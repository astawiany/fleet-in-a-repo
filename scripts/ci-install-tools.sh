#!/usr/bin/env bash
# Install pinned CLI tools on a Linux amd64 CI runner into ${CI_BIN:-$HOME/.local/bin}.
# Usage: scripts/ci-install-tools.sh <tool>...   (kind clusterctl flux helm kubectl kubeconform kustomize yq)
# Versions come from versions.env. Where the project publishes a checksum next to the artifact it
# is verified; kubeconform, clusterctl and yq are fetched over TLS only (no checksum file known).
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
      get "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" "$tmp/kc.tgz"
      tar -xzf "$tmp/kc.tgz" -C "$tmp" kubeconform; install -m 0755 "$tmp/kubeconform" "$BIN/kubeconform" ;;
    kustomize)
      b="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}"
      t="kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
      get "$b/$t" "$tmp/$t"; get "$b/checksums.txt" "$tmp/kz.sum"
      verify "$tmp/$t" "$(grep " $t\$" "$tmp/kz.sum" | cut -d' ' -f1)"
      tar -xzf "$tmp/$t" -C "$tmp" kustomize; install -m 0755 "$tmp/kustomize" "$BIN/kustomize" ;;
    yq)
      get "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" "$tmp/yq"
      install -m 0755 "$tmp/yq" "$BIN/yq" ;;
    *) echo "ci-install-tools: unknown tool '$1'" >&2; exit 1 ;;
  esac
  echo "ci-install-tools: installed $1"
}

[ "$#" -gt 0 ] || { echo "usage: $0 <tool>..." >&2; exit 2; }
for t in "$@"; do install_tool "$t"; done
