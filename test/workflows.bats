#!/usr/bin/env bats
# Static checks of the GitHub Actions workflows, governance files and the opt-in Flux
# notifications. Nothing here talks to GitHub or a cluster.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WF="$ROOT/.github/workflows"
  WORK="$(mktemp -d)"
}

teardown() { rm -rf "$WORK"; }

workflows() { ls "$WF"/*.yml; }

@test "workflow YAML parses and every job has timeout-minutes" {
  [ "$(workflows | wc -l | tr -d ' ')" -ge 3 ]
  for f in $(workflows); do
    yq '.' "$f" > /dev/null
    [ "$(yq '.jobs | length' "$f")" -ge 1 ]
    [ "$(yq '[.jobs[] | select(has("timeout-minutes") | not)] | length' "$f")" = "0" ] || { echo "job without timeout-minutes in $f"; false; }
  done
}

@test "no workflow references a secret other than GITHUB_TOKEN, APP_ID or APP_PRIVATE_KEY" {
  [ "$(workflows | wc -l | tr -d ' ')" -ge 3 ]
  found="$(cat "$WF"/*.yml | grep -Eo 'secrets\.[A-Za-z0-9_]+' | sort -u || true)"
  echo "secrets: $found"
  bad="$(printf '%s\n' "$found" | grep -Ev '^$|^secrets\.(GITHUB_TOKEN|APP_ID|APP_PRIVATE_KEY)$' || true)"
  [ -z "$bad" ] || { echo "disallowed secrets: $bad"; false; }
  # no inherited secrets either
  ! grep -q 'secrets: inherit' "$WF"/*.yml
}

@test "promote.yml skips PR creation on \"no change\"" {
  f="$WF/promote.yml"
  # the promote step records whether promote.sh printed "no change"
  run yq '[.jobs[].steps[] | select(has("run")) | select(.run | contains("no change"))] | length' "$f"
  [ "$output" -ge 1 ]
  # every step that opens a PR is guarded by that output
  n_pr="$(yq '[.jobs[].steps[] | select(has("run")) | select(.run | contains("gh pr create"))] | length' "$f")"
  n_guarded="$(yq '[.jobs[].steps[] | select(has("run")) | select(.run | contains("gh pr create")) | select(.if | contains("outputs.changed == '"'"'true'"'"'"))] | length' "$f")"
  [ "$n_pr" -ge 1 ] || false
  [ "$n_pr" = "$n_guarded" ] || { echo "gh pr create steps: $n_pr, guarded: $n_guarded"; false; }
}

@test "promote.yml triggers on dev/test pins on main" {
  f="$WF/promote.yml"
  [ "$(yq '.on.push.branches[0]' "$f")" = "main" ]
  [ "$(yq '.on.push.paths | map(select(. == "promotion/versions/dev.yaml" or . == "promotion/versions/test.yaml")) | length' "$f")" = "2" ]
  [[ "$(yq '.permissions' "$f")" == *"contents: write"* ]] || false
  [[ "$(yq '.permissions' "$f")" == *"pull-requests: write"* ]] || false
}

@test "promote.yml pairs dev->test and test->prod, each gated by its Environment" {
  f="$WF/promote.yml"
  [ "$(yq '.jobs."promote-test".environment' "$f")" = "test" ]
  [ "$(yq '.jobs."promote-prod".environment' "$f")" = "prod" ]
  [ "$(yq '.jobs."promote-test".env.FROM + ">" + .jobs."promote-test".env.TO' "$f")" = "dev>test" ]
  [ "$(yq '.jobs."promote-prod".env.FROM + ">" + .jobs."promote-prod".env.TO' "$f")" = "test>prod" ]
  [ "$(yq '.jobs."promote-test".needs' "$f")" = "detect" ]
  [[ "$(yq '.jobs."promote-test".if' "$f")" == *"dev_changed"* ]] || false
  [[ "$(yq '.jobs."promote-prod".if' "$f")" == *"test_changed"* ]] || false
  grep -q 'promote.sh "\$FROM" "\$TO"' "$f"
}

@test "promote.yml is idempotent: stable branch, force-with-lease, existing PR updated, serialized per env" {
  f="$WF/promote.yml"
  for j in promote-test promote-prod; do
    [ "$(yq ".jobs.\"$j\".concurrency.group" "$f")" = "$j" ]
    [ "$(yq ".jobs.\"$j\".concurrency.\"cancel-in-progress\"" "$f")" = "false" ]
  done
  grep -q 'branch="promote/\$TO"' "$f"
  grep -q 'git push --force-with-lease origin' "$f"
  grep -q 'gh pr list --head' "$f"
  grep -q 'gh pr edit' "$f"
  # changed files are computed from the push's before SHA, with the all-zero first-push case handled
  grep -q 'BEFORE: \${{ github.event.before }}' "$f"
  grep -q '0000000000000000000000000000000000000000' "$f"
  ! grep -q 'HEAD^' "$f"
}

@test "promote.yml offers an optional GitHub App token step without a new third-party action" {
  f="$WF/promote.yml"
  [ "$(yq '.jobs."promote-test".steps[] | select(.id == "app") | .if' "$f")" = "\${{ vars.USE_APP_TOKEN == 'true' }}" ]
  grep -q 'scripts/app-token.sh' "$f"
  [ -x "$ROOT/scripts/app-token.sh" ]
  [ -f "$ROOT/.github/README.md" ]
  grep -q 'Allow GitHub Actions to create and approve pull requests' "$ROOT/.github/README.md"
  grep -q 'Allow GitHub Actions to create and approve pull requests' "$f"
}

@test "release.yml labels the image with its source repo and exposes the digest" {
  f="$WF/release.yml"
  grep -q 'org.opencontainers.image.source=https://github.com/' "$f"
  [ "$(yq '.jobs.image.outputs.digest' "$f")" = '${{ steps.push.outputs.digest }}' ]
  grep -q 'digest=\$digest" >> "\$GITHUB_OUTPUT"' "$f"
  grep -q 'GITHUB_STEP_SUMMARY' "$f"
}

@test "release.yml pushes the image the chart references (same basename as image.repository)" {
  f="$WF/release.yml"
  values="$ROOT/apps/demo/chart/values.yaml"
  ref="$(grep -oE 'ref="ghcr\.io/\$\{owner\}/[a-z0-9._-]+:' "$f" | head -n 1)"
  [ -n "$ref" ] || { echo "no ghcr.io/\${owner}/<name>: image ref in release.yml"; false; }
  released="${ref##*/}"
  released="${released%:}"
  repo="$(yq '.image.repository' "$values")"
  echo "release: $released, chart: $repo"
  [ "$released" = "${repo##*/}" ] || false
  # the release owner is lowercased (ghcr.io refuses upper case)
  grep -q "owner=\"\$(echo \"\$GITHUB_REPOSITORY_OWNER\" | tr '\[:upper:\]' '\[:lower:\]')\"" "$f"
  # no personal handle in the chart default: the owner is the documented placeholder
  [ "$(echo "$repo" | cut -d/ -f2)" = "owner" ] || false
  grep -q 'release.yml' "$values"
}

