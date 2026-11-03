#!/usr/bin/env bats
# Release hardening: scripts/release.sh, scripts/security-scan.sh, the shape of release.yml and the
# demo image build inputs. docker, trivy and git remotes are stubbed or local; nothing talks to a
# registry, GitHub or Sigstore.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WF="$ROOT/.github/workflows"
  REL="$WF/release.yml"
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/bin"
  D64="$(printf '%064d' 0 | tr 0 a)"
  D64B="$(printf '%064d' 0 | tr 0 b)"
}

teardown() { rm -rf "$WORK"; }

# A docker stub: records every call; `buildx imagetools inspect --raw <ref>` prints $WORK/raw/<ref
# with / : @ replaced by _>, or fails with $WORK/raw.err (exit 1) when that file is missing;
# `save` streams $WORK/save.tar; `run` exits $DOCKER_RUN_RC.
stub_docker() {
  mkdir -p "$WORK/raw"
  cat > "$WORK/bin/docker" << STUB
#!/usr/bin/env bash
echo "docker \$*" >> "$WORK/docker.calls"
case "\$1 \$2 \$3" in
  "buildx imagetools inspect")
    ref="\${@: -1}"; f="$WORK/raw/\$(printf '%s' "\$ref" | tr '/:@' '___')"
    if [ -f "\$f" ]; then cat "\$f"; else cat "$WORK/raw.err" >&2 2> /dev/null; exit 1; fi ;;
  "buildx build "*) exit 0 ;;
  "buildx version "*) exit "\${DOCKER_BUILDX_RC:-0}" ;;
esac
case "\$1" in
  save) cat "$WORK/save.tar" ;;
  run) exit "\${DOCKER_RUN_RC:-0}" ;;
esac
STUB
  chmod +x "$WORK/bin/docker"
}

raw() { printf '%s' "$2" > "$WORK/raw/$(printf '%s' "$1" | tr '/:@' '___')"; }
rel() { PATH="$WORK/bin:$PATH" run "$ROOT/scripts/release.sh" "$@"; }

# --- check-tag ------------------------------------------------------------------------------

@test "check-tag accepts chart-vX.Y.Z only and prints the version" {
  rel check-tag chart-v1.2.3
  [ "$status" -eq 0 ] && [ "$output" = "1.2.3" ]
  rel check-tag chart-v10.20.30
  [ "$status" -eq 0 ] && [ "$output" = "10.20.30" ]
  for bad in chart-v1.2 chart-v1.2.3-rc.1 chart-v1.2.3+build v1.2.3 chart-1.2.3 chart-v1.2.3.4 "chart-v1.2.3 " "" "chart-v1.2.x"; do
    rel check-tag "$bad"
    [ "$status" -ne 0 ] || { echo "accepted '$bad'"; false; }
  done
}

# --- check-ancestor (a throwaway git repo with an origin/main remote-tracking ref) ----------

ancestor_repo() {
  r="$WORK/repo"
  mkdir -p "$r/scripts"
  cp "$ROOT/scripts/release.sh" "$r/scripts/"
  # isolated from the user's git config (signing, hooks, default branch)
  g() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$r" -c user.name=t -c user.email=t@example.invalid "$@"; }
  g init -q -b main
  g commit -q --allow-empty -m c1
  g tag -a -m rel chart-v0.1.0
  g commit -q --allow-empty -m c2
  g update-ref refs/remotes/origin/main HEAD
  g checkout -q -b side
  g commit -q --allow-empty -m c3
  g tag chart-v0.2.0
}

@test "check-ancestor passes for a tag on origin/main and fails for a tag on another branch" {
  ancestor_repo
  run "$WORK/repo/scripts/release.sh" check-ancestor refs/tags/chart-v0.1.0 origin/main
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"is on origin/main"* ]] || false
  run "$WORK/repo/scripts/release.sh" check-ancestor refs/tags/chart-v0.2.0 origin/main
  [ "$status" -ne 0 ]
  [[ "$output" == *"not on origin/main"* ]] || { echo "$output"; false; }
  # an unknown base or revision fails instead of passing
  run "$WORK/repo/scripts/release.sh" check-ancestor refs/tags/chart-v0.1.0 origin/nope
  [ "$status" -ne 0 ]
  run "$WORK/repo/scripts/release.sh" check-ancestor refs/tags/chart-v9.9.9
  [ "$status" -ne 0 ]
}

