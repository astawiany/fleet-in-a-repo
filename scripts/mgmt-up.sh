#!/usr/bin/env bash
# Create or converge the management cluster (idempotent):
#   1. kind cluster fleet-mgmt (kind/mgmt.yaml)
#   2. Cluster API core/kubeadm + CAPD providers at CLUSTERCTL_VERSION
#   3. Flux, synced to this repo at clusters/management:
#        GITHUB_REPOSITORY=owner/repo set -> flux bootstrap github (needs GITHUB_TOKEN)
#        otherwise (offline default)      -> git HEAD is pushed to the bare repo
#          $WORK/git/fleet.git, served read-only over smart HTTP by the fleet-git
#          container on the kind Docker network; GitRepository flux-system points there.
#          Only committed changes are synced; re-run after committing.
#   4. capi/ ClusterClass + the workload Clusters of the active profile (lib.sh customers())
#   5. workload kubeconfigs exported to $WORK/kubeconfigs/<name>.yaml, with the API server
#      rewritten to the load balancer's published localhost port (reachable on macOS too)
# Env: FLEET_PROFILE (full|lite), FLEET_WORK_DIR (default <repo>/.work),
#      FLEET_WAIT_TIMEOUT seconds to wait for each workload kubeconfig (default 600).
# All kubectl/clusterctl/flux calls use the dedicated kubeconfig $WORK/mgmt.kubeconfig.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$here/lib.sh"
# shellcheck source=/dev/null
source "$ROOT/versions.env"

MGMT=fleet-mgmt
NS=fleet
ENVS="dev prod"
BRANCH=main
FLUX_PATH=clusters/management
GIT_CONTAINER=fleet-git
GIT_IMAGE=fleet-git-server:local
WORK="${FLEET_WORK_DIR:-$ROOT/.work}"
TIMEOUT="${FLEET_WAIT_TIMEOUT:-600}"
export KUBECONFIG="$WORK/mgmt.kubeconfig"

log() { echo "mgmt-up: $*"; }

# retry SECONDS CMD...: rerun CMD every 5 s until it succeeds or SECONDS elapse.
retry() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "mgmt-up: gave up after retries: $*" >&2
      return 1
    fi
    sleep 5
  done
}

cust="$(customers)"
names=""
for c in $cust; do
  for e in $ENVS; do
    names="$names $c-$e"
  done
done

mkdir -p "$WORK/kubeconfigs"

# 1. kind management cluster
if kind get clusters 2> /dev/null | grep -qx "$MGMT"; then
  log "kind cluster $MGMT exists"
else
  kind create cluster --config "$ROOT/kind/mgmt.yaml" --kubeconfig "$KUBECONFIG"
fi
kind export kubeconfig --name "$MGMT" --kubeconfig "$KUBECONFIG" > /dev/null 2>&1

# 2. Cluster API with the Docker (CAPD) infrastructure provider
if kubectl -n capd-system get deployment capd-controller-manager > /dev/null 2>&1; then
  log "Cluster API already initialized"
else
  v="v$CLUSTERCTL_VERSION"
  CLUSTER_TOPOLOGY=true clusterctl init --core "cluster-api:$v" --bootstrap "kubeadm:$v" \
    --control-plane "kubeadm:$v" --infrastructure "docker:$v" --wait-providers
fi

# 3. Flux
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  # --personal: the repository belongs to a user account, not an organization.
  flux bootstrap github --owner "${GITHUB_REPOSITORY%%/*}" --repository "${GITHUB_REPOSITORY#*/}" \
    --branch "$BRANCH" --path "$FLUX_PATH" --personal
else
  if kubectl -n flux-system get deployment source-controller > /dev/null 2>&1; then
    log "Flux already installed"
  else
    flux install
  fi

  bare="$WORK/git/fleet.git"
  [ -d "$bare" ] || git init -q --bare "$bare"
  if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    log "warning: uncommitted changes are not synced to Flux (only HEAD is pushed)"
  fi
  git -C "$ROOT" push -q --force "$bare" "HEAD:refs/heads/$BRANCH"
  git -C "$bare" symbolic-ref HEAD "refs/heads/$BRANCH"

  if [ -z "$(docker ps -q --filter "name=^${GIT_CONTAINER}\$")" ]; then
    docker rm -f "$GIT_CONTAINER" > /dev/null 2>&1 || true
    docker image inspect "$GIT_IMAGE" > /dev/null 2>&1 \
      || docker build -q -t "$GIT_IMAGE" "$ROOT/kind/git-server" > /dev/null
    docker run -d --name "$GIT_CONTAINER" --network kind --restart unless-stopped \
      -v "$WORK/git:/srv/git:ro" "$GIT_IMAGE" > /dev/null
  fi

  flux create source git flux-system --url "http://$GIT_CONTAINER/cgi-bin/git/fleet.git" \
    --branch "$BRANCH" --interval 1m --export | kubectl apply -f -
  flux create kustomization flux-system --source GitRepository/flux-system \
    --path "./$FLUX_PATH" --prune --interval 10m --export | kubectl apply -f -
  retry 120 kubectl -n flux-system wait gitrepository/flux-system --for=condition=Ready --timeout=10s
fi

# 4. ClusterClass and the workload clusters of this profile
apply=(-f "$ROOT/capi/namespace.yaml" -f "$ROOT/capi/clusterclass/capd-clusterclass.yaml")
for n in $names; do
  apply+=(-f "$ROOT/capi/customers/$n.yaml")
done
# CAPI webhooks can lag behind --wait-providers on a fresh install.
retry 120 kubectl apply "${apply[@]}"

# 5. Workload kubeconfigs
for n in $names; do
  deadline=$((SECONDS + TIMEOUT))
  while :; do
    if kubectl -n "$NS" get secret "$n-kubeconfig" > /dev/null 2>&1; then
      port="$(docker port "$n-lb" 6443/tcp 2> /dev/null | head -n 1)"
      port="${port##*:}"
      [ -z "$port" ] || break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "mgmt-up: timed out after ${TIMEOUT}s waiting for the $n kubeconfig" >&2
      exit 1
    fi
    sleep 10
  done
  out="$WORK/kubeconfigs/$n.yaml"
  clusterctl get kubeconfig "$n" -n "$NS" \
    | sed -E "s#^( *server: ).*#\\1https://127.0.0.1:$port#" > "$out"
  chmod 600 "$out"
  log "kubeconfig for $n: $out"
done

log "done. Management cluster: export KUBECONFIG=$KUBECONFIG"