@test "every uses: is pinned to a commit SHA or an explicit version tag" {
  refs="$(grep -hE '^\s*-?\s*uses:' "$WF"/*.yml | sed -E 's/.*uses:[[:space:]]*//; s/[[:space:]]*#.*//')"
  [ -n "$refs" ]
  while IFS= read -r r; do
    ref="${r##*@}"
    [ "$ref" != "$r" ] || { echo "unpinned: $r"; false; }
    [[ "$ref" =~ ^([0-9a-f]{40}|v[0-9]+(\.[0-9]+){0,2})$ ]] || { echo "not pinned: $r"; false; }
  done <<< "$refs"
}

@test "permissions are declared at workflow level on every workflow" {
  [ "$(workflows | wc -l | tr -d ' ')" -ge 3 ]
  for f in $(workflows); do
    [ "$(yq '.permissions | length' "$f")" -ge 1 ] || { echo "no permissions in $f"; false; }
  done
}

@test "validate.yml runs on pull requests with lint, validate, test and a lite smoke job" {
  f="$WF/validate.yml"
  [ "$(yq '.on | has("pull_request")' "$f")" = "true" ]
  for j in lint validate test smoke; do
    [ "$(yq ".jobs | has(\"$j\")" "$f")" = "true" ] || { echo "missing job $j"; false; }
  done
  grep -q 'FLEET_PROFILE: lite' "$f"
  grep -q 'make smoke' "$f"
  # teardown must run even when smoke fails
  [ "$(yq '[.jobs.smoke.steps[] | select(.run == "make down") | select(.if == "always()")] | length' "$f")" = "1" ]
  # mgmt-up pushes HEAD to a bare repo: the smoke checkout must not be shallow
  [ "$(yq '.jobs.smoke.steps[] | select(.uses == "actions/checkout*") | .with."fetch-depth"' "$f")" = "0" ] || false
}

@test "release.yml triggers on chart-v* tags and pushes the chart and image to ghcr" {
  f="$WF/release.yml"
  [ "$(yq '.on.push.tags[0]' "$f")" = "chart-v*" ]
  [ "$(yq '.permissions.packages' "$f")" = "write" ]
  grep -q 'helm package apps/demo/chart' "$f"
  grep -q 'helm push' "$f"
  grep -q 'oci://ghcr.io/' "$f"
  grep -q 'digest' "$f"
}

@test "CODEOWNERS covers platform paths and app paths, and documents its placeholder owner" {
  f="$ROOT/.github/CODEOWNERS"
  for p in infrastructure clusters capi kind scripts .github promotion; do
    grep -Eq "^/$p/ +@" "$f" || { echo "no rule for /$p/"; false; }
  done
  grep -Eq '^/apps/ +@' "$f"
  grep -Eq '^\* +@OWNER' "$f"
  grep -q '@OWNER' "$f"
  grep -qi 'replace' "$f"
  # the placeholder is the only owner token used
  ! grep -v '^#' "$f" | grep -Eo '@[A-Za-z0-9_/-]+' | grep -vx '@OWNER'
}

# --- protect-branch.sh --------------------------------------------------------------------

# A gh stub that records every call and fails: dry-run must never reach it.
stub_gh() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/gh" <<STUB
#!/usr/bin/env bash
echo "gh invoked: \$*" >> "$WORK/gh.calls"
exit 99
STUB
  chmod +x "$WORK/bin/gh"
}