# --- check-absent ---------------------------------------------------------------------------

@test "check-absent refuses an existing version, passes on not-found, fails closed otherwise" {
  stub_docker
  raw ghcr.io/o/fleet-demo:1.0.0 '{"schemaVersion":2}'
  rel check-absent ghcr.io/o/fleet-demo:1.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]] || false
  for msg in "ERROR: ghcr.io/o/fleet-demo:2.0.0: not found" "manifest unknown" \
    '{"errors":[{"code":"MANIFEST_UNKNOWN"}]}' '{"errors":[{"code":"NAME_UNKNOWN"}]}'; do
    printf '%s\n' "$msg" > "$WORK/raw.err"
    rel check-absent ghcr.io/o/fleet-demo:2.0.0
    [ "$status" -eq 0 ] || { echo "'$msg': $output"; false; }
  done
  for msg in "denied" "failed to fetch anonymous token: 403 Forbidden" "dial tcp: lookup ghcr.io: no such host" "" \
    "bash: docker: command not found" "ERROR: ghcr.io/o/other:2.0.0: not found" "ERROR: file not found"; do
    printf '%s\n' "$msg" > "$WORK/raw.err"
    rel check-absent ghcr.io/o/fleet-demo:2.0.0
    [ "$status" -eq 2 ] || { echo "'$msg' gave $status: $output"; false; }
  done
}

# --- digests ----------------------------------------------------------------------------------

@test "image-digest reads containerimage.digest and rejects anything that is not a sha256 digest" {
  printf '{"containerimage.digest": "sha256:%s"}' "$D64" > "$WORK/m.json"
  rel image-digest "$WORK/m.json"
  [ "$status" -eq 0 ] && [ "$output" = "sha256:$D64" ]
  for bad in '{}' '{"containerimage.digest": "sha256:abc"}' '{"containerimage.digest": "latest"}'; do
    printf '%s' "$bad" > "$WORK/m.json"
    rel image-digest "$WORK/m.json"
    [ "$status" -ne 0 ] || { echo "accepted $bad"; false; }
  done
  rel image-digest "$WORK/missing.json"
  [ "$status" -ne 0 ]
}

@test "helm-digest parses helm push output and fails when no single digest is present" {
  printf 'Pushed: ghcr.io/o/charts/demo:1.0.0\nDigest: sha256:%s\n' "$D64" > "$WORK/push.txt"
  rel helm-digest "$WORK/push.txt"
  [ "$status" -eq 0 ] && [ "$output" = "sha256:$D64" ]
  printf 'Pushed: ghcr.io/o/charts/demo:1.0.0\nError: unexpected status 403\n' > "$WORK/push.txt"
  rel helm-digest "$WORK/push.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not parse"* ]] || false
  printf 'Digest: sha256:%s\nDigest: sha256:%s\n' "$D64" "$D64B" > "$WORK/push.txt"
  rel helm-digest "$WORK/push.txt"
  [ "$status" -ne 0 ]
  printf 'Digest: sha256:abc\n' > "$WORK/push.txt"
  rel helm-digest "$WORK/push.txt"
  [ "$status" -ne 0 ]
}

# --- assert-scanned ---------------------------------------------------------------------------

# save.tar with a manifest.json whose Config is $1 (both docker save layouts are exercised)
save_tar() {
  mkdir -p "$WORK/save"
  printf '[{"Config": "%s", "Layers": []}]' "$1" > "$WORK/save/manifest.json"
  tar -cf "$WORK/save.tar" -C "$WORK/save" manifest.json
}

pushed_index() { # pushed index with an amd64 image (config $1) and an attestation manifest
  raw "ghcr.io/o/fleet-demo@sha256:$D64" "$(printf '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"digest":"sha256:%s","platform":{"os":"linux","architecture":"amd64"}},{"digest":"sha256:%s","platform":{"os":"unknown","architecture":"unknown"}}]}' "$D64B" "$(printf '%064d' 0 | tr 0 c)")"
  raw "ghcr.io/o/fleet-demo@sha256:$D64B" "$(printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"digest":"%s"}}' "$1")"
}

