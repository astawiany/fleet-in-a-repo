#!/usr/bin/env bash
# Install pinned CLI tools on a Linux amd64 CI runner into ${CI_BIN:-$HOME/.local/bin}.
# Usage: scripts/ci-install-tools.sh <tool>...   (kind clusterctl flux helm kubectl kubeconform kustomize yq)
# Versions come from versions.env. Every download is sha256-verified: against the checksum file the
# project publishes next to the artifact, except clusterctl (upstream publishes none), which is
# checked against CLUSTERCTL_SHA256_LINUX_AMD64 pinned in versions.env (trust on first use).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"
BIN="${CI_BIN:-$HOME/.local/bin}"
mkdir -p "$BIN"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

get() { curl -fsSL --retry 3 -o "$2" "$1"; }

# verify <file> <expected-sha256>
verify() {
  local got
  got="$(sha256sum "$1" | cut -d' ' -f1)"
  [ "$got" = "$2" ] || { echo "ci-install-tools: checksum mismatch for $1 ($got != $2)" >&2; exit 1; }
}

install_tool() {
  case "$1" in
    kind)
      u="https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-linux-amd64"
      get "$u" "$tmp/kind"; get "$u.sha256sum" "$tmp/kind.sum"
      verify "$tmp/kind" "$(cut -d' ' -f1 "$tmp/kind.sum")"
      install -m 0755 "$tmp/kind" "$BIN/kind" ;;
    clusterctl)
      get "https://github.com/kubernetes-sigs/cluster-api/releases/download/v${CLUSTERCTL_VERSION}/clusterctl-linux-amd64" "$tmp/clusterctl"
      verify "$tmp/clusterctl" "$CLUSTERCTL_SHA256_LINUX_AMD64"
      install -m 0755 "$tmp/clusterctl" "$BIN/clusterctl" ;;
    flux)
      b="https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}"
      t="flux_${FLUX_VERSION}_linux_amd64.tar.gz"
      get "$b/$t" "$tmp/$t"; get "$b/flux_${FLUX_VERSION}_checksums.txt" "$tmp/flux.sum"
      verify "$tmp/$t" "$(grep " $t\$" "$tmp/flux.sum" | cut -d' ' -f1)"
      tar -xzf "$tmp/$t" -C "$tmp" flux; install -m 0755 "$tmp/flux" "$BIN/flux" ;;
    helm)
      u="https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
      get "$u" "$tmp/helm.tgz"; get "$u.sha256sum" "$tmp/helm.sum"
      verify "$tmp/helm.tgz" "$(cut -d' ' -f1 "$tmp/helm.sum")"
      tar -xzf "$tmp/helm.tgz" -C "$tmp" linux-amd64/helm; install -m 0755 "$tmp/linux-amd64/helm" "$BIN/helm" ;;
    kubectl)
      u="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
      get "$u" "$tmp/kubectl"; get "$u.sha256" "$tmp/kubectl.sum"
      verify "$tmp/kubectl" "$(cut -d' ' -f1 "$tmp/kubectl.sum")"
      install -m 0755 "$tmp/kubectl" "$BIN/kubectl" ;;
    kubeconform)
      b="https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}"
      t="kubeconform-linux-amd64.tar.gz"
      get "$b/$t" "$tmp/$t"; get "$b/CHECKSUMS" "$tmp/kc.sum"
      verify "$tmp/$t" "$(grep " $t\$" "$tmp/kc.sum" | cut -d' ' -f1)"
      tar -xzf "$tmp/$t" -C "$tmp" kubeconform; install -m 0755 "$tmp/kubeconform" "$BIN/kubeconform" ;;
    kustomize)
      b="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}"
      t="kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
      get "$b/$t" "$tmp/$t"; get "$b/checksums.txt" "$tmp/kz.sum"
      verify "$tmp/$t" "$(grep " $t\$" "$tmp/kz.sum" | cut -d' ' -f1)"
      tar -xzf "$tmp/$t" -C "$tmp" kustomize; install -m 0755 "$tmp/kustomize" "$BIN/kustomize" ;;
    yq)
      b="https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}"
      get "$b/yq_linux_amd64" "$tmp/yq"; get "$b/checksums" "$tmp/yq.sum"; get "$b/checksums_hashes_order" "$tmp/yq.order"
      # yq's checksums file is "<name> <hash1> <hash2> ...", columns named by checksums_hashes_order
      col="$(grep -n '^SHA-256$' "$tmp/yq.order" | cut -d: -f1)"
      [ -n "$col" ] || { echo "ci-install-tools: no SHA-256 column in yq checksums_hashes_order" >&2; exit 1; }
      verify "$tmp/yq" "$(awk -v c="$((col + 1))" '$1 == "yq_linux_amd64" { print $c }' "$tmp/yq.sum")"
      install -m 0755 "$tmp/yq" "$BIN/yq" ;;
    *) echo "ci-install-tools: unknown tool '$1'" >&2; exit 1 ;;
  esac
  echo "ci-install-tools: installed $1"
}

[ "$#" -gt 0 ] || { echo "usage: $0 <tool>..." >&2; exit 2; }
for t in "$@"; do install_tool "$t"; done
