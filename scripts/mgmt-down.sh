#!/usr/bin/env bash
# Tear down everything mgmt-up.sh created: the fleet-mgmt kind cluster, CAPD workload
# cluster containers (any capi/customers/*.yaml name, whatever the profile), the fleet-git
# server container and the work dir. Silent and exit 0 when nothing exists.
# Env: FLEET_WORK_DIR (default <repo>/.work).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MGMT=fleet-mgmt
GIT_CONTAINER=fleet-git
WORK="${FLEET_WORK_DIR:-$ROOT/.work}"

if kind get clusters 2> /dev/null | grep -qx "$MGMT"; then
  kind delete cluster --name "$MGMT"
fi

# CAPD labels every machine and load balancer container with io.x-k8s.kind.cluster=<cluster>.
ids=""
for f in "$ROOT"/capi/customers/*.yaml; do
  [ -e "$f" ] || continue
  n="$(basename "$f" .yaml)"
  ids="$ids $(docker ps -aq --filter "label=io.x-k8s.kind.cluster=$n" 2> /dev/null || true)"
done
ids="$ids $(docker ps -aq --filter "name=^${GIT_CONTAINER}\$" 2> /dev/null || true)"
# shellcheck disable=SC2086 # word-splitting the id list is intended
set -- $ids
if [ "$#" -gt 0 ]; then
  echo "mgmt-down: removing $# leftover container(s)"
  docker rm -f "$@" > /dev/null
fi

rm -rf "$WORK"