@test "assert-scanned passes when the pushed amd64 config equals the scanned image config" {
  stub_docker
  cfg="$(printf '%064d' 0 | tr 0 e)"
  pushed_index "sha256:$cfg"
  for layout in "$cfg.json" "blobs/sha256/$cfg"; do
    save_tar "$layout"
    rel assert-scanned fleet-demo:scan "ghcr.io/o/fleet-demo@sha256:$D64"
    [ "$status" -eq 0 ] || { echo "$layout: $output"; false; }
    [[ "$output" == *"equals the scanned image config"* ]] || false
  done
}

@test "assert-scanned fails when the pushed image differs from the scanned one, or is given a tag" {
  stub_docker
  pushed_index "sha256:$(printf '%064d' 0 | tr 0 f)"
  save_tar "$(printf '%064d' 0 | tr 0 e).json"
  rel assert-scanned fleet-demo:scan "ghcr.io/o/fleet-demo@sha256:$D64"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not the scanned image"* ]] || { echo "$output"; false; }
  rel assert-scanned fleet-demo:scan ghcr.io/o/fleet-demo:1.0.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"never a tag"* ]] || { echo "$output"; false; }
  # an index without an amd64 image is an error, not a pass
  raw "ghcr.io/o/fleet-demo@sha256:$D64" '{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}'
  rel assert-scanned fleet-demo:scan "ghcr.io/o/fleet-demo@sha256:$D64"
  [ "$status" -ne 0 ]
}

# --- build, identity, govulncheck -------------------------------------------------------------

@test "build passes the release build args, linux/amd64 and the caller's flags, and needs all inputs" {
  stub_docker
  PATH="$WORK/bin:$PATH" VERSION=1.2.3 REVISION=abc SOURCE=https://github.com/o/r SOURCE_DATE_EPOCH=1700000000 \
    run "$ROOT/scripts/release.sh" build --load -t fleet-demo:scan
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  call="$(cat "$WORK/docker.calls")"
  for want in "buildx build --builder release --platform linux/amd64" "--build-arg SOURCE_DATE_EPOCH=1700000000" \
    "--build-arg VERSION=1.2.3" "--build-arg REVISION=abc" "--build-arg SOURCE=https://github.com/o/r" \
    "--load -t fleet-demo:scan $ROOT/apps/demo/src"; do
    [[ "$call" == *"$want"* ]] || { echo "missing '$want' in: $call"; false; }
  done
  PATH="$WORK/bin:$PATH" VERSION=1.2.3 REVISION=abc SOURCE=https://github.com/o/r run "$ROOT/scripts/release.sh" build --load
  [ "$status" -ne 0 ]
  [[ "$output" == *"SOURCE_DATE_EPOCH"* ]] || false
}

@test "identity-regexp matches only release.yml on a chart-vX.Y.Z tag of this repository" {
  rel identity-regexp astawiany/fleet-in-a-repo
  [ "$status" -eq 0 ]
  re="$output"
  [ "$re" = '^https://github\.com/astawiany/fleet-in-a-repo/\.github/workflows/release\.yml@refs/tags/chart-v[0-9]+\.[0-9]+\.[0-9]+$' ]
  grep -Eq "$re" <<< "https://github.com/astawiany/fleet-in-a-repo/.github/workflows/release.yml@refs/tags/chart-v1.2.3"
  for bad in \
    "https://github.com/astawiany/fleet-in-a-repo/.github/workflows/release.yml@refs/heads/main" \
    "https://github.com/astawiany/fleet-in-a-repo/.github/workflows/validate.yml@refs/tags/chart-v1.2.3" \
    "https://github.com/evil/fleet-in-a-repo/.github/workflows/release.yml@refs/tags/chart-v1.2.3" \
    "https://github.com/astawiany/fleet-in-a-repoX/.github/workflows/release.yml@refs/tags/chart-v1.2.3" \
    "https://github.com/astawiany/fleet-in-a-repo/.github/workflows/release.yml@refs/tags/chart-v1.2.3-rc1"; do
    run grep -Eq "$re" <<< "$bad"
    [ "$status" -eq 1 ] || { echo "matched $bad"; false; }
  done
  rel identity-regexp 'not a repo'
  [ "$status" -ne 0 ]
}

