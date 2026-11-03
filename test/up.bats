#!/usr/bin/env bats
# up.sh step 2 (demo image) against a scratch git copy of the repo: preflight.sh, mgmt-up.sh
# and sync-workloads.sh are replaced by no-ops; docker, kind and kubectl are stubbed.

bats_require_minimum_version 1.5.0

setup() {
  REAL_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  ROOT="$T/repo"
  STUBS="$T/stubs"
  export CALLS="$T/calls.log" STATE="$T/state"
  mkdir -p "$STUBS" "$STATE" "$ROOT/apps/demo" "$ROOT/promotion"
  : > "$CALLS"
  cp -R "$REAL_ROOT/scripts" "$REAL_ROOT/versions.env" "$ROOT/"
  cp -R "$REAL_ROOT/apps/demo/src" "$REAL_ROOT/apps/demo/chart" "$ROOT/apps/demo/"
  cp -R "$REAL_ROOT/promotion/versions" "$ROOT/promotion/"
  for s in preflight.sh mgmt-up.sh sync-workloads.sh; do printf '#!/bin/sh\nexit 0\n' > "$ROOT/scripts/$s"; done
  git -C "$ROOT" init -q
  git -C "$ROOT" add -A
  git -C "$ROOT" -c user.name=t -c user.email=t@example.invalid commit -q -m init
  unset GITHUB_REPOSITORY FLEET_FLUX_GITHUB
  export FLEET_PROFILE=lite FLEET_WORK_DIR="$T/work" FLEET_UP_TIMEOUT=5

  # docker: remembers each built image's fleet.src-hash label in $STATE/<image with / and : as _>.
  stub docker '
key() { echo "$STATE/$(echo "$1" | tr "/:" "__")"; }
for a; do last="$a"; done
case "$1 $2" in
  "image inspect")
    [ -f "$(key "$last")" ] || exit 1
    case "$*" in *--format*) cat "$(key "$last")" ;; esac ;;
  build*)
    label=""; tag=""; prev=""
    for a; do
      case "$prev" in --label) label="${a#fleet.src-hash=}" ;; -t) tag="$a" ;; esac
      prev="$a"
    done
    echo "$label" > "$(key "$tag")" ;;
esac
exit 0'
  stub kind 'exit 0'
  stub kubectl '
case "$*" in
  *"get kustomizations"*)
    echo "{\"items\": [
      {\"kind\": \"Kustomization\", \"metadata\": {\"name\": \"workload-clusters\"}, \"status\": {\"conditions\": [{\"type\": \"Ready\", \"status\": \"True\"}]}},
      {\"kind\": \"Kustomization\", \"metadata\": {\"name\": \"apps\"}, \"status\": {\"conditions\": [{\"type\": \"Ready\", \"status\": \"True\"}]}}]}" ;;
esac
exit 0'
}

stub() {
  printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n%s\n' "$1" "$2" > "$STUBS/$1"
  chmod +x "$STUBS/$1"
}

up() {
  PATH="$STUBS:$(dirname "$(command -v jq)"):/usr/bin:/bin" run --separate-stderr bash "$ROOT/scripts/up.sh"
}

image() { # the chart repository with the dev pin
  local repo
  repo="$(awk '/^image:/ { f = 1; next } f && $1 == "repository:" { print $2; exit }' "$ROOT/apps/demo/chart/values.yaml")"
  echo "$repo:$(awk '$1 == "version:" { print $2; exit }' "$ROOT/promotion/versions/dev.yaml")"
}

# Number of distinct images up.sh builds: one per distinct pinned version among the lite envs
# (dev and prod), so it is 2 while promotion is in flight and 1 once the pins agree.
n_images() {
  { awk '$1 == "version:" { print $2; exit }' "$ROOT/promotion/versions/dev.yaml"
    awk '$1 == "version:" { print $2; exit }' "$ROOT/promotion/versions/prod.yaml"; } | sort -u | wc -l | tr -d ' '
}

@test "up labels the demo image with a source hash and rebuilds only when apps/demo/src changes" {
  n="$(n_images)"
  up
  [ "$status" -eq 0 ]
  run grep -c "^docker build .*--label fleet.src-hash=[0-9a-f]\{12\} .*-t $(image) " "$CALLS"
  [ "$output" -eq 1 ]
  up
  [ "$status" -eq 0 ]
  run grep -c '^docker build' "$CALLS"
  [ "$output" -eq "$n" ] || false
  echo "// edited" >> "$ROOT/apps/demo/src/main.go"
  up
  [ "$status" -eq 0 ]
  run grep -c '^docker build' "$CALLS"
  [ "$output" -eq $((2 * n)) ] || false
  # the image is loaded into the nodes either way; running pods only change on a version bump
  grep -q "^kind load docker-image $(image) " "$CALLS"
}

@test "up reads the pins from git HEAD and warns when the working tree differs" {
  head_image="$(image)"
  sed -i.bak 's/^  version: .*/  version: 9.9.9/' "$ROOT/promotion/versions/dev.yaml"
  rm "$ROOT/promotion/versions/dev.yaml.bak"
  up
  [ "$status" -eq 0 ]
  up_stderr="$stderr"
  run grep -c "^docker build .*-t $head_image " "$CALLS"
  [ "$output" -eq 1 ] || false
  run grep -c ':9.9.9' "$CALLS"
  [ "$output" -eq 0 ] || false
  [[ "$up_stderr" == *"promotion/versions/dev.yaml"*"differs from HEAD"* ]] || false
}
