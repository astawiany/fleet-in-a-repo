#!/usr/bin/env bash
# Print cluster state useful for debugging a failed `make up` / `make smoke` (used by CI on failure).
# Best-effort: every command may fail; nothing here changes state.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${FLEET_WORK_DIR:-$ROOT/.work}"
K="$WORK/mgmt.kubeconfig"
section() { printf '\n===== %s =====\n' "$*"; }

section "docker ps"
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>&1 | head -40
section "host resources"
free -m 2>&1 | head -3; df -h / 2>&1 | tail -1; docker info --format 'cgroup={{.CgroupVersion}} mem={{.MemTotal}}' 2>&1
[ -f "$K" ] || { echo "no management kubeconfig at $K"; exit 0; }
export KUBECONFIG="$K"
section "clusters / machines"
kubectl get clusters,machines,dockermachines,kubeadmcontrolplanes,machinedeployments -A -o wide 2>&1 | head -40
section "cluster conditions"
kubectl get clusters -A -o json 2>&1 | jq -r '.items[]? | .metadata.name as $n | .status.conditions[]? | "\($n) \(.type)=\(.status) \(.reason // "") \(.message // "")"' 2>&1 | head -40
section "machine conditions"
kubectl get machines -A -o json 2>&1 | jq -r '.items[]? | .metadata.name as $n | .status.conditions[]? | select(.status!="True") | "\($n) \(.type)=\(.status) \(.reason // "") \(.message // "")"' 2>&1 | head -40
section "events (warnings)"
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>&1 | tail -30
section "capd / capi controller logs (tail)"
kubectl -n capd-system logs deploy/capd-controller-manager --tail=60 2>&1 | tail -60
kubectl -n capi-kubeadm-control-plane-system logs deploy/capi-kubeadm-control-plane-controller-manager --tail=40 2>&1 | tail -40
section "flux on management"
kubectl get kustomizations,gitrepositories -A 2>&1 | head -20