@test "govulncheck runs the pinned version in the digest-pinned builder image and propagates failure" {
  stub_docker
  rel govulncheck
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # shellcheck disable=SC1091
  source "$ROOT/versions.env"
  call="$(cat "$WORK/docker.calls")"
  builder="$(grep -E '^FROM .* AS build$' "$ROOT/apps/demo/src/Dockerfile" | awk '{ print $2 }')"
  [[ "$builder" == golang:*@sha256:* ]] || false
  [[ "$call" == *"run --rm -v $ROOT/apps/demo/src:/src:ro -w /src"* ]] || { echo "$call"; false; }
  [[ "$call" == *" $builder "* ]] || { echo "$call"; false; }
  [[ "$call" == *"golang.org/x/vuln/cmd/govulncheck@v${GOVULNCHECK_VERSION} && govulncheck ./..."* ]] || { echo "$call"; false; }
  DOCKER_RUN_RC=3 PATH="$WORK/bin:$PATH" run "$ROOT/scripts/release.sh" govulncheck
  [ "$status" -eq 3 ]
}

# --- security-scan.sh ---------------------------------------------------------------------------

stub_trivy() { # trivy stub: records calls, exits 1 for the subcommand+scanner named in $TRIVY_FAIL
  cat > "$WORK/bin/trivy" << STUB
#!/usr/bin/env bash
echo "trivy \$*" >> "$WORK/trivy.calls"
case " \$* " in *" \${TRIVY_FAIL:-none} "*) exit 1 ;; esac
exit 0
STUB
  chmod +x "$WORK/bin/trivy"
}

@test "security-scan runs every gate with failing thresholds and passes when all pass" {
  stub_docker; stub_trivy
  PATH="$WORK/bin:$PATH" run "$ROOT/scripts/security-scan.sh" fleet-demo:scan
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  calls="$(cat "$WORK/trivy.calls")"
  grep -qx -- "trivy image --no-progress --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 fleet-demo:scan" <<< "$calls"
  grep -qx -- "trivy image --no-progress --scanners secret --exit-code 1 fleet-demo:scan" <<< "$calls"
  grep -qx -- "trivy config --severity HIGH,CRITICAL --exit-code 1 $ROOT/apps/demo/chart" <<< "$calls"
  grep -qx -- "trivy config --severity HIGH,CRITICAL --exit-code 1 $ROOT/apps/demo/src" <<< "$calls"
  grep -q -- "trivy fs --no-progress --scanners secret --exit-code 1 .* $ROOT\$" <<< "$calls"
  grep -q 'govulncheck' "$WORK/docker.calls"
}

@test "security-scan fails when any single gate fails, and names it" {
  stub_docker; stub_trivy
  for gate in "vuln:image-vulns" "secret --exit-code 1 fleet-demo:scan:image-secrets" "$ROOT/apps/demo/chart:chart-config" \
    "$ROOT/apps/demo/src:dockerfile-config" "fs:repo-secrets"; do
    TRIVY_FAIL="${gate%:*}" PATH="$WORK/bin:$PATH" run "$ROOT/scripts/security-scan.sh" fleet-demo:scan
    [ "$status" -eq 1 ] || { echo "$gate passed"; false; }
    [[ "$output" == *"FAIL ${gate##*:}"* ]] || { echo "$gate: $output"; false; }
  done
  DOCKER_RUN_RC=3 PATH="$WORK/bin:$PATH" run "$ROOT/scripts/security-scan.sh" fleet-demo:scan
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL govulncheck"* ]] || false
  PATH="$WORK/bin:$PATH" run "$ROOT/scripts/security-scan.sh"
  [ "$status" -eq 2 ]
}

# --- release.yml shape --------------------------------------------------------------------------

@test "release.yml: no workflow-level permissions, least privilege per job" {
  [ "$(yq '.permissions | length' "$REL")" = "0" ]
  [ "$(yq '.permissions | tag' "$REL")" = "!!map" ]
  [ "$(yq -o=json -I=0 '.jobs.verify.permissions' "$REL")" = '{"contents":"read","packages":"read"}' ]
  for j in image chart; do
    [ "$(yq -o=json -I=0 ".jobs.$j.permissions" "$REL")" = '{"contents":"read","packages":"write","id-token":"write"}' ] \
      || { echo "$j: $(yq -o=json -I=0 ".jobs.$j.permissions" "$REL")"; false; }
  done
  [ "$(yq '.jobs | keys | join(",")' "$REL")" = "verify,image,chart" ]
}

