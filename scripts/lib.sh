#!/usr/bin/env bash
# Shared helpers. Source this file; do not execute it.

FLEET_PROFILE="${FLEET_PROFILE:-full}"

# Print the customer names for the active profile, one per line.
customers() {
  case "$FLEET_PROFILE" in
    full) printf '%s\n' acme globex ;;
    lite) printf '%s\n' acme ;;
    *)
      echo "unknown FLEET_PROFILE '$FLEET_PROFILE' (expected full or lite)" >&2
      return 1
      ;;
  esac
}

# phys_path PATH: PATH with symlinks resolved when it (or its parent) exists, else PATH itself.
phys_path() {
  if [ -d "$1" ]; then
    (cd "$1" && pwd -P)
  elif [ -d "$(dirname "$1")" ]; then
    echo "$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
  else
    echo "$1"
  fi
}

# fleet_work_dir ROOT: print the work dir, FLEET_WORK_DIR or ROOT/.work by default, after
# checking it is safe to create and later remove: an absolute path without . or .. segments
# that is not /, $HOME or an ancestor of it, nor the repo root ROOT or an ancestor of it.
# Fails with a message (and prints nothing) otherwise.
fleet_work_dir() {
  local root="$1" w="${FLEET_WORK_DIR:-$1/.work}" pw proot phome
  local bad="FLEET_WORK_DIR='${FLEET_WORK_DIR:-}'"
  case "$w" in
    /*) ;;
    *)
      echo "$bad must be an absolute path" >&2
      return 1
      ;;
  esac
  case "$w/" in
    */./* | */../*)
      echo "$bad must not contain . or .. segments" >&2
      return 1
      ;;
  esac
  while [ "${w%/}" != "$w" ]; do w="${w%/}"; done
  if [ -z "$w" ]; then
    echo "$bad: refusing the filesystem root" >&2
    return 1
  fi
  pw="$(phys_path "$w")"
  proot="$(phys_path "$root")"
  phome="$(phys_path "${HOME:-/nonexistent-home}")"
  case "$proot/" in
    "$pw"/*)
      echo "$bad: refusing the repository root or one of its ancestors" >&2
      return 1
      ;;
  esac
  case "$phome/" in
    "$pw"/*)
      echo "$bad: refusing \$HOME or one of its ancestors" >&2
      return 1
      ;;
  esac
  echo "$w"
}

# Marker file mgmt-up.sh writes into a work dir it owns; only such dirs are ever removed.
FLEET_WORK_MARKER=.fleet-work

# fleet_work_owned WORK ROOT: true when WORK is ours to remove: absent, the default ROOT/.work,
# or marked with $FLEET_WORK_MARKER.
fleet_work_owned() {
  [ ! -e "$1" ] || [ "$1" = "$2/.work" ] || [ -f "$1/$FLEET_WORK_MARKER" ]
}

# fleet_work_require_owned WORK ROOT: fail with a message unless fleet_work_owned.
fleet_work_require_owned() {
  fleet_work_owned "$1" "$2" && return 0
  echo "refusing to remove FLEET_WORK_DIR=$1: it has no $FLEET_WORK_MARKER marker (mgmt-up.sh writes" \
    "one into the work dirs it creates); remove it yourself if it is really a fleet work dir" >&2
  return 1
}
