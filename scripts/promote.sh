#!/usr/bin/env bash
# Promote the pinned chart version from one environment to another.
# Usage: scripts/promote.sh <from-env> <to-env>   (envs: dev test prod)
# Copies .chart.version of promotion/versions/<from>.yaml into <to>.yaml; touches nothing else.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/promotion/versions"

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <from-env> <to-env>" >&2
  exit 2
fi
command -v yq > /dev/null 2>&1 || { echo "FAIL: yq not found on PATH" >&2; exit 2; }

for env in "$1" "$2"; do
  case "$env" in
    dev | test | prod) [ -f "$DIR/$env.yaml" ] || { echo "FAIL: missing pin file $DIR/$env.yaml" >&2; exit 1; } ;;
    *) echo "FAIL: unknown environment '$env' (expected dev, test or prod)" >&2; exit 1 ;;
  esac
done

from_v="$(yq '.chart.version' "$DIR/$1.yaml")"
to_v="$(yq '.chart.version' "$DIR/$2.yaml")"
if [ -z "$from_v" ] || [ "$from_v" = null ]; then
  echo "FAIL: $DIR/$1.yaml has no chart.version" >&2
  exit 1
fi
if [ "$from_v" = "$to_v" ]; then
  echo "no change"
  exit 0
fi
V="$from_v" yq -i '.chart.version = strenv(V)' "$DIR/$2.yaml"
echo "bumped $2 to $from_v"
