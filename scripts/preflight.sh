#!/usr/bin/env bash
# Verify required tools and Docker memory. Usage: preflight.sh [--profile full|lite]
# Missing tools or too little Docker memory fail; flux/kind/clusterctl client versions other
# than the versions.env pins only print a WARNING (they are untested, not necessarily broken).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$here/lib.sh"
# shellcheck source=/dev/null
source "$here/../versions.env"

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
# jq: up.sh and smoke; yq: promote.sh; git: mgmt-up.sh (offline git server); curl: smoke.
for tool in docker kind clusterctl flux helm kubectl kubeconform jq yq git curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "preflight: required tool '$tool' not found on PATH (see versions.env for expected versions)" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

# version_warn TOOL PINNED CMD...: WARNING when CMD's first x.y.z differs from PINNED.
version_warn() {
  local tool="$1" want="$2" have
  shift 2
  have="$("$@" 2> /dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
  if [ -z "$have" ]; then
    echo "preflight: WARNING: cannot read the $tool version; this repo is tested with $want" >&2
  elif [ "$have" != "$want" ]; then
    echo "preflight: WARNING: $tool $have is installed, versions.env pins $want; other versions are untested" >&2
  fi
}
version_warn flux "$FLUX_VERSION" flux version --client
version_warn kind "$KIND_VERSION" kind version
version_warn clusterctl "$CLUSTERCTL_VERSION" env CLUSTERCTL_DISABLE_VERSIONCHECK=true clusterctl version -o short

# Linux hosts: kind/CAPD nodes run systemd, which needs inotify instances; the common default (128)
# is too low for a management cluster plus workload nodes ("Too many open files" in node logs).
inotify_file="${FLEET_INOTIFY_FILE:-/proc/sys/fs/inotify/max_user_instances}"
if [ -r "$inotify_file" ]; then
  inotify_have="$(cat "$inotify_file" 2> /dev/null || true)"
  if [[ "$inotify_have" =~ ^[0-9]+$ ]] && [ "$inotify_have" -lt 512 ]; then
    echo "preflight: WARNING: fs.inotify.max_user_instances is $inotify_have; kind nodes may fail to start" >&2
    echo "preflight:   fix: sudo sysctl fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288" >&2
  fi
fi

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
