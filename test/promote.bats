#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/scripts" "$WORK/promotion"
  cp "$ROOT/scripts/promote.sh" "$WORK/scripts/" 2> /dev/null || true
  cp -R "$ROOT/promotion/versions" "$WORK/promotion/versions" 2> /dev/null || true
  mkdir -p "$WORK/promotion/versions"
  # distinct versions so a copy is observable
  printf 'chart:\n  version: 1.2.0\n' > "$WORK/promotion/versions/dev.yaml"
  printf 'chart:\n  version: 1.1.0\n' > "$WORK/promotion/versions/test.yaml"
  printf 'chart:\n  version: 1.0.0\n' > "$WORK/promotion/versions/prod.yaml"
  cd "$WORK"
  git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm base
}

teardown() { rm -rf "$WORK"; }

@test "promote dev->test changes only test.yaml" {
  run scripts/promote.sh dev test
  [ "$status" -eq 0 ]
  [[ "$output" == "bumped test to 1.2.0" ]] || false
  [ "$(git status --porcelain | wc -l | tr -d ' ')" = "1" ]
  [[ "$(git status --porcelain)" == *"promotion/versions/test.yaml" ]] || false
  [ "$(yq '.chart.version' promotion/versions/test.yaml)" = "1.2.0" ]
}

@test "promote when versions equal prints 'no change' and leaves the tree clean" {
  run scripts/promote.sh dev dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"no change"* ]] || false
  [ -z "$(git status --porcelain)" ]
}

@test "promote with unknown env exits non-zero naming the env" {
  run scripts/promote.sh dev staging
  [ "$status" -ne 0 ]
  [[ "$output" == *"staging"* ]] || false
  run scripts/promote.sh qa dev
  [ "$status" -ne 0 ]
  [[ "$output" == *"qa"* ]] || false
}

@test "HelmRelease for acme-prod renders chart version from prod.yaml" {
  # copy the build inputs and give the pins distinct versions so a wrong pick is detectable
  mkdir -p "$WORK/repo/apps" "$WORK/repo/promotion"
  cp -R "$ROOT/apps/demo" "$WORK/repo/apps/demo"
  cp -R "$ROOT/promotion/." "$WORK/repo/promotion/"
  V=1.0.0 yq -i '.chart.version = strenv(V)' "$WORK/repo/promotion/versions/dev.yaml"
  V=7.7.7 yq -i '.chart.version = strenv(V)' "$WORK/repo/promotion/versions/prod.yaml"
  want=7.7.7
  [ "$(yq '.chart.version' "$ROOT/promotion/versions/prod.yaml")" != "$want" ]
  out="$(kustomize build "$WORK/repo/apps/demo/flux/acme-prod")"
  got="$(echo "$out" | yq -N 'select(.kind=="HelmRelease") | .spec.chart.spec.version')"
  [ "$got" = "$want" ]
  [ "$(echo "$out" | yq -N 'select(.kind=="HelmRelease") | .spec.releaseName')" = "demo" ]
  # pins must not leak into the output
  [ "$(echo "$out" | yq -N 'select(.kind=="PromotionPin") | .metadata.name' | wc -l | tr -d ' ')" = "0" ]
  [ "$(echo "$out" | yq -N 'select(.kind=="HelmRelease") | .spec.valuesFrom[0].name')" = "demo-values-acme-prod" ]
  echo "$out" | yq -N 'select(.kind=="ConfigMap") | .data."values.yaml"' | grep -q 'replicas'
}
