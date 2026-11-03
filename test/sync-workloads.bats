#!/usr/bin/env bats
# scripts/sync-workloads.sh against stubbed flux, kubectl and docker.
# Stubs append "<tool> <args>" to $CALLS; kubectl apply also saves its stdin to $STATE/applied.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  export CALLS="$BATS_TEST_TMPDIR/calls.log"
  export STATE="$BATS_TEST_TMPDIR/state"
  export FLEET_WORK_DIR="$BATS_TEST_TMPDIR/work"
  mkdir -p "$STUBS" "$STATE" "$FLEET_WORK_DIR/kubeconfigs"
  : > "$CALLS"
  echo running > "$STATE/git-server"
  unset FLEET_PROFILE GITHUB_REPOSITORY FLEET_FLUX_GITHUB KUBECONFIG
  for c in acme-dev acme-prod globex-dev globex-prod; do
    echo "kind: Config" > "$FLEET_WORK_DIR/kubeconfigs/$c.yaml"
  done

  # flux install marks the cluster (by kubeconfig path) as having Flux.
  stub flux '
case "$*" in
  *install*) for a; do case "$a" in --kubeconfig=*) touch "$STATE/flux-$(basename "${a#*=}")" ;; esac; done ;;
esac'
  stub kubectl '
kc=""
for a; do case "$a" in --kubeconfig=*) kc="$(basename "${a#*=}")" ;; esac; done
case "$*" in
  *source-controller*) [ -f "$STATE/flux-$kc" ] ;;
  *"apply -f -"*) cat >> "$STATE/applied" ;;
  *) exit 0 ;;
esac'
  stub docker '
case "$1 $2" in
  "network inspect") echo "172.18.0.0/16 fc00:f853:ccd:e793::/64 " ;;
  ps*) [ -f "$STATE/git-server" ] && echo abc123; exit 0 ;;
esac'
}

# stub NAME BODY: write an executable that logs its call, then runs BODY.
stub() {
  printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n%s\n' "$1" "$2" > "$STUBS/$1"
  chmod +x "$STUBS/$1"
}

sync() {
  PATH="$STUBS:/usr/bin:/bin" run --separate-stderr bash "$ROOT/scripts/sync-workloads.sh" "$@"
}

@test "lite profile syncs only the acme clusters" {
  FLEET_PROFILE=lite sync
  [ "$status" -eq 0 ]
  run grep -c 'kubeconfigs/acme-dev.yaml' "$CALLS"
  [ "$output" -ge 1 ]
  run grep -c 'kubeconfigs/acme-prod.yaml' "$CALLS"
  [ "$output" -ge 1 ]
  run grep -c globex "$CALLS"
  [ "$output" -eq 0 ]
}

@test "full profile syncs all four clusters" {
  sync
  [ "$status" -eq 0 ]
  for c in acme-dev acme-prod globex-dev globex-prod; do
    run grep -c "^kubectl .*kubeconfigs/$c.yaml.* apply -k $ROOT/clusters/$c/flux-system\$" "$CALLS"
    [ "$output" -eq 1 ]
  done
}

@test "flux is installed at FLUX_VERSION once per cluster across two runs" {
  # shellcheck source=/dev/null
  source "$ROOT/versions.env"
  FLEET_PROFILE=lite sync
  [ "$status" -eq 0 ]
  FLEET_PROFILE=lite sync
  [ "$status" -eq 0 ]
  run grep -c "^flux install --version v$FLUX_VERSION .*acme-dev.yaml" "$CALLS"
  [ "$output" -eq 1 ]
  run grep -c '^flux install' "$CALLS"
  [ "$output" -eq 2 ]
}

@test "cluster-vars carries the cluster's MetalLB pool and the add-on versions" {
  # shellcheck source=/dev/null
  source "$ROOT/versions.env"
  FLEET_PROFILE=lite sync
  [ "$status" -eq 0 ]
  line="$(grep '^kubectl .*acme-prod.yaml.* create configmap cluster-vars' "$CALLS")"
  [[ "$line" == *"-n flux-system"* ]] || false
  [[ "$line" == *"--from-literal=METALLB_POOL=172.18.255.16/28 "* ]] || false
  [[ "$line" == *"--from-literal=CERT_MANAGER_VERSION=$CERT_MANAGER_VERSION "* ]] || false
  [[ "$line" == *"--from-literal=GATEWAY_API_VERSION=$GATEWAY_API_VERSION "* ]] || false
  [[ "$line" == *"--from-literal=NGF_VERSION=$NGF_VERSION "* ]] || false
  [[ "$line" == *"--from-literal=METALLB_VERSION=$METALLB_VERSION "* ]] || false
  [[ "$line" == *"--from-literal=KPS_VERSION=$KPS_VERSION "* ]] || false
}

@test "every \${VAR} in infrastructure/ is a cluster-vars key or has a default" {
  FLEET_PROFILE=lite sync
  [ "$status" -eq 0 ]
  keys="$(grep -m1 'create configmap cluster-vars' "$CALLS" | grep -oE -- '--from-literal=[A-Z_]+' | cut -d= -f2)"
  vars="$(grep -rhoE '\$\{[A-Z_]+\}' "$ROOT/infrastructure" | tr -d '${}' | sort -u)"
  [ -n "$vars" ]
  for v in $vars; do
    printf '%s\n' "$keys" | grep -qx "$v"
  done
}

@test "a missing kubeconfig fails naming the cluster" {
  rm "$FLEET_WORK_DIR/kubeconfigs/acme-prod.yaml"
  FLEET_PROFILE=lite sync
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"acme-prod"* ]] || false
}

@test "fails before touching any cluster when the fleet-git server is not running" {
  rm "$STATE/git-server"
  FLEET_PROFILE=lite sync
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"fleet-git"* ]] || false
  run grep -c -E '^(flux|kubectl) ' "$CALLS"
  [ "$output" -eq 0 ]
}
