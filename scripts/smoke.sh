#!/usr/bin/env bash
# Acceptance checks against every workload cluster of the active profile. For each cluster
# (kubeconfig $WORK/kubeconfigs/<cluster>.yaml) prints exactly one line per criterion:
#   PASS|FAIL <criterion> <cluster> [object] [(detail)]
# Criteria: flux (every Flux Kustomization/HelmRelease Ready; a FAIL names each one that is not,
# as "<Kind> <name>/<cluster>"), then one per scripts/smoke.d/NN-<criterion>.sh, run in order
# with the cluster name as $1 and KUBECONFIG exported; each prints its own single line.
# Exits 1 if any line is FAIL.
# Env: FLEET_PROFILE (full|lite), FLEET_WORK_DIR (default <repo>/.work); the smoke.d checks
#   read SMOKE_* tuning variables (see each check's header).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$here/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$here/lib.sh"

ENVS="dev prod"
WORK="${FLEET_WORK_DIR:-$ROOT/.work}"

cust="$(customers)" || exit 1
checks=("$here"/smoke.d/*.sh)

criterion() { # smoke.d/NN-name.sh -> name
  local b
  b="$(basename "$1" .sh)"
  echo "${b#*-}"
}

# flux_check CLUSTER: one line for all Flux Kustomizations and HelmReleases of the cluster.
flux_check() {
  local json bad
  if ! json="$(kubectl get kustomizations.kustomize.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io \
    -A -o json 2>&1)"; then
    echo "FAIL flux $1 (cannot list Flux objects: $(head -n 1 <<< "$json"))"
    return
  fi
  bad="$(jq -r --arg c "$1" '
    [.items[]
      | select(([.status.conditions[]? | select(.type == "Ready")][0].status // "Unknown") != "True")
      | "\(.kind) \(.metadata.name)/\($c) (namespace \(.metadata.namespace)): \(
          [.status.conditions[]? | select(.type == "Ready")][0].message // "no Ready condition")"]
    | join("; ")' <<< "$json")"
  if [ -n "$bad" ]; then
    echo "FAIL flux $1 $bad"
  elif [ "$(jq '.items | length' <<< "$json")" -eq 0 ]; then
    echo "FAIL flux $1 (no Flux Kustomizations or HelmReleases)"
  else
    echo "PASS flux $1"
  fi
}

out=""
for c in $cust; do
  for e in $ENVS; do
    n="$c-$e"
    kc="$WORK/kubeconfigs/$n.yaml"
    if [ ! -f "$kc" ]; then
      lines="FAIL flux $n kubeconfig (missing $kc; run make up)"
      for f in "${checks[@]}"; do
        lines="$lines"$'\n'"FAIL $(criterion "$f") $n kubeconfig (missing $kc)"
      done
      echo "$lines"
      out="$out"$'\n'"$lines"
      continue
    fi
    export KUBECONFIG="$kc"
    line="$(flux_check "$n")"
    echo "$line"
    out="$out"$'\n'"$line"
    for f in "${checks[@]}"; do
      k="$(criterion "$f")"
      line="$(bash "$f" "$n" | grep -E "^(PASS|FAIL) $k $n( |\$)" | head -n 1)"
      [ -n "$line" ] || line="FAIL $k $n (check printed no result)"
      echo "$line"
      out="$out"$'\n'"$line"
    done
  done
done

if grep -q '^FAIL ' <<< "$out"; then
  echo "smoke: $(grep -c '^FAIL ' <<< "$out") check(s) failed" >&2
  exit 1
fi
echo "smoke: all checks passed"
