#!/usr/bin/env bash
# Tear the fleet down without residue (exit 0 on a machine where nothing exists):
#   1. mgmt-down.sh: fleet-mgmt kind cluster, CAPD workload cluster containers, fleet-git
#      container, the work dir ($WORK: kubeconfigs, bare git repo)
#   2. remove the work dir (again, also when mgmt-down.sh stopped early)
#   3. delete stale contexts (and their cluster and user entries) from the user's kubeconfig
#      ($KUBECONFIG or ~/.kube/config): kind-fleet-mgmt and <cluster>-admin@<cluster> for every
#      capi/customers/*.yaml name, whatever the profile. Other contexts are left alone.
# Env: FLEET_WORK_DIR (default <repo>/.work): absolute, not /, $HOME, the repo or an ancestor
#   (scripts/lib.sh fleet_work_dir); removed only when it carries the .fleet-work marker that
#   mgmt-up.sh writes (or is the default). Otherwise down.sh stops before deleting anything.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$here/lib.sh"
# Refuse an unsafe or foreign work dir before anything is deleted.
WORK="$(fleet_work_dir "$ROOT")"
fleet_work_require_owned "$WORK" "$ROOT"

"$here/mgmt-down.sh"
rm -rf "$WORK"

stale="kind-fleet-mgmt"
for f in "$ROOT"/capi/customers/*.yaml; do
  [ -e "$f" ] || continue
  n="$(basename "$f" .yaml)"
  stale="$stale $n-admin@$n"
done
contexts="$(kubectl config get-contexts -o name 2> /dev/null || true)"
for ctx in $stale; do
  if printf '%s\n' "$contexts" | grep -qxF "$ctx"; then
    kubectl config delete-context "$ctx" > /dev/null
    # kind: cluster and user are named like the context; clusterctl: <n>-admin@<n> -> <n>, <n>-admin
    kubectl config delete-cluster "${ctx#*@}" > /dev/null 2>&1 || true
    kubectl config delete-user "${ctx%@*}" > /dev/null 2>&1 || true
    echo "down: removed kubeconfig context $ctx"
  fi
done
