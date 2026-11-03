#!/usr/bin/env bats
# mgmt-up.sh / mgmt-down.sh against stubbed kind, clusterctl, flux, docker, kubectl and git.
# Stubs append "<tool> <args>" to $CALLS and keep minimal state in $STATE.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  export CALLS="$BATS_TEST_TMPDIR/calls.log"
  export STATE="$BATS_TEST_TMPDIR/state"
  export FLEET_WORK_DIR="$BATS_TEST_TMPDIR/work"
  mkdir -p "$STUBS" "$STATE"
  : > "$CALLS"
  unset FLEET_PROFILE GITHUB_REPOSITORY KUBECONFIG

  stub kind '
case "$1 $2" in
  "get clusters")
    if [ -f "$STATE/kind" ]; then echo fleet-mgmt; else echo "No kind clusters found." >&2; fi ;;
  "create cluster") touch "$STATE/kind" ;;
  "delete cluster") rm -f "$STATE/kind" ;;
esac'
  stub clusterctl '
case "$1" in
  init) touch "$STATE/capi" ;;
  get) printf "apiVersion: v1\nkind: Config\nclusters:\n- cluster:\n    server: https://172.18.0.9:6443\n  name: c\n" ;;
esac'
  stub flux '
case "$1" in
  install) touch "$STATE/flux" ;;
  create) echo "kind: GitRepository" ;;
esac'
  stub kubectl '
case "$*" in
  *capd-controller-manager*) [ -f "$STATE/capi" ] ;;
  *source-controller*) [ -f "$STATE/flux" ] ;;
  *) exit 0 ;;
esac'
  stub docker '
case "$1" in
  port) echo "0.0.0.0:55000" ;;
  run) touch "$STATE/git-server" ;;
  ps) case "$*" in *fleet-git*) [ -f "$STATE/git-server" ] && echo abc123 ;; esac; exit 0 ;;
esac'
  stub git ''
}

# stub NAME BODY: write an executable that logs its call, then runs BODY.
stub() {
  printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n%s\n' "$1" "$2" > "$STUBS/$1"
  chmod +x "$STUBS/$1"
}

mgmt() { # script [args...]
  local script="$1"
  shift
  PATH="$STUBS:/usr/bin:/bin" run --separate-stderr bash "$ROOT/scripts/$script" "$@"
}

@test "mgmt-up twice calls kind create once" {
  mgmt mgmt-up.sh
  [ "$status" -eq 0 ]
  mgmt mgmt-up.sh
  [ "$status" -eq 0 ]
  run grep -c '^kind create cluster' "$CALLS"
  [ "$output" -eq 1 ]
  run grep -c '^clusterctl init' "$CALLS"
  [ "$output" -eq 1 ]
  run grep -c '^flux install' "$CALLS"
  [ "$output" -eq 1 ]
}

@test "mgmt-down with no cluster exits 0 and prints nothing to stderr" {
  mgmt mgmt-down.sh
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  run grep -c '^kind delete' "$CALLS"
  [ "$output" -eq 0 ]
}

@test "mgmt-down deletes an existing fleet-mgmt cluster and removes the work dir" {
  touch "$STATE/kind"
  mkdir -p "$FLEET_WORK_DIR/kubeconfigs"
  mgmt mgmt-down.sh
  [ "$status" -eq 0 ]
  run grep -c '^kind delete cluster --name fleet-mgmt' "$CALLS"
  [ "$output" -eq 1 ]
  [ ! -e "$FLEET_WORK_DIR" ]
}

@test "mgmt-up with FLEET_PROFILE=lite only references the acme cluster" {
  FLEET_PROFILE=lite mgmt mgmt-up.sh
  [ "$status" -eq 0 ]
  run grep -c 'capi/customers/acme-dev.yaml' "$CALLS"
  [ "$output" -ge 1 ]
  run grep -c 'capi/customers/acme-prod.yaml' "$CALLS"
  [ "$output" -ge 1 ]
  run grep -c globex "$CALLS"
  [ "$output" -eq 0 ]
  [ -f "$FLEET_WORK_DIR/kubeconfigs/acme-dev.yaml" ]
  [ ! -e "$FLEET_WORK_DIR/kubeconfigs/globex-dev.yaml" ]
}

@test "mgmt-up with the full profile references globex too" {
  mgmt mgmt-up.sh
  [ "$status" -eq 0 ]
  run grep -c 'capi/customers/globex-prod.yaml' "$CALLS"
  [ "$output" -ge 1 ]
}

@test "mgmt-up rewrites workload kubeconfig server to the published load balancer port" {
  FLEET_PROFILE=lite mgmt mgmt-up.sh
  [ "$status" -eq 0 ]
  run grep 'server:' "$FLEET_WORK_DIR/kubeconfigs/acme-dev.yaml"
  [ "$output" = "    server: https://127.0.0.1:55000" ]
}

@test "mgmt-up offline mode never calls flux bootstrap" {
  mgmt mgmt-up.sh
  [ "$status" -eq 0 ]
  run grep -c '^flux bootstrap' "$CALLS"
  [ "$output" -eq 0 ]
}
