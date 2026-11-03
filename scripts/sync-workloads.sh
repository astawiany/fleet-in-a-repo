#!/usr/bin/env bash
# Point every workload cluster of the active profile at its Flux entrypoint clusters/<name>/
# (idempotent; run after mgmt-up.sh has exported the workload kubeconfigs):
#   1. wait for the cluster's API server ($WORK/kubeconfigs/<name>.yaml)
#   2. flux install FLUX_VERSION (skipped when source-controller already exists)
#   3. ConfigMap flux-system/cluster-vars: METALLB_POOL (scripts/metallb-pool.sh) and the add-on
#      versions from versions.env, read by the Flux Kustomizations' postBuild.substituteFrom
#   4. kubectl apply -k clusters/<name>/flux-system: GitRepository flux-system (the offline git
#      server fleet-git, reachable from the node containers on the kind Docker network) and
#      Kustomization flux-system (path ./clusters/<name>), which from then on manage themselves.
# Needs the fleet-git container that mgmt-up.sh runs in offline mode (the default).
# Versions: versions.env (FLUX_VERSION, CERT_MANAGER_VERSION, GATEWAY_API_VERSION, NGF_VERSION,
#   METALLB_VERSION, KPS_VERSION).
# Profile settings in cluster-vars: KPS_SCRAPE_APISERVER=false for lite (the API server's
#   metrics are kube-prometheus-stack's largest series source and no dashboard or SLO uses them;
#   dropping them keeps Prometheus small enough for two clusters in an 8 GiB Docker VM), true for full.
# Env: FLEET_PROFILE (full|lite), FLEET_WORK_DIR (default <repo>/.work),
#      FLEET_WAIT_TIMEOUT seconds to wait for each API server (default 600).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$here/lib.sh"
# shellcheck source=/dev/null
source "$ROOT/versions.env"

ENVS="dev prod"
GIT_CONTAINER=fleet-git
WORK="${FLEET_WORK_DIR:-$ROOT/.work}"
TIMEOUT="${FLEET_WAIT_TIMEOUT:-600}"

log() { echo "sync-workloads: $*"; }
die() {
  echo "sync-workloads: $*" >&2
  exit 1
}

cust="$(customers)"
if [ "$FLEET_PROFILE" = lite ]; then scrape_apiserver=false; else scrape_apiserver=true; fi
names=""
for c in $cust; do
  for e in $ENVS; do
    names="$names $c-$e"
  done
done

if [ -z "$(docker ps -q --filter "name=^${GIT_CONTAINER}\$" --filter label=fleet-in-a-repo=1 \
  --filter status=running)" ]; then
  die "git server container $GIT_CONTAINER is not running; run scripts/mgmt-up.sh (offline mode) first"
fi
for n in $names; do
  [ -f "$WORK/kubeconfigs/$n.yaml" ] || die "no kubeconfig for $n at $WORK/kubeconfigs/$n.yaml; run scripts/mgmt-up.sh first"
done

for n in $names; do
  kc="--kubeconfig=$WORK/kubeconfigs/$n.yaml"

  deadline=$((SECONDS + TIMEOUT))
  until kubectl "$kc" get --raw /readyz > /dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || die "timed out after ${TIMEOUT}s waiting for the $n API server"
    sleep 5
  done

  if kubectl "$kc" -n flux-system get deployment source-controller > /dev/null 2>&1; then
    log "$n: Flux already installed"
  else
    flux install --version "v$FLUX_VERSION" "$kc"
  fi

  kubectl "$kc" -n flux-system create configmap cluster-vars \
    --from-literal=METALLB_POOL="$("$here/metallb-pool.sh" "$n")" \
    --from-literal=CERT_MANAGER_VERSION="$CERT_MANAGER_VERSION" \
    --from-literal=GATEWAY_API_VERSION="$GATEWAY_API_VERSION" \
    --from-literal=NGF_VERSION="$NGF_VERSION" \
    --from-literal=METALLB_VERSION="$METALLB_VERSION" \
    --from-literal=KPS_VERSION="$KPS_VERSION" \
    --from-literal=KPS_SCRAPE_APISERVER="$scrape_apiserver" \
    --dry-run=client -o yaml | kubectl "$kc" apply -f -

  kubectl "$kc" apply -k "$ROOT/clusters/$n/flux-system"
  log "$n: syncing clusters/$n"
done