@test "release.yml: verify gates both publish jobs, which run in the release Environment" {
  [ "$(yq '.jobs.image.needs' "$REL")" = "verify" ]
  [ "$(yq '.jobs.chart.needs | join(",")' "$REL")" = "verify,image" ]
  [ "$(yq '.jobs.image.environment' "$REL")" = "release" ]
  [ "$(yq '.jobs.chart.environment' "$REL")" = "release" ]
  [ "$(yq '.jobs.verify | has("environment")' "$REL")" = "false" ]
  [ "$(yq '.jobs.verify.steps[0].with."fetch-depth"' "$REL")" = "0" ]
  body="$(yq '.jobs.verify.steps[] | select(.id == "check") | .run' "$REL")"
  [[ "$body" == *'scripts/release.sh check-tag "$TAG"'* ]] || false
  [[ "$body" == *'scripts/release.sh check-ancestor "refs/tags/$TAG" origin/main'* ]] || false
  [[ "$body" == *'check-absent "ghcr.io/${owner}/fleet-demo:${version}"'* ]] || false
  [[ "$body" == *'check-absent "ghcr.io/${owner}/charts/demo:${version}"'* ]] || false
  [ "$(yq '.concurrency."cancel-in-progress"' "$REL")" = "false" ]
}

# line number of the first step in job $1 whose run contains $2
step_idx() { yq ".jobs.$1.steps | to_entries | map(select(.value.run != null and (.value.run | contains(\"$2\")))) | .[0].key" "$REL"; }

@test "release.yml image job: scan before push, push with attestations, check, then sign and verify by digest" {
  scan_build="$(step_idx image 'build --load -t fleet-demo:scan')"
  gate="$(step_idx image 'scripts/security-scan.sh fleet-demo:scan')"
  push="$(step_idx image 'build --push')"
  same="$(step_idx image 'assert-scanned fleet-demo:scan')"
  sign="$(step_idx image 'cosign sign --yes')"
  for v in "$scan_build" "$gate" "$push" "$same" "$sign"; do [ "$v" != "null" ] || { echo "missing step"; false; }; done
  [ "$scan_build" -lt "$gate" ] && [ "$gate" -lt "$push" ] && [ "$push" -lt "$same" ] && [ "$same" -lt "$sign" ] \
    || { echo "order: $scan_build $gate $push $same $sign"; false; }
  pushrun="$(yq ".jobs.image.steps[$push].run" "$REL")"
  [[ "$pushrun" == *"--provenance=mode=max --sbom=true"* ]] || false
  [[ "$pushrun" == *'--metadata-file "$RUNNER_TEMP/image-metadata.json"'* ]] || false
  [[ "$pushrun" == *'echo "ref=$IMAGE@$digest" >> "$GITHUB_OUTPUT"'* ]] || false
  [ "$(yq '.jobs.image.outputs.digest' "$REL")" = '${{ steps.push.outputs.digest }}' ]
  # the only image builds go through scripts/release.sh build (pinned BuildKit, same args)
  run grep -nE 'docker (image )?build ' "$REL"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  grep -q 'driver-opt "image=$BUILDKIT_IMAGE"' "$REL"
  grep -q 'SOURCE_DATE_EPOCH=$(git log -1 --format=%ct HEAD)' "$REL"
  grep -q 'GITHUB_STEP_SUMMARY' "$REL"
}

