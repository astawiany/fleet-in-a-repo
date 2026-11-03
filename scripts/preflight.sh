#!/usr/bin/env bash
# Verify required tools and Docker memory. Usage: preflight.sh [--profile full|lite]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$here/lib.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)
      [ $# -ge 2 ] || { echo "preflight: --profile needs a value (full|lite)" >&2; exit 1; }
      FLEET_PROFILE="$2"
      shift 2
      ;;
    *)
      echo "preflight: unknown argument '$1'" >&2
      exit 1
      ;;
  esac
done

case "$FLEET_PROFILE" in
  full) min_gib=12 ;;
  lite) min_gib=6 ;;
  *)
    echo "preflight: unknown profile '$FLEET_PROFILE' (expected full or lite)" >&2
    exit 1
    ;;
esac

missing=0
for tool in docker kind clusterctl flux helm kubectl kubeconform; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "preflight: required tool '$tool' not found on PATH (see versions.env for expected versions)" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || true)"
if ! [[ "$mem_bytes" =~ ^[0-9]+$ ]]; then
  echo "preflight: cannot read Docker memory; is the Docker daemon running?" >&2
  exit 1
fi

need_bytes=$((min_gib * 1024 * 1024 * 1024))
if [ "$mem_bytes" -lt "$need_bytes" ]; then
  have_gib=$((mem_bytes / 1024 / 1024 / 1024))
  msg="preflight: Docker has ${have_gib} GiB, profile '$FLEET_PROFILE' needs at least ${min_gib} GiB."
  if [ "$FLEET_PROFILE" = "full" ]; then
    msg="$msg Raise Docker's memory limit or run with --profile lite (FLEET_PROFILE=lite)."
  else
    msg="$msg Raise Docker's memory limit."
  fi
  echo "$msg" >&2
  exit 1
fi

echo "preflight: ok (profile $FLEET_PROFILE)"
