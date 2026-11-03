#!/usr/bin/env bash
# Tear down everything mgmt-up.sh created: the fleet-mgmt kind cluster, CAPD workload
# cluster containers (any capi/customers/*.yaml name, whatever the profile), the fleet-git
# server container (only when labeled fleet-in-a-repo=1) and the work dir.
# Silent and exit 0 when nothing exists.
# Env: FLEET_WORK_DIR (default <repo>/.work; validated and marker-checked as in down.sh).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$here/lib.sh"
MGMT=fleet-mgmt
GIT_CONTAINER=fleet-git
# Refuse an unsafe or foreign work dir before anything is deleted.
WORK="$(fleet_work_dir "$ROOT")"
fleet_work_require_owned "$WORK" "$ROOT"

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
# Only the fleet-git container this repo created (label fleet-in-a-repo=1).
ids="$ids $(docker ps -aq --filter "name=^${GIT_CONTAINER}\$" --filter label=fleet-in-a-repo=1 2> /dev/null || true)"
# shellcheck disable=SC2086 # word-splitting the id list is intended
set -- $ids
if [ "$#" -gt 0 ]; then
  echo "mgmt-down: removing $# leftover container(s)"
  docker rm -f -v "$@" > /dev/null
fi

rm -rf "$WORK"
