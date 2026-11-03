#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIX="$ROOT/test/fixtures"
}

@test "validate fails naming \"Acme_Prod\" for an invalid cluster dir name" {
  run "$ROOT/scripts/validate.sh" "$FIX/bad-name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Acme_Prod"* ]]
}

@test "validate fails on a capi/customers file with an invalid name" {
  d="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$d/capi/customers"
  : > "$d/capi/customers/Bad_Name.yaml"
  run "$ROOT/scripts/validate.sh" "$d"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Bad_Name"* ]]
}

@test "validate fails on a manifest with an unknown field" {
  run "$ROOT/scripts/validate.sh" "$FIX/bad-field"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bad-field"* ]]
}

@test "validate passes on the existing chart and values" {
  run "$ROOT/scripts/validate.sh" "$ROOT/apps/demo"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "validate passes on the repo" {
  skip "enabled in Task 6"
  run "$ROOT/scripts/validate.sh"
  [ "$status" -eq 0 ]
}
