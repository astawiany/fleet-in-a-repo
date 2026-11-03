#!/usr/bin/env bash
# Validate repo manifests: name rules, kustomize build + kubeconform, helm lint/template.
# Usage: scripts/validate.sh [path...]   (no args = whole repo; the walk skips test/fixtures)
# Network: kubeconform downloads JSON schemas from raw.githubusercontent.com on first use.
# They are cached in ${XDG_CACHE_HOME:-$HOME/.cache}/fleet-in-a-repo/kubeconform, so later
# runs work offline. The name rules need no network.
set -uo pipefail

for tool in kustomize kubeconform helm; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "FAIL [prereq]: '$tool' not found on PATH; install it (see scripts/preflight.sh)" >&2
    exit 2
  fi
done
KC_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/fleet-in-a-repo/kubeconform"
mkdir -p "$KC_CACHE"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$ROOT/apps/demo/chart"
VALUES="$ROOT/apps/demo/values"
NAME_RE='^[a-z][a-z0-9-]{0,62}$'

if [ "$#" -eq 0 ]; then
  targets=("$ROOT")
  walk_prune=(-path "$ROOT/test/fixtures")
else
  targets=()
  for p in "$@"; do
    if [ ! -d "$p" ]; then
      echo "FAIL [args]: not a directory: $p" >&2
      exit 2
    fi
    targets+=("$(cd "$p" && pwd)")
  done
  walk_prune=(-path /nonexistent)
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL [$1]: $2" >&2; failures=$((failures + 1)); }

check_name() { # kind name path
  if ! printf '%s\n' "$2" | LC_ALL=C grep -Eq "$NAME_RE"; then
    fail "name-rule" "$1 name '$2' must match $NAME_RE ($3)"
  fi
}

kubeconform_check() { # label manifest-file
  if ! kubeconform -strict -ignore-missing-schemas -cache "$KC_CACHE" -summary < "$2" > "$work/kc.out" 2>&1; then
    cat "$work/kc.out" >&2
    fail "kubeconform" "$1"
  fi
}

# Step 1: name rules
for t in "${targets[@]}"; do
  if [ -d "$t/clusters" ]; then
    for d in "$t"/clusters/*/; do
      [ -d "$d" ] || continue
      n="$(basename "$d")"
      [ "$n" = management ] && continue
      check_name "cluster directory" "$n" "$d"
    done
  fi
  if [ -d "$t/capi/customers" ]; then
    for f in "$t"/capi/customers/*.yaml; do
      [ -e "$f" ] || continue
      n="$(basename "$f" .yaml)"
      check_name "customer file" "$n" "$f"
    done
  fi
done

# Step 2: kustomize build + kubeconform
for t in "${targets[@]}"; do
  while IFS= read -r k; do
    d="$(dirname "$k")"
    if ! kustomize build "$d" > "$work/build.yaml" 2> "$work/build.err"; then
      cat "$work/build.err" >&2
      fail "kustomize-build" "$d"
      continue
    fi
    kubeconform_check "$d" "$work/build.yaml"
  done < <(find "$t" \( -name .git -o -name .superpowers -o -name .work -o -name node_modules -o "${walk_prune[@]}" \) -prune \
    -o -name kustomization.yaml -type f -print | sort)
done

# Step 3: helm lint + template (only when a target covers the chart)
run_helm=0
if [ -f "$CHART/Chart.yaml" ]; then
  for t in "${targets[@]}"; do
    case "$CHART/" in "$t"/*) run_helm=1 ;; esac
    case "$t/" in "$CHART"/*) run_helm=1 ;; esac
  done
fi
if [ "$run_helm" -eq 1 ]; then
  for v in "$VALUES"/*.yaml; do
    [ -e "$v" ] || continue
    [ "$(basename "$v")" = kustomization.yaml ] && continue
    if ! helm lint "$CHART" -f "$v" > "$work/lint.out" 2>&1; then
      cat "$work/lint.out" >&2
      fail "helm-lint" "$CHART with $v"
    fi
    if ! helm template demo "$CHART" -f "$v" > "$work/tpl.yaml" 2> "$work/tpl.err"; then
      cat "$work/tpl.err" >&2
      fail "helm-template" "$CHART with $v"
      continue
    fi
    kubeconform_check "$CHART with $v" "$work/tpl.yaml"
  done
fi

if [ "$failures" -gt 0 ]; then
  echo "validate: $failures failure(s)" >&2
  exit 1
fi
echo "validate: OK"
