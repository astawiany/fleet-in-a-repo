#!/usr/bin/env bats
# smoke.sh / up.sh / down.sh against stubbed kubectl, curl, kind, docker and friends.
# Stubs append "<tool> <args>" to $CALLS; files in $STATE switch a stub to a broken variant.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIX="$ROOT/test/fixtures/smoke"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  export CALLS="$BATS_TEST_TMPDIR/calls.log"
  export STATE="$BATS_TEST_TMPDIR/state"
  export FIX
  export FLEET_WORK_DIR="$BATS_TEST_TMPDIR/work"
  export KUBECONFIG="$BATS_TEST_TMPDIR/home-kubeconfig"
  mkdir -p "$STUBS" "$STATE"
  : > "$CALLS"
  unset GITHUB_REPOSITORY FLEET_FLUX_GITHUB
  export FLEET_PROFILE=lite
  # keep the polling loops short
  export SMOKE_RESILIENCE_TIMEOUT=5 SMOKE_RETRY_TIMEOUT=2 SMOKE_POLL=1

  # kubectl: answers by argument shape; $KUBECONFIG tells which cluster is asked.
  stub kubectl '
fix() { cat "$FIX/$1"; }
case "$*" in
  *"get kustomizations"*)
    case "$KUBECONFIG" in
      *acme-prod*) if [ -f "$STATE/hr-broken" ]; then fix flux-hr-notready.json; else fix flux-ready.json; fi ;;
      *) fix flux-ready.json ;;
    esac ;;
  *"get deployment demo-web demo-api demo-worker"*)
    if [ -f "$STATE/no-label" ]; then
      fix deployments.json | sed "s#\"app.kubernetes.io/part-of\": \"fleet-demo\",##"
    else fix deployments.json; fi ;;
  *"get networkpolicies"*)
    if [ -f "$STATE/no-deny" ]; then fix netpols-no-deny.json; else fix netpols.json; fi ;;
  *port-forward*)
    echo "Forwarding from 127.0.0.1:43210 -> 8080"
    exec sleep 30 ;;
  *"get deployment demo-api -o jsonpath"*) echo 1 ;;
  *"delete pod"*) touch "$STATE/deleted-${KUBECONFIG##*/}" ;;
  *"get pods -l"*)
    if [ -f "$STATE/deleted-${KUBECONFIG##*/}" ] && [ ! -f "$STATE/no-recover" ]; then fix pods-api-after.json; else fix pods-api.json; fi ;;
  *"get pods -o json"*)
    if [ -f "$STATE/privileged" ]; then fix pods-privileged.json; else fix pods.json; fi ;;
  *"get --raw"*)
    if [ -f "$STATE/target-down" ]; then fix targets-down.json; else fix targets.json; fi ;;
  *"get secret kube-prometheus-stack-grafana"*) fix grafana-secret.json ;;
  *) exit 0 ;;
esac'
  stub curl '
case "$*" in
  *"/api/dashboards/uid/"*) printf 200 ;;
  *"/feature"*) if [ -f "$STATE/slow" ]; then echo "200 0.350"; else echo "200 0.012"; fi ;;
  *) exit 7 ;;
esac'
}

# stub NAME BODY: write an executable that logs its call, then runs BODY.
stub() {
  printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n%s\n' "$1" "$2" > "$STUBS/$1"
  chmod +x "$STUBS/$1"
}

kubeconfigs() {
  mkdir -p "$FLEET_WORK_DIR/kubeconfigs"
  touch "$FLEET_WORK_DIR/kubeconfigs/acme-dev.yaml" "$FLEET_WORK_DIR/kubeconfigs/acme-prod.yaml"
}

script() { # script [args...]
  local s="$1"
  shift
  PATH="$STUBS:$(dirname "$(command -v jq)"):/usr/bin:/bin" run --separate-stderr bash "$ROOT/scripts/$s" "$@"
}

@test "smoke fails and names HelmRelease demo/acme-prod when it is not Ready" {
  kubeconfigs
  touch "$STATE/hr-broken"
  script smoke.sh
  [ "$status" -ne 0 ]
  run grep -E '^FAIL flux acme-prod .*HelmRelease demo/acme-prod' <<< "$output"
  [ "$status" -eq 0 ]
  # the healthy cluster and the Ready kube-prometheus-stack are not blamed
  run grep -E '^FAIL flux acme-dev|kube-prometheus-stack' <<< "$output"
  [ "$status" -eq 1 ]
}

