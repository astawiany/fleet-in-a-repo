#!/usr/bin/env bats
# scripts/metallb-pool.sh against a stubbed `docker network inspect kind`.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"
  subnets "172.18.0.0/16 fc00:f853:ccd:e793::/64"
}

# subnets "LIST": the stubbed docker prints LIST for the kind network's IPAM subnets.
subnets() {
  printf '#!/bin/sh\n[ "$1 $2 $3" = "network inspect kind" ] || exit 1\necho "%s "\n' "$1" > "$STUBS/docker"
  chmod +x "$STUBS/docker"
}

pool() {
  PATH="$STUBS:/usr/bin:/bin" run bash "$ROOT/scripts/metallb-pool.sh" "$@"
}

@test "acme-dev gets the first /28 of the top /24 of the kind subnet" {
  pool acme-dev
  [ "$status" -eq 0 ]
  [ "$output" = "172.18.255.0/28" ]
}

@test "pools are deterministic" {
  pool globex-prod
  first="$output"
  pool globex-prod
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
}

@test "every customer cluster gets a distinct pool inside the subnet" {
  got=""
  for f in "$ROOT"/capi/customers/*.yaml; do
    pool "$(basename "$f" .yaml)"
    [ "$status" -eq 0 ]
    [[ "$output" == 172.18.255.*/28 ]] || false
    got="$got$output"$'\n'
  done
  [ "$(printf '%s' "$got" | sort -u | wc -l)" -eq 4 ]
  [ "$got" = $'172.18.255.0/28\n172.18.255.16/28\n172.18.255.32/28\n172.18.255.48/28\n' ]
}

@test "the slice follows the subnet: 10.89.0.0/20 puts acme-prod at 10.89.15.16/28" {
  subnets "10.89.0.0/20"
  pool acme-prod
  [ "$status" -eq 0 ]
  [ "$output" = "10.89.15.16/28" ]
}

@test "an unknown cluster name fails" {
  pool initech-dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"initech-dev"* ]] || false
}

@test "a subnet smaller than /23 fails" {
  subnets "172.30.0.0/24"
  pool acme-dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"/24"* ]] || false
}

@test "no IPv4 subnet on the kind network fails" {
  subnets "fc00:f853:ccd:e793::/64"
  pool acme-dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"IPv4"* ]] || false
}

@test "missing argument prints usage and fails" {
  pool
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]] || false
}
