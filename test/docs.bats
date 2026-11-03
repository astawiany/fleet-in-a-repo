#!/usr/bin/env bats
# Static checks of README, architecture doc and ADRs. Nothing here talks to a cluster.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ADRS="0001-flux-vs-argocd 0002-monorepo-env-dirs 0003-feature-flags-as-helm-values 0004-github-actions-vs-gitlab-ci 0005-capd-as-local-provider"
}

@test "five ADR files exist with Context, Decision, Consequences and Alternatives headings" {
  for a in $ADRS; do
    f="$ROOT/docs/adr/$a.md"
    [[ -f "$f" ]] || { echo "missing $f"; false; }
    for h in Context Decision Consequences Alternatives; do
      grep -qE "^## $h" "$f" || { echo "$f lacks '## $h'"; false; }
    done
  done
}

@test "README links every ADR" {
  for a in $ADRS; do
    grep -qF "docs/adr/$a.md" "$ROOT/README.md" || { echo "README does not link $a"; false; }
  done
}

@test "README contains the quickstart commands make up, make smoke, make down" {
  for c in "make up" "make smoke" "make down"; do
    grep -qF "$c" "$ROOT/README.md" || { echo "README lacks '$c'"; false; }
  done
}

@test "README and architecture.md each contain a Mermaid diagram" {
  for f in README.md docs/architecture.md; do
    grep -qE '^```mermaid' "$ROOT/$f" || { echo "$f has no mermaid block"; false; }
  done
}

@test "every relative markdown link in README and docs resolves to an existing file" {
  cd "$ROOT"
  files="README.md $(find docs -name '*.md' -not -path 'docs/superpowers/*')"
  n=0
  for f in $files; do
    dir="$(dirname "$f")"
    for link in $(grep -oE '\]\([^)#]+(#[^)]*)?\)' "$f" | sed -E 's/^\]\(//; s/\)$//; s/#.*//'); do
      case "$link" in http*|mailto:*) continue ;; esac
      n=$((n + 1))
      [[ -e "$dir/$link" ]] || { echo "$f: broken link $link"; false; }
    done
  done
  [[ "$n" -gt 5 ]] || { echo "only $n links checked"; false; }
}

@test "repo contains no employer names" {
  cd "$ROOT"
  # The pattern is assembled from pieces so this file does not match itself. Only the git-ignored
  # .superpowers working notes and .work scratch are skipped; docs/superpowers is scanned too.
  pat="t""-mobile|te""lekom"
  run grep -rIiE "$pat" . --exclude-dir=.git --exclude-dir=.work --exclude-dir=.superpowers
  [[ "$status" -eq 1 ]] || { echo "$output"; false; }
}

@test "docs/security.md is linked from README and documents verification with the release identity" {
  f="$ROOT/docs/security.md"
  [[ -f "$f" ]]
  grep -qF '(docs/security.md)' "$ROOT/README.md"
  # the documented identity regexp is exactly the one release.yml verifies against
  want="$("$ROOT/scripts/release.sh" identity-regexp astawiany/fleet-in-a-repo)"
  grep -qxF "IDENTITY='$want'" "$f" || { echo "IDENTITY line differs from: $want"; false; }
  grep -qxF 'ISSUER=https://token.actions.githubusercontent.com' "$f"
  [ "$(grep -c '^cosign verify "ghcr.io/astawiany/' "$f")" = "3" ]
  [ "$(grep -c -- '--certificate-identity-regexp "$IDENTITY"' "$f")" = "2" ]
  [ "$(grep -c -- '--certificate-oidc-issuer "$ISSUER"' "$f")" = "3" ]
  # exact identity of a known version, in addition to the anchored regexp
  grep -qF -- '--certificate-identity "https://github.com/astawiany/fleet-in-a-repo/.github/workflows/release.yml@refs/tags/chart-v$VERSION"' "$f"
  grep -qF "fleet-demo@\$DIGEST\" --format '{{json .SBOM}}'" "$f"
  grep -qF "fleet-demo@\$DIGEST\" --format '{{json .Provenance}}'" "$f"
  grep -qF 'helm pull oci://ghcr.io/astawiany/charts/demo' "$f"
  # threat model in ten numbered points, release procedure, GHCR visibility, limits
  [ "$(sed -n '/^## Threat model/,/^## /p' "$f" | grep -cE '^[0-9]+\. ')" = "10" ]
  for h in "What is published" "Release procedure" "GHCR packages" "Not covered"; do
    grep -qx "## $h" "$f" || { echo "no section $h"; false; }
  done
  grep -q 'packages/container/fleet-demo/settings' "$f"
  grep -q 'gh api users/astawiany/packages/container/fleet-demo --jq .visibility' "$f"
}

@test ".github/README.md documents the release Environment and tag protection, and its links resolve" {
  f="$ROOT/.github/README.md"
  grep -q '`release`' "$f"
  grep -q -- 'release-tags' "$f"
  for link in $(grep -oE '\]\([^)#]+(#[^)]*)?\)' "$f" | sed -E 's/^\]\(//; s/\)$//; s/#.*//'); do
    case "$link" in http*) continue ;; esac
    [[ -e "$ROOT/.github/$link" ]] || { echo "broken link $link"; false; }
  done
}

@test "security docs state that the tag ruleset is the signing control and that verify/Environment are procedural" {
  f="$ROOT/docs/security.md"
  tm="$(sed -n '/^## Threat model/,/^## /p' "$f")"
  [[ "$tm" == *"release-tags"* ]] || false
  [[ "$tm" == *"only while that ruleset is active"* ]] || false
  [[ "$tm" == *"procedural gates"* ]] || false
  [[ "$tm" == *"prevent_self_review"* ]] || false
  # step 0 of the release procedure applies protect-branch.sh (with the ruleset)
  rp="$(sed -n '/^## Release procedure/,/^## /p' "$f")"
  [[ "$(printf '%s\n' "$rp" | grep -E '^0\. ')" == *"Once per repository"* ]] || false
  [[ "$rp" == *"scripts/protect-branch.sh --repo astawiany/fleet-in-a-repo"* ]] || false
  g="$ROOT/.github/README.md"
  grep -q -- '--no-protect-tags' "$g"
  grep -q 'prevent_self_review' "$g"
  grep -q 'procedural gates' "$g"
  run grep -n -- '--protect-tags' "$g" "$f" "$ROOT/README.md"
  [ "$status" -eq 1 ] || { echo "stale flag: $output"; false; }
}