@test "smoke prints one PASS/FAIL line per criterion per cluster" {
  kubeconfigs
  script smoke.sh
  [ "$status" -eq 0 ]
  lines_pf="$(grep -E '^(PASS|FAIL) ' <<< "$output")"
  [ "$(wc -l <<< "$lines_pf" | tr -d ' ')" -eq 12 ]
  for c in acme-dev acme-prod; do
    for k in flux compliance performance resilience observability security; do
      [ "$(grep -cE "^(PASS|FAIL) $k $c( |\$)" <<< "$lines_pf")" -eq 1 ]
    done
  done
  run grep -c '^FAIL' <<< "$output"
  [ "$output" -eq 0 ]
}

@test "smoke compliance fails and names a Deployment missing a required label" {
  kubeconfigs
  touch "$STATE/no-label"
  script smoke.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL compliance acme-dev deployment/demo-web"*"app.kubernetes.io/part-of"* ]] || false
}

@test "smoke performance fails when p95 of /feature is over 200 ms" {
  kubeconfigs
  touch "$STATE/slow"
  script smoke.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL performance acme-dev"*"p95=350"* ]] || false
  # 200 requests per cluster (the stub's sh echo splits each logged call at the -w newline)
  [ "$(grep -c '127.0.0.1:43210/feature' "$CALLS")" -eq 400 ]
}

@test "smoke resilience fails when the api Deployment does not recover in time" {
  kubeconfigs
  touch "$STATE/no-recover"
  script smoke.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL resilience acme-dev deployment/demo-api"* ]] || false
  grep -q '^kubectl -n demo delete pod demo-api-old' "$CALLS"
}

@test "smoke observability fails and names a down Prometheus target" {
  kubeconfigs
  touch "$STATE/target-down"
  script smoke.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL observability acme-dev"*"serviceMonitor/demo/demo-api/0"* ]] || false
}

@test "smoke security fails on a privileged pod and on a missing default-deny policy" {
  kubeconfigs
  touch "$STATE/privileged"
  script smoke.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL security acme-dev pod/demo-worker-1"* ]] || false
  rm "$STATE/privileged"
  touch "$STATE/no-deny"
  script smoke.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL security acme-dev"*"default-deny"* ]] || false
}

@test "smoke fails every criterion of a cluster without a kubeconfig" {
  script smoke.sh
  [ "$status" -ne 0 ]
  [ "$(grep -c '^FAIL ' <<< "$output")" -eq 12 ]
}

@test "up stops at preflight failure before creating anything" {
  for t in kind clusterctl flux helm kubectl kubeconform git; do stub "$t" ''; done
  stub docker '
case "$1" in
  info) echo 1073741824 ;;  # 1 GiB: below every profile minimum
esac'
  script up.sh
  [ "$status" -ne 0 ]
  [[ "$stderr" == *preflight* ]] || false
  run grep -E '^(kind create|kind load|clusterctl|flux|docker (build|run)|kubectl|git)' "$CALLS"
  [ "$status" -eq 1 ]
  [ ! -e "$FLEET_WORK_DIR" ]
}

@test "down on an empty machine exits 0" {
  stub kind 'echo "No kind clusters found." >&2'
  stub docker 'exit 0'
  stub kubectl 'exit 0'
  script down.sh
  [ "$status" -eq 0 ]
  [ ! -e "$FLEET_WORK_DIR" ]
  run grep -E '^(kind delete|docker rm|kubectl config delete)' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "down removes the work dir and only the fleet kubeconfig contexts" {
  mkdir -p "$FLEET_WORK_DIR/kubeconfigs"
  stub kind 'echo "No kind clusters found." >&2'
  stub docker 'exit 0'
  stub kubectl '
case "$*" in
  "config get-contexts -o name") printf "kind-fleet-mgmt\nacme-dev-admin@acme-dev\nglobex-prod-admin@globex-prod\nmy-own\n" ;;
esac'
  script down.sh
  [ "$status" -eq 0 ]
  [ ! -e "$FLEET_WORK_DIR" ]
  grep -qx 'kubectl config delete-context kind-fleet-mgmt' "$CALLS"
  grep -qx 'kubectl config delete-context acme-dev-admin@acme-dev' "$CALLS"
  grep -qx 'kubectl config delete-context globex-prod-admin@globex-prod' "$CALLS"
  run grep -c 'my-own' "$CALLS"
  [ "$output" -eq 0 ]
}
