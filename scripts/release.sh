#!/usr/bin/env bash
# Release helpers for .github/workflows/release.yml. Each command checks one thing and fails closed.
# Usage: scripts/release.sh <command> [args]
#   check-tag <ref_name>              print the version of chart-vX.Y.Z; fail on anything else
#   check-ancestor <rev> [<base>]     fail unless <rev> (a tag is peeled to its commit) is in the
#                                     history of <base> (default origin/main): releases come from main
#   check-absent <ref>                fail if <ref> already exists in its registry (tags are mutable on
#                                     GHCR: never overwrite); exit 2 when the registry answer is neither
#                                     "exists" nor "not found" (auth, network): unknown is not absent
#   build <buildx flags>...           docker buildx build of apps/demo/src for linux/amd64 with the
#                                     release build args from the environment (VERSION, REVISION,
#                                     SOURCE, SOURCE_DATE_EPOCH; BUILDER, default "release"). The scan
#                                     build and the push build both go through here, so they cannot
#                                     drift apart.
#   assert-scanned <local image> <ref@digest>
#                                     fail unless the pushed linux/amd64 image has the same config
#                                     digest (same layers diff_ids, labels, entrypoint) as the scanned one
#   assert-tag <repo:tag> <digest>    fail unless <repo:tag> resolves to <digest> in the registry
#   identity-regexp <owner/repo>      print the Sigstore certificate identity regexp of release.yml
#   image-digest <metadata.json>      print containerimage.digest from a buildx --metadata-file
#   helm-digest <file>                print the digest from saved `helm push` output
#   local-config-digest <image>       print the config digest of a local image (via docker save)
#   remote-config-digest <ref@digest> [<os/arch>]
#                                     print the config digest of the <os/arch> image (default
#                                     linux/amd64) in a pushed index or manifest
#   govulncheck [<module dir>]        run govulncheck (GOVULNCHECK_VERSION) on apps/demo/src inside the
#                                     Dockerfile's pinned builder image, so the analysed toolchain and
#                                     stdlib are the ones the image is built with
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "release: $*" >&2; exit 1; }
digest_re='^sha256:[0-9a-f]{64}$'

check_tag() {
  local tag="${1:-}"
  [[ "$tag" =~ ^chart-v([0-9]+\.[0-9]+\.[0-9]+)$ ]] \
    || die "tag '$tag' is not chart-vMAJOR.MINOR.PATCH (no prerelease or build suffix)"
  echo "${BASH_REMATCH[1]}"
}

check_ancestor() {
  local rev="${1:-}" base="${2:-origin/main}" commit
  [ -n "$rev" ] || die "check-ancestor needs a revision"
  commit="$(git -C "$ROOT" rev-parse --verify -q "${rev}^{commit}")" || die "unknown revision '$rev'"
  git -C "$ROOT" rev-parse --verify -q "${base}^{commit}" > /dev/null \
    || die "unknown base '$base' (fetch it first)"
  git -C "$ROOT" merge-base --is-ancestor "$commit" "$base" \
    || die "$rev ($commit) is not on $base: releases are cut from $base only"
  echo "release: $rev ($commit) is on $base"
}

check_absent() {
  local ref="${1:-}" out
  [ -n "$ref" ] || die "check-absent needs an image reference"
  # a missing or broken docker/buildx must not read as "not published"
  if ! docker buildx version > /dev/null 2>&1; then
    echo "release: docker buildx is not usable, cannot check whether $ref exists" >&2
    exit 2
  fi
  if out="$(docker buildx imagetools inspect --raw "$ref" 2>&1)"; then
    die "$ref already exists: refusing to overwrite a published version (bump the version instead)"
  fi
  case "$out" in
    # only a registry answer about this very ref counts as "absent"
    *"$ref: not found"* | *"manifest unknown"* | *MANIFEST_UNKNOWN* | *NAME_UNKNOWN*)
      echo "release: $ref does not exist yet" ;;
    *)
      echo "release: cannot tell whether $ref exists (registry said: $out)" >&2
      exit 2 ;;
  esac
}

image_digest() {
  local f="${1:-}" d
  [ -f "$f" ] || die "no metadata file '$f'"
  d="$(jq -r '."containerimage.digest" // empty' "$f")"
  [[ "$d" =~ $digest_re ]] || die "no valid containerimage.digest in $f (got '$d')"
  echo "$d"
}

helm_digest() {
  local f="${1:-}" d
  [ -f "$f" ] || die "no helm push output '$f'"
  d="$(sed -nE 's/^Digest:[[:space:]]+(sha256:[0-9a-f]{64})[[:space:]]*$/\1/p' "$f")"
  [ "$(printf '%s' "$d" | grep -c '^sha256:' || true)" = "1" ] || die "could not parse exactly one digest from helm push output in $f"
  echo "$d"
}

local_config_digest() {
  local img="${1:-}" cfg hex
  [ -n "$img" ] || die "local-config-digest needs an image"
  # docker save writes manifest.json in both image stores: Config is "<hex>.json" (classic) or
  # "blobs/sha256/<hex>" (containerd); .Id would be the manifest digest in the containerd store.
  cfg="$(docker save "$img" | tar -xOf - manifest.json | jq -r '.[0].Config')"
  hex="$(printf '%s' "$cfg" | sed -nE 's#^(blobs/sha256/)?([0-9a-f]{64})(\.json)?$#\2#p')"
  [ -n "$hex" ] || die "could not read the config digest of $img (manifest.json Config: '$cfg')"
  echo "sha256:$hex"
}

