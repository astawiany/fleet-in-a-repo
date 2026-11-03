#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIX="$ROOT/test/fixtures"
}

# Schemas come from the network on first use; skip when unreachable and uncached.
need_schemas() {
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/fleet-in-a-repo/kubeconform"
  if ! curl -sf --max-time 5 -o /dev/null https://raw.githubusercontent.com \
    && [ -z "$(ls -A "$cache" 2>/dev/null)" ]; then
    skip "kubeconform schema host unreachable and cache is empty"
  fi
}

# Build a tree with clusters/<name>/ under the tmpdir and validate it.
validate_cluster_name() {
  mkdir -p "$BATS_TEST_TMPDIR/tree/clusters/$1"
  run "$ROOT/scripts/validate.sh" "$BATS_TEST_TMPDIR/tree"
}

@test "validate fails naming \"Acme_Prod\" for an invalid cluster dir name" {
  run "$ROOT/scripts/validate.sh" "$FIX/bad-name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL [name-rule]"* ]]
  [[ "$output" == *"Acme_Prod"* ]]
}

@test "validate fails on a capi/customers file with an invalid name" {
  d="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$d/capi/customers"
  : > "$d/capi/customers/Bad_Name.yaml"
  run "$ROOT/scripts/validate.sh" "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL [name-rule]"* ]]
  [[ "$output" == *"Bad_Name"* ]]
}

@test "validate fails on a manifest with an unknown field" {
  need_schemas
  run "$ROOT/scripts/validate.sh" "$FIX/bad-field"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL [kubeconform]"* ]]
  [[ "$output" == *"bogusField"* ]]
}

@test "validate passes on the existing chart and values" {
  need_schemas
  run "$ROOT/scripts/validate.sh" "$ROOT/apps/demo"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "name rule: 64-character name fails" {
  n="a$(printf 'b%.0s' $(seq 63))"
  [ "${#n}" -eq 64 ]
  validate_cluster_name "$n"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL [name-rule]"* ]]
  [[ "$output" == *"$n"* ]]
}

@test "name rule: 63-character name passes" {
  n="a$(printf 'b%.0s' $(seq 62))"
  [ "${#n}" -eq 63 ]
  validate_cluster_name "$n"
  [ "$status" -eq 0 ]
}

@test "name rule: leading digit fails" {
  validate_cluster_name "1acme"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL [name-rule]"* ]]
  [[ "$output" == *"1acme"* ]]
}

@test "name rule: acme-prod passes" {
  validate_cluster_name "acme-prod"
  [ "$status" -eq 0 ]
}

@test "validate fails naming the tool when kustomize is missing from PATH" {
  stubs="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$stubs"
  for t in kubeconform helm; do
    printf '#!/bin/sh\nexit 0\n' > "$stubs/$t"
    chmod +x "$stubs/$t"
  done
  PATH="$stubs:/usr/bin:/bin" run "$ROOT/scripts/validate.sh" "$FIX/bad-name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"kustomize"* ]]
}

@test "validate passes on the repo" {
  skip "enabled in Task 6"
  run "$ROOT/scripts/validate.sh"
  [ "$status" -eq 0 ]
}
