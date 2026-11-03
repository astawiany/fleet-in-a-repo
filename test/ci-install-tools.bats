#!/usr/bin/env bats
# scripts/ci-install-tools.sh checksum verification for yq, kubeconform and clusterctl.
# curl is stubbed (serves files by basename from $WORK/serve); no network.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/bin" "$WORK/serve" "$WORK/root/scripts" "$WORK/out"
  cp "$ROOT/scripts/ci-install-tools.sh" "$WORK/root/scripts/"
  cat > "$WORK/bin/curl" <<'EOS'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
n="$(basename "$url")"
[ "$n" != CHECKSUMS ] || n=kubeconform.sums # avoid a clash with yq's "checksums" on case-insensitive filesystems
f="$SERVE/$n"
[ -f "$f" ] || { echo "stub curl: no $f" >&2; exit 22; }
cp "$f" "$out"
EOS
  chmod +x "$WORK/bin/curl"
  export SERVE="$WORK/serve" CI_BIN="$WORK/out" PATH="$WORK/bin:$PATH"

  # fake artifacts
  echo "fake yq" > "$WORK/serve/yq_linux_amd64"
  mkdir "$WORK/kc"; echo "fake kubeconform" > "$WORK/kc/kubeconform"
  tar -czf "$WORK/serve/kubeconform-linux-amd64.tar.gz" -C "$WORK/kc" kubeconform
  echo "fake clusterctl" > "$WORK/serve/clusterctl-linux-amd64"
  printf 'CRC32\nSHA-1\nSHA-256\nSHA-512\n' > "$WORK/serve/checksums_hashes_order"
  sum() { sha256sum "$1" | cut -d' ' -f1; }
  printf 'yq_linux_amd64 aaaa bbbb %s cccc\n' "$(sum "$WORK/serve/yq_linux_amd64")" > "$WORK/serve/checksums"
  printf '%s  kubeconform-linux-amd64.tar.gz\n' "$(sum "$WORK/serve/kubeconform-linux-amd64.tar.gz")" > "$WORK/serve/kubeconform.sums"
  cat > "$WORK/root/versions.env" <<EOS
YQ_VERSION=1.0.0
KUBECONFORM_VERSION=1.0.0
CLUSTERCTL_VERSION=1.0.0
CLUSTERCTL_SHA256_LINUX_AMD64=$(sum "$WORK/serve/clusterctl-linux-amd64")
EOS
}

teardown() { rm -rf "$WORK"; }

run_install() { run "$WORK/root/scripts/ci-install-tools.sh" "$@"; }

@test "yq, kubeconform and clusterctl install when checksums match" {
  run_install yq kubeconform clusterctl
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for t in yq kubeconform clusterctl; do [ -x "$WORK/out/$t" ]; done
}

@test "yq checksum mismatch fails and installs nothing" {
  echo tampered > "$WORK/serve/yq_linux_amd64"
  run_install yq
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]] || { echo "$output"; false; }
  [ ! -e "$WORK/out/yq" ]
}

@test "kubeconform checksum mismatch fails and installs nothing" {
  echo tampered > "$WORK/serve/kubeconform-linux-amd64.tar.gz"
  run_install kubeconform
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]] || { echo "$output"; false; }
  [ ! -e "$WORK/out/kubeconform" ]
}

@test "clusterctl differing from the sha256 pinned in versions.env fails" {
  echo tampered > "$WORK/serve/clusterctl-linux-amd64"
  run_install clusterctl
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]] || { echo "$output"; false; }
  [ ! -e "$WORK/out/clusterctl" ]
}

@test "a missing checksum entry fails instead of passing" {
  : > "$WORK/serve/kubeconform.sums"
  run_install kubeconform
  [ "$status" -ne 0 ]
}

@test "versions.env pins a 64-hex clusterctl sha256 marked trust-on-first-use" {
  grep -Eq '^CLUSTERCTL_SHA256_LINUX_AMD64=[0-9a-f]{64}$' "$ROOT/versions.env"
  grep -qi 'trust on first use' "$ROOT/versions.env"
}