@test "protect-branch --dry-run prints the gh api calls and never invokes gh" {
  stub_gh
  PATH="$WORK/bin:$PATH" run "$ROOT/scripts/protect-branch.sh" --dry-run --repo acme/fleet --reviewers alice,bob
  [ "$status" -eq 0 ]
  [ ! -e "$WORK/gh.calls" ] || { cat "$WORK/gh.calls"; false; }
  [[ "$output" == *"gh api --method PUT repos/acme/fleet/branches/main/protection"* ]] || false
  [[ "$output" == *"repos/acme/fleet/environments/test"* ]] || false
  [[ "$output" == *"repos/acme/fleet/environments/prod"* ]] || false
  [[ "$output" == *"required_pull_request_reviews"* ]] || false
  [[ "$output" == *'"enforce_admins": true'* ]] || false
  # required checks are exactly the validate.yml job ids
  for j in lint validate test smoke; do [[ "$output" == *"\"$j\""* ]] || { echo "missing check $j"; false; }; done
  [[ "$output" == *"alice"* && "$output" == *"bob"* ]] || false
}

@test "protect-branch refuses to run for real without --repo, and never calls gh then" {
  stub_gh
  PATH="$WORK/bin:$PATH" run "$ROOT/scripts/protect-branch.sh" --reviewers alice
  [ "$status" -ne 0 ]
  [[ "$output" == *"--repo"* ]] || false
  [ ! -e "$WORK/gh.calls" ]
}

@test "protect-branch rejects blank reviewer entries with exit 2 and a clear message" {
  stub_gh
  run "$ROOT/scripts/protect-branch.sh" --dry-run --repo acme/fleet --reviewers ", ,"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no valid reviewers"* ]] || false
  # blank entries between real ones are dropped: two reviewers per environment, none unresolved
  run "$ROOT/scripts/protect-branch.sh" --dry-run --repo acme/fleet --reviewers "alice,,bob"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -o '"type": "User"' | wc -l | tr -d ' ')" = "4" ]
  [[ "$output" != *"<id of :"* ]] || false
}

