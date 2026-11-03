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
  unset FLEET_PROFILE GITHUB_REPOSITORY FLEET_FLUX_GITHUB KUBECONFIG

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
for a; do last="$a"; done
case "$1 $2" in
  "image inspect") grep -qx "$last" "$STATE/images" 2> /dev/null ;;
  build*) echo "$4" >> "$STATE/images" ;;
  port*) echo "0.0.0.0:55000" ;;
  run*) echo "$last" > "$STATE/git-server" ;;
  rm*) rm -f "$STATE/git-server" ;;
  ps*)
    case "$*" in
      *fleet-git*--format*) cat "$STATE/git-server" 2> /dev/null ;;
      *fleet-git*) [ -f "$STATE/git-server" ] && echo abc123 ;;
    esac
    exit 0 ;;
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

# copy_repo: point ROOT at a scratch copy of the files the scripts read, so a test may edit them.
copy_repo() {
  local copy="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$copy"
  cp -R "$ROOT/scripts" "$ROOT/capi" "$ROOT/kind" "$ROOT/versions.env" "$copy/"
  ROOT="$copy"
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
  run grep -c 'customers/acme-dev.yaml' "$CALLS"
  [ "$output" -ge 1 ]
  run grep -c 'customers/acme-prod.yaml' "$CALLS"
  [ "$output" -ge 1 ]
  run grep -c globex "$CALLS"
  [ "$output" -eq 0 ]
  [ -f "$FLEET_WORK_DIR/kubeconfigs/acme-dev.yaml" ]
  [ ! -e "$FLEET_WORK_DIR/kubeconfigs/globex-dev.yaml" ]
}

@test "mgmt-up with the full profile references globex too" {
  mgmt mgmt-up.sh
  [ "$status" -eq 0 ]
  run grep -c 'customers/globex-prod.yaml' "$CALLS"
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

@test "mgmt-up applies the kindnet ClusterResourceSet with versions.env substituted" {
  FLEET_PROFILE=lite mgmt mgmt-up.sh
  [ "$status" -eq 0 ]
  run grep -c 'kubectl apply .*rendered/cni/kindnet.yaml' "$CALLS"
  [ "$output" -eq 1 ]
  run grep -c 'kind: ClusterResourceSet' "$FLEET_WORK_DIR/rendered/cni/kindnet.yaml"
  [ "$output" -eq 1 ]
  # shellcheck source=/dev/null
  source "$ROOT/versions.env"
  run grep -c "image: $KINDNETD_IMAGE\$" "$FLEET_WORK_DIR/rendered/cni/kindnet.yaml"
  [ "$output" -eq 1 ]
  run grep -c "version: $WORKLOAD_K8S_VERSION\$" "$FLEET_WORK_DIR/rendered/customers/acme-dev.yaml"
  [ "$output" -eq 1 ]
  run grep -rc '\${' "$FLEET_WORK_DIR/rendered"
  [ "$(printf '%s\n' "$output" | grep -vc ':0$')" -eq 0 ]
}

@test "every customer Cluster carries the fleet/cni: kindnet label" {
  n=0
  for f in "$ROOT"/capi/customers/*.yaml; do
    run grep -c '^    fleet/cni: kindnet$' "$f"
    [ "$output" -eq 1 ]
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
}

@test "no kindest image, digest or Kubernetes version is hard-coded outside versions.env" {
  run grep -rEn 'kindest/(node|kindnetd):v[0-9]|sha256:7416a61b|v1\.[0-9]+\.[0-9]+' \
    "$ROOT/capi" "$ROOT/kind" "$ROOT/scripts"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "mgmt-up passes versions.env values to kind and flux install" {
  # shellcheck source=/dev/null
  source "$ROOT/versions.env"
  mgmt mgmt-up.sh
  [ "$status" -eq 0 ]
  run grep -c "^kind create cluster .*--image $KIND_NODE_IMAGE" "$CALLS"
  [ "$output" -eq 1 ]
  run grep -c "^flux install --version v$FLUX_VERSION\$" "$CALLS"
  [ "$output" -eq 1 ]
}

@test "git server image is rebuilt when kind/git-server changes, not otherwise" {
  copy_repo
  mgmt mgmt-up.sh
  [ "$status" -eq 0 ]
  mgmt mgmt-up.sh
  [ "$status" -eq 0 ]
  run grep -c '^docker build' "$CALLS"
  [ "$output" -eq 1 ]
  echo "# changed" >> "$ROOT/kind/git-server/Dockerfile"
  mgmt mgmt-up.sh
  [ "$status" -eq 0 ]
  run grep -c '^docker build' "$CALLS"
  [ "$output" -eq 2 ]
  run grep -c '^docker run .*--label fleet-in-a-repo=1' "$CALLS"
  [ "$output" -eq 2 ]
}

@test "GITHUB_REPOSITORY alone never triggers flux bootstrap" {
  GITHUB_REPOSITORY=owner/repo mgmt mgmt-up.sh
  [ "$status" -eq 0 ]
  run grep -c '^flux bootstrap' "$CALLS"
  [ "$output" -eq 0 ]
}

@test "FLEET_FLUX_GITHUB opts in to flux bootstrap github with token auth" {
  FLEET_FLUX_GITHUB=owner/repo mgmt mgmt-up.sh
  [ "$status" -eq 0 ]
  run grep -c '^flux bootstrap github .*--owner owner --repository repo .*--token-auth' "$CALLS"
  [ "$output" -eq 1 ]
}