@test "release.yml: every cosign call targets a digest ref and verify pins identity and issuer" {
  n_sign="$(grep -c 'cosign sign --yes' "$REL")"
  [ "$n_sign" = "2" ]
  # signing and verifying only ever use $REF, which the push steps set to <repo>@<digest>
  run grep -nE '^ +cosign (sign|verify)' "$REL"
  [ "${#lines[@]}" -eq 4 ] || { echo "$output"; false; }
  while IFS= read -r l; do
    [[ "$l" == *'"$REF"'* ]] || { echo "not by digest: $l"; false; }
  done <<< "$output"
  for j in image chart; do
    [ "$(yq ".jobs.$j.steps[] | select(.name == \"Sign by digest and verify\") | .env.REF" "$REL")" = '${{ steps.push.outputs.ref }}' ] || { echo "$j REF"; false; }
    body="$(yq ".jobs.$j.steps[] | select(.name == \"Sign by digest and verify\") | .run" "$REL")"
    [[ "$body" == *'--certificate-identity-regexp "$(scripts/release.sh identity-regexp "$GITHUB_REPOSITORY")"'* ]] || false
    [[ "$body" == *"--certificate-oidc-issuer https://token.actions.githubusercontent.com"* ]] || false
  done
  grep -q 'echo "ref=ghcr.io/${OWNER}/charts/demo@$digest"' "$REL"
  grep -q 'scripts/ci-install-tools.sh cosign trivy' "$REL"
  grep -q 'scripts/ci-install-tools.sh helm yq cosign' "$REL"
}

@test "release.yml chart job packages the chart pinned to the image job's digest" {
  [ "$(yq '.jobs.chart.env.IMAGE_DIGEST' "$REL")" = '${{ needs.image.outputs.digest }}' ]
  body="$(yq '.jobs.chart.steps[] | select(.id == "push") | .run' "$REL")"
  [[ "$body" == *'.image.digest = strenv(IMAGE_DIGEST)'* ]] || false
  [[ "$body" == *'grep -qF "image: \"ghcr.io/${OWNER}/fleet-demo@${IMAGE_DIGEST}\""'* ]] || false
  [[ "$body" == *'scripts/release.sh helm-digest "$RUNNER_TEMP/helm-push.txt"'* ]] || false
  [[ "$body" == *'| tee "$RUNNER_TEMP/helm-push.txt"'* ]] || false
}

@test "validate.yml has a non-required security job running the same gate" {
  f="$WF/validate.yml"
  [ "$(yq '.jobs | has("security")' "$f")" = "true" ]
  [ "$(yq '.jobs.security.steps[] | select(.run != null) | select(.run | contains("scripts/security-scan.sh")) | .name' "$f")" != "" ]
  grep -q 'OPTIONAL_JOBS="security"' "$ROOT/scripts/protect-branch.sh"
  # smoke does not wait for it
  [[ "$(yq '.jobs.smoke.needs | join(",")' "$f")" != *security* ]] || false
}

# --- image build inputs -------------------------------------------------------------------------

@test "Dockerfile: digest-pinned bases, read-only modules, no VCS stamping, OCI labels from build args" {
  f="$ROOT/apps/demo/src/Dockerfile"
  [ "$(grep -cE '^FROM [^ ]+@sha256:[0-9a-f]{64}( |$)' "$f")" = "$(grep -c '^FROM ' "$f")" ]
  grep -q 'GOFLAGS=-mod=readonly' "$f"
  grep -q 'CGO_ENABLED=0' "$f"
  grep -q 'go mod verify' "$f"
  grep -Eq 'go build -trimpath -buildvcs=false' "$f"
  for l in source revision version; do
    grep -q "org.opencontainers.image.$l=\"\${$(echo "$l" | tr '[:lower:]' '[:upper:]')}\"" "$f" || { echo "label $l"; false; }
  done
  grep -q 'org.opencontainers.image.licenses="MIT"' "$f"
  grep -q 'org.opencontainers.image.title="fleet-demo"' "$f"
  grep -q '^USER nonroot:nonroot' "$f"
}

@test ".dockerignore is an allowlist of the Go sources (no .git, tests, docs, env files or keys)" {
  f="$ROOT/apps/demo/src/.dockerignore"
  [ "$(grep -v '^#' "$f" | grep -v '^$' | head -n 1)" = "*" ]
  [ "$(grep '^!' "$f" | sort | tr '\n' ' ')" = '!*.go !go.mod !go.sum ' ]
  grep -qx '\*_test.go' "$f"
}

@test "check-absent fails closed (exit 2) when docker or buildx is missing or broken" {
  stub_docker
  printf 'ERROR: ghcr.io/o/fleet-demo:2.0.0: not found\n' > "$WORK/raw.err"
  DOCKER_BUILDX_RC=1 PATH="$WORK/bin:$PATH" run "$ROOT/scripts/release.sh" check-absent ghcr.io/o/fleet-demo:2.0.0
  [ "$status" -eq 2 ] || { echo "$status: $output"; false; }
  [[ "$output" == *"not usable"* ]] || false
  # no docker on PATH at all: "command not found" is not "not published"
  mkdir "$WORK/minpath"
  for c in bash env dirname; do ln -s "$(command -v "$c")" "$WORK/minpath/$c"; done
  PATH="$WORK/minpath" run "$ROOT/scripts/release.sh" check-absent ghcr.io/o/fleet-demo:2.0.0
  [ "$status" -eq 2 ] || { echo "$status: $output"; false; }
}
