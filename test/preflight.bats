#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  for t in kind clusterctl flux helm kubectl kubeconform jq yq git curl; do
    printf '#!/bin/sh\nexit 0\n' > "$STUBS/$t"
    chmod +x "$STUBS/$t"
  done
  make_docker 17179869184 # 16 GiB
  unset FLEET_PROFILE
}

make_docker() {
  printf '#!/bin/sh\necho %s\n' "$1" > "$STUBS/docker"
  chmod +x "$STUBS/docker"
}

# version_stub TOOL OUTPUT: TOOL prints OUTPUT for any arguments (e.g. "flux version --client").
version_stub() {
  printf '#!/bin/sh\necho "%s"\n' "$2" > "$STUBS/$1"
  chmod +x "$STUBS/$1"
}

# Run preflight with only the stub dir (plus system essentials) on PATH.
run_preflight() {
  PATH="$STUBS:/usr/bin:/bin" run bash "$ROOT/scripts/preflight.sh" "$@"
}

@test "preflight fails naming \"kind\" when kind is missing from PATH" {
  rm "$STUBS/kind"
  run_preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"kind"* ]] || false
}

@test "preflight fails and mentions \"--profile lite\" when Docker memory < 8 GiB (stub docker info)" {
  make_docker 7516192768 # 7 GiB
  run_preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"--profile lite"* ]] || false
}

@test "preflight passes with all stubs present" {
  run_preflight
  [ "$status" -eq 0 ]
}

@test "lite profile passes with 7 GiB" {
  make_docker 7516192768
  run_preflight --profile lite
  [ "$status" -eq 0 ]
}

@test "lite profile fails below 6 GiB" {
  make_docker 4294967296
  run_preflight --profile lite
  [ "$status" -eq 1 ]
}

@test "unknown profile is rejected" {
  run_preflight --profile bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"bogus"* ]] || false
}

@test "customers prints acme and globex for full, acme for lite" {
  run env FLEET_PROFILE=full bash -c "source '$ROOT/scripts/lib.sh'; customers"
  [ "$output" = $'acme\nglobex' ]
  run env FLEET_PROFILE=lite bash -c "source '$ROOT/scripts/lib.sh'; customers"
  [ "$output" = "acme" ]
}

@test "preflight fails naming jq when jq is missing from PATH" {
  rm "$STUBS/jq"
  run_preflight --profile lite
  [ "$status" -eq 1 ]
  [[ "$output" == *"'jq'"* ]] || false
}

@test "preflight requires jq, yq, git and curl besides the cluster tools" {
  for t in jq yq git curl; do
    grep -Eq "^for tool in .*[[:space:]]$t([[:space:]]|;)" "$ROOT/scripts/preflight.sh" || { echo "$t not checked"; false; }
  done
}

@test "preflight warns, but passes, when flux/kind/clusterctl differ from versions.env" {
  # shellcheck source=/dev/null
  source "$ROOT/versions.env"
  version_stub flux "flux: v$FLUX_VERSION"
  version_stub kind "kind v$KIND_VERSION go1.25.4 darwin/arm64"
  version_stub clusterctl "v$CLUSTERCTL_VERSION"
  run_preflight --profile lite
  [ "$status" -eq 0 ]
  [[ "$output" != *WARNING* ]] || false
  version_stub flux "flux: v2.9.0"
  run_preflight --profile lite
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"*"flux"*"2.9.0"*"$FLUX_VERSION"* ]] || false
  [[ "$output" != *"WARNING"*"kind"* ]] || false
}
