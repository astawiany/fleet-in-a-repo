#!/usr/bin/env bats
# FLEET_WORK_DIR validation (scripts/lib.sh fleet_work_dir) and the .fleet-work marker that
# down.sh / mgmt-down.sh require before they remove a work dir.
# Safety: the scripts under test remove directories. Every script run here uses a scratch
# HOME and a scratch copy of the repo, so even a broken implementation can only delete files
# below $BATS_TEST_TMPDIR. Real /, $HOME and the real repo are only given to the pure resolver.

bats_require_minimum_version 1.5.0

setup() {
  REAL_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  STUBS="$T/stubs"
  export CALLS="$T/calls.log"
  mkdir -p "$STUBS" "$T/home" "$T/anc/repo"
  : > "$CALLS"
  echo canary > "$T/home/canary"
  cp -R "$REAL_ROOT/scripts" "$REAL_ROOT/capi" "$REAL_ROOT/kind" "$REAL_ROOT/versions.env" "$T/anc/repo/"
  echo canary > "$T/anc/repo/canary"
  echo canary > "$T/anc/canary"
  ROOT="$T/anc/repo" # scripts below run from this copy
  unset FLEET_PROFILE GITHUB_REPOSITORY FLEET_FLUX_GITHUB FLEET_WORK_DIR
  export KUBECONFIG="$T/home-kubeconfig"
  stub kind 'echo "No kind clusters found." >&2'
  stub docker 'exit 0'
  stub kubectl 'exit 0'
}

stub() {
  printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n%s\n' "$1" "$2" > "$STUBS/$1"
  chmod +x "$STUBS/$1"
}

# resolve VALUE: print what fleet_work_dir makes of FLEET_WORK_DIR=VALUE ("-": unset) for the
# real repo. Pure: it removes nothing.
resolve() {
  if [ "$1" = - ]; then
    run --separate-stderr env -u FLEET_WORK_DIR bash -c 'source "$1/scripts/lib.sh"; fleet_work_dir "$1"' _ "$REAL_ROOT"
  else
    run --separate-stderr env FLEET_WORK_DIR="$1" bash -c 'source "$1/scripts/lib.sh"; fleet_work_dir "$1"' _ "$REAL_ROOT"
  fi
}

# script NAME: run the scratch copy's script with the scratch HOME, from the scratch HOME.
script() {
  status=0
  (cd "$T/home" && HOME="$T/home" PATH="$STUBS:/usr/bin:/bin" bash "$ROOT/scripts/$1") \
    > "$T/out" 2> "$T/err" || status=$?
  output="$(cat "$T/out")"
  stderr="$(cat "$T/err")"
}

canaries_intact() {
  [ -f "$T/home/canary" ] || { echo "scratch HOME wiped"; return 1; }
  [ -f "$T/anc/repo/canary" ] && [ -d "$T/anc/repo/scripts" ] || { echo "repo copy wiped"; return 1; }
  [ -f "$T/anc/canary" ] || { echo "repo ancestor wiped"; return 1; }
}

@test "fleet_work_dir defaults to <repo>/.work and accepts an absolute scratch path" {
  resolve -
  [ "$status" -eq 0 ]
  [ "$output" = "$REAL_ROOT/.work" ]
  resolve "$T/work/"
  [ "$status" -eq 0 ]
  [ "$output" = "$T/work" ]
}

@test "fleet_work_dir refuses /, \$HOME, relative paths, dot segments, the repo root and its ancestors" {
  for bad in / // "$HOME" "$HOME/" . .work relative/dir "$REAL_ROOT" "$REAL_ROOT/" \
    "$(dirname "$REAL_ROOT")" "$REAL_ROOT/.." "$T/../x" "$T/./x"; do
    resolve "$bad"
    [ "$status" -ne 0 ] || { echo "accepted: '$bad' -> $output"; false; }
    [ -z "$output" ] || { echo "printed a dir for '$bad': $output"; false; }
    [[ "$stderr" == *FLEET_WORK_DIR* ]] || { echo "no FLEET_WORK_DIR in message for '$bad': $stderr"; false; }
  done
}

@test "down and mgmt-down refuse \$HOME, ., the repo root and its ancestor and remove nothing" {
  for s in down.sh mgmt-down.sh; do
    for bad in "$T/home" . "$ROOT" "$T/anc"; do
      FLEET_WORK_DIR="$bad" script "$s"
      [ "$status" -ne 0 ] || { echo "$s accepted '$bad'"; false; }
      [[ "$stderr" == *FLEET_WORK_DIR* ]] || { echo "$s '$bad': $stderr"; false; }
      canaries_intact
    done
  done
  run grep -E '^(kind|docker|kubectl)' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "down and mgmt-down refuse a FLEET_WORK_DIR without a .fleet-work marker and remove nothing" {
  export FLEET_WORK_DIR="$T/precious"
  mkdir -p "$FLEET_WORK_DIR"
  echo keep > "$FLEET_WORK_DIR/file"
  for s in down.sh mgmt-down.sh; do
    script "$s"
    [ "$status" -ne 0 ] || { echo "$s exited 0"; false; }
    [[ "$stderr" == *".fleet-work"* ]] || { echo "$s: $stderr"; false; }
    [ -f "$FLEET_WORK_DIR/file" ] || { echo "$s removed the dir"; false; }
  done
  run grep -E '^(kind delete|docker rm|kubectl config delete)' "$CALLS"
  [ "$status" -eq 1 ]
}

@test "down removes a marked FLEET_WORK_DIR, and the default <repo>/.work without a marker" {
  export FLEET_WORK_DIR="$T/work"
  mkdir -p "$FLEET_WORK_DIR/kubeconfigs"
  touch "$FLEET_WORK_DIR/.fleet-work"
  script down.sh
  [ "$status" -eq 0 ]
  [ ! -e "$FLEET_WORK_DIR" ]
  unset FLEET_WORK_DIR
  mkdir -p "$ROOT/.work/kubeconfigs"
  script down.sh
  [ "$status" -eq 0 ]
  [ ! -e "$ROOT/.work" ]
  canaries_intact
}

@test "mgmt-up refuses a non-empty unmarked FLEET_WORK_DIR before creating anything" {
  for t in kind clusterctl flux kubectl docker git; do stub "$t" 'exit 0'; done
  export FLEET_WORK_DIR="$T/precious" FLEET_WAIT_TIMEOUT=1
  mkdir -p "$FLEET_WORK_DIR"
  echo keep > "$FLEET_WORK_DIR/file"
  script mgmt-up.sh
  [ "$status" -ne 0 ]
  [[ "$stderr" == *".fleet-work"* ]] || false
  [ ! -e "$FLEET_WORK_DIR/.fleet-work" ]
  run grep -E '^(kind|clusterctl|flux|docker|git)' "$CALLS"
  [ "$status" -eq 1 ]
}
