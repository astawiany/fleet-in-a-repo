#!/usr/bin/env bash
# Create or converge the management cluster (idempotent):
#   1. kind cluster fleet-mgmt (kind/mgmt.yaml, node image KIND_NODE_IMAGE)
#   2. Cluster API core/kubeadm + CAPD providers at CLUSTERCTL_VERSION
#   3. Flux FLUX_VERSION, synced to this repo at clusters/management:
#        FLEET_FLUX_GITHUB=owner/repo set -> flux bootstrap github --personal --token-auth
#          (explicit opt-in, needs GITHUB_TOKEN; GITHUB_REPOSITORY alone never triggers it)
#        otherwise (offline default)      -> git HEAD is pushed to the bare repo
#          $WORK/git/fleet.git, served read-only over smart HTTP by the fleet-git
#          container on the kind Docker network; GitRepository flux-system points there.
#          Only committed changes are synced; re-run after committing.
#   4. capi/ namespace, ClusterClass, kindnet CNI ClusterResourceSet and the workload
#      Clusters of the active profile (lib.sh customers()); ${VAR} placeholders are
#      substituted from versions.env into $WORK/rendered/ before kubectl apply.
#   5. workload kubeconfigs exported to $WORK/kubeconfigs/<name>.yaml, with the API server
#      rewritten to the load balancer's published localhost port (reachable on macOS too)
# Versions: versions.env (KIND_NODE_IMAGE, CLUSTERCTL_VERSION, FLUX_VERSION,
#   WORKLOAD_K8S_VERSION, KINDNETD_IMAGE).
# Env: FLEET_FLUX_GITHUB (see 3), FLEET_PROFILE (full|lite), FLEET_WORK_DIR (default <repo>/.work),
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
GIT_SERVER_DIR="$ROOT/kind/git-server"
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

# Hash of kind/git-server (file names + contents): changing it yields a new image tag.
dir_hash() {
  (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
    echo "$f"
    cat "$f"
  done) | shasum -a 256 | cut -c1-12
}

# render FILE: copy capi/FILE to $WORK/rendered/FILE with ${VAR} placeholders from versions.env.
render() {
  local out="$WORK/rendered/$1"
  mkdir -p "$(dirname "$out")"
  sed -e "s|\${WORKLOAD_K8S_VERSION}|$WORKLOAD_K8S_VERSION|g" \
    -e "s|\${KINDNETD_IMAGE}|$KINDNETD_IMAGE|g" "$ROOT/capi/$1" > "$out"
  echo "$out"
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
  kind create cluster --config "$ROOT/kind/mgmt.yaml" --image "$KIND_NODE_IMAGE" --kubeconfig "$KUBECONFIG"
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
if [ -n "${FLEET_FLUX_GITHUB:-}" ]; then
  # --personal: the repository belongs to a user account; --token-auth: clone over HTTPS with
  # GITHUB_TOKEN instead of creating a deploy key.
  flux bootstrap github --version "v$FLUX_VERSION" --owner "${FLEET_FLUX_GITHUB%%/*}" \
    --repository "${FLEET_FLUX_GITHUB#*/}" --branch "$BRANCH" --path "$FLUX_PATH" \
    --personal --token-auth
else
  if kubectl -n flux-system get deployment source-controller > /dev/null 2>&1; then
    log "Flux already installed"
  else
    flux install --version "v$FLUX_VERSION"
  fi

  bare="$WORK/git/fleet.git"
  [ -d "$bare" ] || git init -q --bare "$bare"
  if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    log "warning: uncommitted changes are not synced to Flux (only HEAD is pushed)"
  fi
  git -C "$ROOT" push -q --force "$bare" "HEAD:refs/heads/$BRANCH"
  git -C "$bare" symbolic-ref HEAD "refs/heads/$BRANCH"

  git_image="fleet-git-server:$(dir_hash "$GIT_SERVER_DIR")"
  docker image inspect "$git_image" > /dev/null 2>&1 \
    || docker build -q -t "$git_image" "$GIT_SERVER_DIR" > /dev/null
  running="$(docker ps --filter "name=^${GIT_CONTAINER}\$" --filter label=fleet-in-a-repo=1 \
    --format '{{.Image}}')"
  if [ "$running" != "$git_image" ]; then
    if [ -n "$(docker ps -aq --filter "name=^${GIT_CONTAINER}\$" --filter label=fleet-in-a-repo=1)" ]; then
      docker rm -f -v "$GIT_CONTAINER" > /dev/null
    fi
    docker run -d --name "$GIT_CONTAINER" --label fleet-in-a-repo=1 --network kind \
      --restart unless-stopped -v "$WORK/git:/srv/git:ro" "$git_image" > /dev/null
  fi

  flux create source git flux-system --url "http://$GIT_CONTAINER/cgi-bin/git/fleet.git" \
    --branch "$BRANCH" --interval 1m --export | kubectl apply -f -
  flux create kustomization flux-system --source GitRepository/flux-system \
    --path "./$FLUX_PATH" --prune --interval 10m --export | kubectl apply -f -
  retry 120 kubectl -n flux-system wait gitrepository/flux-system --for=condition=Ready --timeout=10s
fi

# 4. ClusterClass, CNI and the workload clusters of this profile
rm -rf "$WORK/rendered"
apply=()
for f in namespace.yaml clusterclass/capd-clusterclass.yaml cni/kindnet.yaml; do
  apply+=(-f "$(render "$f")")
done
for n in $names; do
  apply+=(-f "$(render "customers/$n.yaml")")
done
# CAPI webhooks can lag behind --wait-providers on a fresh install.
retry 120 kubectl apply "${apply[@]}"

# 5. Workload kubeconfigs (credentials: owner-only files)
umask 077
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
