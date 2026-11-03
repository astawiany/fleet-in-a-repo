#!/usr/bin/env bash
# Print the MetalLB address pool of a workload cluster as a CIDR, e.g. 172.18.255.16/28.
# Usage: metallb-pool.sh <cluster>   (<cluster> = a capi/customers/<cluster>.yaml name)
#
# Pools are /28 slices (16 addresses) of the IPv4 subnet of the "kind" Docker network, on which
# all node and load balancer containers live, so L2 announcements reach every cluster.
# Docker hands out container addresses from the bottom of the subnet, so pools come from the top
# /24 of the subnet instead:
#   top  = network address + subnet size - 256           (172.18.0.0/16 -> 172.18.255.0)
#   pool = top + 16 * i, /28                             (i = 0..14)
# where i is the position of <cluster> in the sorted list of capi/customers/*.yaml names (stable
# whatever the profile, distinct per cluster). Slot 15 would hold the broadcast address, and a
# subnet smaller than /23 is refused so the top /24 never meets the containers' addresses.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
  echo "metallb-pool: $*" >&2
  exit 1
}

[ "$#" -eq 1 ] || die "usage: metallb-pool.sh <cluster>"
cluster="$1"

i=-1
n=0
for f in "$ROOT"/capi/customers/*.yaml; do
  [ "$(basename "$f" .yaml)" = "$cluster" ] && i=$n
  n=$((n + 1))
done
[ "$i" -ge 0 ] || die "unknown cluster '$cluster' (no capi/customers/$cluster.yaml)"
[ "$i" -lt 15 ] || die "cluster '$cluster' is #$i; only 15 pools fit in the top /24"

subnet=""
for s in $(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'); do
  case "$s" in *.*.*.*/*) subnet="$s" && break ;; esac
done
[ -n "$subnet" ] || die "the kind Docker network has no IPv4 subnet"

prefix="${subnet#*/}"
[ "$prefix" -le 23 ] || die "kind subnet $subnet is smaller than /23; no room for pools"

IFS=. read -r a b c d <<< "${subnet%/*}"
ip=$(((a << 24) | (b << 16) | (c << 8) | d))
size=$((1 << (32 - prefix)))
start=$(((ip & ~(size - 1) & 0xFFFFFFFF) + size - 256 + 16 * i))

echo "$((start >> 24 & 255)).$((start >> 16 & 255)).$((start >> 8 & 255)).$((start & 255))/28"
