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