@test "protect-branch validates reviewers before any gh call (real run, blank reviewers)" {
  stub_gh
  PATH="$WORK/bin:$PATH" run "$ROOT/scripts/protect-branch.sh" --repo acme/fleet --reviewers ", ,"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no valid reviewers"* ]] || false
  [ ! -e "$WORK/gh.calls" ] || { cat "$WORK/gh.calls"; false; }
}

@test "protect-branch requires reviewers (no hard-coded logins)" {
  stub_gh
  run env -u PROTECT_REVIEWERS PATH="$WORK/bin:$PATH" "$ROOT/scripts/protect-branch.sh" --dry-run --repo acme/fleet
  [ "$status" -ne 0 ]
  [[ "$output" == *"reviewers"* ]] || false
}

# --- Flux notifications (opt-in) ----------------------------------------------------------

@test "flux-notifications is opt-in: builds and validates, but is not part of the default infrastructure" {
  d="$ROOT/infrastructure/base/flux-notifications"
  [ -f "$d/README.md" ]
  run kustomize build "$d"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kind: Provider"* && "$output" == *"type: github"* ]] || false
  [[ "$output" == *"kind: Alert"* ]] || false
  [[ "$output" == *"notification.toolkit.fluxcd.io/v1beta3"* ]] || false
  run "$ROOT/scripts/validate.sh" "$d"
  [ "$status" -eq 0 ]
  # not wired into any default kustomization
  ! grep -rn 'flux-notifications' "$ROOT/infrastructure" "$ROOT/clusters" --include='*.yaml' | grep -v '^[^:]*flux-notifications/'
  grep -qi 'secret' "$d/README.md"
}

# --- app-token.sh (curl stubbed, fake key generated here) ---------------------------------

app_token_env() { # $1 = installation response, $2 = token response
  mkdir -p "$WORK/bin"
  printf '%s' "$1" > "$WORK/resp.inst"; printf '%s' "$2" > "$WORK/resp.tok"
  cat > "$WORK/bin/curl" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *access_tokens*) cat "$WORK/resp.tok" ;;
  *) cat "$WORK/resp.inst" ;;
esac
STUB
  chmod +x "$WORK/bin/curl"
  openssl genrsa -out "$WORK/key.pem" 2048 2> /dev/null
}

@test "app-token.sh prints the token, and fails on an empty token or missing installation" {
  app_token_env '{"id": 42}' '{"token": "tok-123"}'
  PATH="$WORK/bin:$PATH" APP_ID=1 REPO=acme/fleet APP_PRIVATE_KEY="$(cat "$WORK/key.pem")" run "$ROOT/scripts/app-token.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "tok-123" ]
  app_token_env '{"id": 42}' '{"token": ""}'
  PATH="$WORK/bin:$PATH" APP_ID=1 REPO=acme/fleet APP_PRIVATE_KEY="$(cat "$WORK/key.pem")" run "$ROOT/scripts/app-token.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no installation token"* ]] || false
  app_token_env '{"message": "Not Found"}' '{"token": "tok-123"}'
  PATH="$WORK/bin:$PATH" APP_ID=1 REPO=acme/fleet APP_PRIVATE_KEY="$(cat "$WORK/key.pem")" run "$ROOT/scripts/app-token.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not find an installation"* ]] || false
  [[ "$output" != *"tok-123"* ]] || false
}

@test "promote.yml least privilege, fetch before force-with-lease, and notes obsolete PRs" {
  f="$WF/promote.yml"
  [ "$(yq '.jobs.detect.permissions.contents' "$f")" = "read" ]
  [ "$(yq '.jobs.detect.permissions | length' "$f")" = "1" ]
  grep -q 'git fetch origin "\$branch"' "$f"
  [ "$(grep -n 'git fetch origin' "$f" | head -1 | cut -d: -f1)" -lt "$(grep -n 'git push --force-with-lease' "$f" | head -1 | cut -d: -f1)" ]
  grep -q 'gh pr comment' "$f"
  grep -q 'promotion-note-marker' "$f"
}
