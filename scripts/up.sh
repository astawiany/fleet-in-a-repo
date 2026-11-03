#!/usr/bin/env bash
# Bring the whole fleet up (idempotent; safe to re-run):
#   1. preflight.sh: tools and Docker memory for FLEET_PROFILE; on failure nothing is created
#   2. build the demo image (apps/demo/src) as <chart image.repository>:<pin> for every pin of
#      promotion/versions/{dev,prod}.yaml; skipped when the image already exists
#   3. mgmt-up.sh: kind management cluster, Cluster API, Flux, offline git server, kubeconfigs
#   4. wait until every workload Cluster of the profile is Available (control plane + workers)
#   5. kind load the demo image into each workload cluster's nodes (no registry offline; the chart
#      uses the default pull policy IfNotPresent for a non-latest tag, so the loaded image is used)
#   6. sync-workloads.sh: Flux in every workload cluster
#   7. wait until every Flux Kustomization and HelmRelease is Ready (management included; the
#      workload clusters' `apps` Kustomization must exist, i.e. the full tree was applied)
# Env: FLEET_PROFILE (full|lite), FLEET_WORK_DIR (default <repo>/.work),
#      FLEET_UP_TIMEOUT seconds for each wait of steps 4 and 7 (default 1500).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$here/lib.sh"

ENVS="dev prod"
NS=fleet
WORK="$(fleet_work_dir "$ROOT")"
TIMEOUT="${FLEET_UP_TIMEOUT:-1500}"
MGMT_KC="$WORK/mgmt.kubeconfig"
t0=$SECONDS

log() { echo "up: [$(((SECONDS - t0) / 60))m$(((SECONDS - t0) % 60))s] $*"; }
die() {
  echo "up: $*" >&2
  exit 1
}

# 1. Nothing is created before preflight passes.
"$here/preflight.sh" --profile "$FLEET_PROFILE"

cust="$(customers)"
names=""
for c in $cust; do
  for e in $ENVS; do
    names="$names $c-$e"
  done
done

# 2. Demo image, tagged with each pinned version used by the profile's environments.
repo="$(awk '/^image:/ { f = 1; next } f && /^[^ ]/ { f = 0 } f && $1 == "repository:" { print $2; exit }' \
  "$ROOT/apps/demo/chart/values.yaml")"
[ -n "$repo" ] || die "no image.repository in apps/demo/chart/values.yaml"
images=""
for e in $ENVS; do
  v="$(awk '/^chart:/ { f = 1; next } f && $1 == "version:" { print $2; exit }' "$ROOT/promotion/versions/$e.yaml")"
  [ -n "$v" ] || die "no chart.version in promotion/versions/$e.yaml"
  case " $images " in *" $repo:$v "*) ;; *) images="$images $repo:$v" ;; esac
done
for img in $images; do
  if docker image inspect "$img" > /dev/null 2>&1; then
    log "image $img exists"
  else
    log "building $img"
    docker build -q -t "$img" "$ROOT/apps/demo/src" > /dev/null
  fi
done

# 3. Management cluster and workload Clusters.
"$here/mgmt-up.sh"

# 4. Workload clusters up (control plane and workers).
for n in $names; do
  log "waiting for Cluster $n to be Available"
  kubectl --kubeconfig "$MGMT_KC" -n "$NS" wait "cluster.cluster.x-k8s.io/$n" \
    --for=condition=Available --timeout="${TIMEOUT}s" > /dev/null
done

# 5. Demo image into every node (kind skips nodes that already have it).
for n in $names; do
  for img in $images; do
    kind load docker-image "$img" --name "$n" > /dev/null
  done
  log "$n: loaded$images"
done

# 6. Flux in the workload clusters.
"$here/sync-workloads.sh"

# 7. Every Flux object Ready.
# not_ready KUBECONFIG [REQUIRED_KUSTOMIZATION]: print the Flux objects that are not Ready
# (or "<name> missing"); nothing when all are Ready.
not_ready() {
  local json
  json="$(kubectl --kubeconfig "$1" get kustomizations.kustomize.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io \
    -A -o json 2> /dev/null)" || {
    echo "API unreachable"
    return
  }
  jq -r --arg req "${2:-}" '
    ([.items[]
      | select(([.status.conditions[]? | select(.type == "Ready")][0].status // "Unknown") != "True")
      | "\(.kind)/\(.metadata.name)"]
     + (if $req != "" and ([.items[] | select(.kind == "Kustomization" and .metadata.name == $req)] | length) == 0
        then ["Kustomization/\($req) missing"] else [] end))
    | join(" ")' <<< "$json"
}

wait_flux() { # label kubeconfig [required kustomization]
  local deadline=$((SECONDS + TIMEOUT)) last=0 pending
  while :; do
    pending="$(not_ready "$2" "${3:-}")"
    if [ -z "$pending" ]; then
      log "$1: all Flux objects Ready"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      die "$1: Flux objects not Ready after ${TIMEOUT}s: $pending"
    fi
    if [ $((SECONDS - last)) -ge 60 ]; then
      log "$1: waiting for $pending"
      last=$SECONDS
    fi
    sleep 10
  done
}

wait_flux fleet-mgmt "$MGMT_KC" workload-clusters
for n in $names; do
  wait_flux "$n" "$WORK/kubeconfigs/$n.yaml" apps
done

log "done. Run 'make smoke' to check the acceptance criteria."
