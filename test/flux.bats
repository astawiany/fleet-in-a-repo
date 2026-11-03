#!/usr/bin/env bats
# Flux layout: management profiles, per-cluster entrypoints and infrastructure wiring.
# Uses the real kustomize binary; no cluster needed.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# doc KIND NAME: read a multi-document YAML stream on stdin, print the document of that kind/name.
doc() {
  awk -v kind="kind: $1" -v name="  name: $2" '
    function flush() { if (k && n) printf "%s", buf; buf = ""; k = 0; n = 0 }
    /^---/ { flush(); next }
    { buf = buf $0 "\n"; if ($0 == kind) k = 1; if ($0 == name) n = 1 }
    END { flush() }'
}

# workload cluster names, from capi/customers/*.yaml
clusters() {
  for f in "$ROOT"/capi/customers/*.yaml; do basename "$f" .yaml; done
}

# capi_clusters PROFILE: Cluster names that the management Kustomization for PROFILE applies.
capi_clusters() {
  local t="$BATS_TEST_TMPDIR/capi-$1"
  mkdir -p "$t"
  ln -s "$ROOT/capi" "$t/capi"
  printf 'resources:\n  - capi\n' > "$t/kustomization.yaml"
  local c
  for c in $(sed -n 's#^    - \(profiles/.*\)$#\1#p' "$ROOT/clusters/management/$1/workload-clusters.yaml"); do
    printf 'components:\n  - capi/%s\n' "$c" >> "$t/kustomization.yaml"
  done
  kustomize build "$t" > "$t/out.yaml" || return 1
  awk '/^---/ { c = 0 } /^kind: Cluster$/ { c = 1 } c && /^  name: / { print $2 }' "$t/out.yaml" | sort
}

@test "every workload cluster has a flux-system, infrastructure and apps entrypoint" {
  n=0
  for c in $(clusters); do
    env="${c##*-}"
    d="$ROOT/clusters/$c"
    run kustomize build "$d"
    [ "$status" -eq 0 ]
    out="$output"

    ks="$(doc Kustomization infrastructure <<< "$out")"
    [[ "$ks" == *"path: ./infrastructure/overlays/$env"* ]] || false
    [[ "$ks" == *"wait: true"* ]] || false
    [[ "$ks" == *"name: cluster-vars"* ]] || false

    ks="$(doc Kustomization apps <<< "$out")"
    [[ "$ks" == *"path: ./apps/demo/flux/$c"* ]] || false
    [[ "$ks" == *"dependsOn:"*"- name: infrastructure"* ]] || false
    # kustomize-controller rejects a kustomization that yields no objects
    [ -n "$(kustomize build "$ROOT/apps/demo/flux/$c")" ]

    ks="$(doc Kustomization flux-system <<< "$out")"
    [[ "$ks" == *"path: ./clusters/$c"* ]] || false
    src="$(doc GitRepository flux-system <<< "$out")"
    [[ "$src" == *"url: http://fleet-git/cgi-bin/git/fleet.git"* ]] || false
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
}

@test "each environment overlay wires all platform components with health checks" {
  for env in dev prod; do
    run kustomize build "$ROOT/infrastructure/overlays/$env"
    [ "$status" -eq 0 ]
    out="$output"
    for comp in cert-manager gateway-api-crds nginx-gateway-fabric metallb metallb-pool monitoring; do
      ks="$(doc Kustomization "$comp" <<< "$out")"
      [ -n "$ks" ]
      [[ "$ks" == *"wait: true"* ]] || false
      if [ "$comp" != gateway-api-crds ]; then
        [[ "$ks" == *"name: cluster-vars"* ]] || false
      fi
    done
  done
}

@test "nginx-gateway-fabric reconciles after the Gateway API CRDs" {
  ks="$(kustomize build "$ROOT/infrastructure/overlays/dev" | doc Kustomization nginx-gateway-fabric)"
  [[ "$ks" == *"dependsOn:"*"- name: gateway-api-crds"* ]] || false
  ks="$(kustomize build "$ROOT/infrastructure/overlays/dev" | doc Kustomization gateway-api-crds)"
  [[ "$ks" == *"path: ./config/crd"* ]] || false
  src="$(kustomize build "$ROOT/infrastructure/overlays/dev" | doc GitRepository gateway-api)"
  [[ "$src" == *'tag: v${GATEWAY_API_VERSION}'* ]] || false
}

@test "metallb-pool applies the address pool after MetalLB itself" {
  ks="$(kustomize build "$ROOT/infrastructure/overlays/dev" | doc Kustomization metallb-pool)"
  [[ "$ks" == *"dependsOn:"*"- name: metallb"* ]] || false
  run kustomize build "$ROOT/infrastructure/base/metallb/pool"
  [ "$status" -eq 0 ]
  [[ "$output" == *'- ${METALLB_POOL}'* ]] || false
  [[ "$output" == *"kind: L2Advertisement"* ]] || false
}

@test "fleet-gateway: GatewayClass nginx, HTTP on port 80, routes from namespace demo" {
  gw="$(kustomize build "$ROOT/infrastructure/base/nginx-gateway-fabric" | doc Gateway fleet-gateway)"
  [[ "$gw" == *"namespace: nginx-gateway"* ]] || false
  [[ "$gw" == *"gatewayClassName: nginx"* ]] || false
  [[ "$gw" == *"port: 80"* ]] || false
  [[ "$gw" == *"protocol: HTTP"* ]] || false
  [[ "$gw" == *"kubernetes.io/metadata.name: demo"* ]] || false
}

@test "platform namespaces are declared" {
  all="$(for d in "$ROOT"/infrastructure/base/*/; do kustomize build "$d"; echo ---; done)"
  for ns in cert-manager nginx-gateway metallb-system monitoring demo; do
    [ -n "$(doc Namespace "$ns" <<< "$all")" ]
  done
}

@test "every HelmRelease chart version is substituted from versions.env" {
  n=0
  for f in "$ROOT"/infrastructure/base/*/release.yaml; do
    run grep -E '^      version: ' "$f"
    [ "$status" -eq 0 ]
    [[ "$output" == *'${'*'_VERSION}'* ]] || false
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
}

@test "management profiles: full applies every customer cluster, lite only lite customers" {
  # shellcheck source=scripts/lib.sh
  source "$ROOT/scripts/lib.sh"
  for p in full lite; do
    f="$ROOT/clusters/management/$p/workload-clusters.yaml"
    grep -q '^  name: workload-clusters$' "$f"
    grep -q '^  path: ./capi$' "$f"
    grep -q 'name: fleet-vars' "$f"
    want="$(for c in $(FLEET_PROFILE=$p customers); do printf '%s-dev\n%s-prod\n' "$c" "$c"; done | sort)"
    run capi_clusters "$p"
    [ "$status" -eq 0 ]
    [ "$output" = "$want" ]
  done
}