remote_config_digest() {
  local ref="${1:-}" platform="${2:-linux/amd64}" raw mt m d os arch
  [[ "$ref" == *@sha256:* ]] || die "remote-config-digest needs <repo>@sha256:<digest> (never a tag)"
  os="${platform%%/*}"; arch="${platform#*/}"
  raw="$(docker buildx imagetools inspect --raw "$ref")"
  mt="$(printf '%s' "$raw" | jq -r '.mediaType // empty')"
  case "$mt" in
    application/vnd.oci.image.index.v1+json | application/vnd.docker.distribution.manifest.list.v2+json)
      m="$(printf '%s' "$raw" | jq -r --arg os "$os" --arg arch "$arch" \
        '[.manifests[] | select(.platform.os == $os and .platform.architecture == $arch)] | if length == 1 then .[0].digest else empty end')"
      [ -n "$m" ] || die "no single $platform manifest in $ref"
      raw="$(docker buildx imagetools inspect --raw "${ref%@*}@$m")" ;;
  esac
  d="$(printf '%s' "$raw" | jq -r '.config.digest // empty')"
  [[ "$d" =~ $digest_re ]] || die "no config digest in $ref"
  echo "$d"
}

build() {
  local v
  for v in VERSION REVISION SOURCE SOURCE_DATE_EPOCH; do
    [ -n "${!v:-}" ] || die "build needs $v in the environment"
  done
  [[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || die "SOURCE_DATE_EPOCH must be a unix timestamp"
  docker buildx build --builder "${BUILDER:-release}" --platform linux/amd64 \
    --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" --build-arg "VERSION=$VERSION" \
    --build-arg "REVISION=$REVISION" --build-arg "SOURCE=$SOURCE" \
    "$@" "$ROOT/apps/demo/src"
}

assert_scanned() {
  local img="${1:-}" ref="${2:-}" scanned pushed
  [ -n "$img" ] && [ -n "$ref" ] || die "assert-scanned needs <local image> <ref@digest>"
  scanned="$(local_config_digest "$img")"
  pushed="$(remote_config_digest "$ref" linux/amd64)"
  [ "$scanned" = "$pushed" ] \
    || die "pushed image $ref (config $pushed) is not the scanned image $img (config $scanned)"
  echo "release: pushed image config $pushed equals the scanned image config"
}

assert_tag() {
  local ref="${1:-}" want="${2:-}" got
  [[ "$ref" == *:* && "$ref" != *@* ]] || die "assert-tag needs <repo:tag> (got '$ref')"
  [[ "$want" =~ $digest_re ]] || die "assert-tag needs a sha256 digest (got '$want')"
  got="$(docker buildx imagetools inspect --format '{{json .Manifest}}' "$ref" | jq -r '.digest // empty')"
  [ "$got" = "$want" ] || die "$ref resolves to '$got', expected the signed digest $want"
  echo "release: $ref resolves to $want"
}

identity_regexp() {
  local repo="${1:-}"
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "identity-regexp needs owner/repo (got '$repo')"
  printf '^https://github\\.com/%s/\\.github/workflows/release\\.yml@refs/tags/chart-v[0-9]+\\.[0-9]+\\.[0-9]+$\n' "${repo//./\\.}"
}

run_govulncheck() {
  # shellcheck disable=SC1091
  source "$ROOT/versions.env"
  local src="${1:-$ROOT/apps/demo/src}" builder
  builder="$(awk 'toupper($1) == "FROM" && toupper($3) == "AS" && $4 == "build" { print $2; exit }' "$ROOT/apps/demo/src/Dockerfile")"
  [[ "$builder" == *@sha256:* ]] || die "builder image in apps/demo/src/Dockerfile is not digest-pinned ('$builder')"
  [[ "${GOVULNCHECK_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "GOVULNCHECK_VERSION missing from versions.env"
  # govulncheck exits 3 when the code calls a vulnerable symbol; go install verifies the module
  # against the Go checksum database (sum.golang.org).
  docker run --rm -v "$src:/src:ro" -w /src -e GOFLAGS=-mod=readonly "$builder" \
    sh -c "go install golang.org/x/vuln/cmd/govulncheck@v${GOVULNCHECK_VERSION} && govulncheck ./..."
}

cmd="${1:-}"
[ "$#" -gt 0 ] && shift
case "$cmd" in
  check-tag) check_tag "$@" ;;
  check-ancestor) check_ancestor "$@" ;;
  check-absent) check_absent "$@" ;;
  build) build "$@" ;;
  assert-scanned) assert_scanned "$@" ;;
  assert-tag) assert_tag "$@" ;;
  identity-regexp) identity_regexp "$@" ;;
  image-digest) image_digest "$@" ;;
  helm-digest) helm_digest "$@" ;;
  local-config-digest) local_config_digest "$@" ;;
  remote-config-digest) remote_config_digest "$@" ;;
  govulncheck) run_govulncheck "$@" ;;
  *) echo "usage: $0 check-tag|check-ancestor|check-absent|build|assert-scanned|assert-tag|identity-regexp|image-digest|helm-digest|local-config-digest|remote-config-digest|govulncheck" >&2; exit 2 ;;
esac
