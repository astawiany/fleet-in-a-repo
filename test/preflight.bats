#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  for t in kind clusterctl flux helm kubectl kubeconform; do
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
