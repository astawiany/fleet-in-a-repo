#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHART="$ROOT/apps/demo/chart"
  VALUES="$ROOT/apps/demo/values"
}

render() { helm template demo "$CHART" -f "$VALUES/$1.yaml"; }

@test "acme-dev renders FEATURE_NEW_BANNER=true and globex-dev renders false" {
  q='select(.kind=="Deployment") | .spec.template.spec.containers[].env[] | select(.name=="FEATURE_NEW_BANNER") | .value'
  [ "$(render acme-dev | yq -N "$q" | sort -u)" = "true" ]
  [ "$(render globex-dev | yq -N "$q" | sort -u)" = "false" ]
}

@test "prod renders replicas 2 for web and dev renders 1" {
  q='select(.kind=="Deployment" and .metadata.name=="demo-web") | .spec.replicas'
  [ "$(render acme-prod | yq -N "$q")" = "2" ]
  [ "$(render acme-dev | yq -N "$q")" = "1" ]
}

@test "renders 3 Deployments and 2 Services" {
  out="$(render globex-prod)"
  [ "$(echo "$out" | yq -N 'select(.kind=="Deployment") | .metadata.name' | wc -l | tr -d ' ')" = "3" ]
  [ "$(echo "$out" | yq -N 'select(.kind=="Service") | .metadata.name' | wc -l | tr -d ' ')" = "2" ]
}

@test "every Deployment has non-root securityContext and no privileged container" {
  for v in acme-dev acme-prod globex-dev globex-prod; do
    out="$(render "$v")"
    [ "$(echo "$out" | yq -N 'select(.kind=="Deployment") | .spec.template.spec.securityContext.runAsNonRoot' | grep -c '^true$')" = "3" ]
    [ "$(echo "$out" | yq -N 'select(.kind=="Deployment") | .spec.template.spec.containers[].securityContext.allowPrivilegeEscalation' | grep -c '^false$')" = "3" ]
    [ "$(echo "$out" | yq -N 'select(.kind=="Deployment") | .spec.template.spec.containers[].securityContext.readOnlyRootFilesystem' | grep -c '^true$')" = "3" ]
    [ "$(echo "$out" | yq -N 'select(.kind=="Deployment") | .spec.template.spec.containers[].securityContext.capabilities.drop[]' | grep -c '^ALL$')" = "3" ]
    run grep -q 'privileged: true' <<<"$out"
    [ "$status" -ne 0 ]
  done
}

@test "every Deployment carries the required labels" {
  out="$(render acme-dev)"
  for k in name part-of component managed-by instance; do
    [ "$(echo "$out" | yq -N "select(.kind==\"Deployment\") | .metadata.labels.\"app.kubernetes.io/$k\"" | grep -vc '^null$')" = "3" ]
  done
  [ "$(echo "$out" | yq -N 'select(.kind=="Deployment") | .metadata.labels."app.kubernetes.io/part-of"' | sort -u)" = "fleet-demo" ]
}

@test "default-deny and web-to-api NetworkPolicies exist" {
  out="$(render acme-dev)"
  # default-deny: selects all release pods, Ingress type, no ingress rules
  [ "$(echo "$out" | yq -N 'select(.kind=="NetworkPolicy" and .metadata.name=="demo-default-deny") | .spec.policyTypes[0]')" = "Ingress" ]
  [ "$(echo "$out" | yq -N 'select(.kind=="NetworkPolicy" and .metadata.name=="demo-default-deny") | .spec.ingress')" = "null" ]
  # api accepts ingress from web pods
  api="$(echo "$out" | yq -N 'select(.kind=="NetworkPolicy" and .metadata.name=="demo-allow-web-to-api")')"
  [ "$(echo "$api" | yq -N '.spec.podSelector.matchLabels."app.kubernetes.io/component"')" = "api" ]
  [ "$(echo "$api" | yq -N '.spec.ingress[0].from[0].podSelector.matchLabels."app.kubernetes.io/component"')" = "web" ]
}

@test "hostname from values appears in the HTTPRoute" {
  for v in acme-dev acme-prod globex-dev globex-prod; do
    out="$(render "$v")"
    [ "$(echo "$out" | yq -N 'select(.kind=="HTTPRoute") | .spec.hostnames[0]')" = "demo.$v.fleet.test" ]
    [ "$(echo "$out" | yq -N 'select(.kind=="HTTPRoute") | .spec.parentRefs[0].name')" = "fleet-gateway" ]
    [ "$(echo "$out" | yq -N 'select(.kind=="HTTPRoute") | .spec.parentRefs[0].namespace')" = "nginx-gateway" ]
  done
}

@test "monitoring objects exist for web, api and worker" {
  out="$(render acme-dev)"
  [ "$(echo "$out" | yq -N 'select(.kind=="ServiceMonitor") | .metadata.name' | wc -l | tr -d ' ')" = "2" ]
  [ "$(echo "$out" | yq -N 'select(.kind=="PodMonitor") | .metadata.name' | wc -l | tr -d ' ')" = "1" ]
}

@test "pods mount no service account token, set resource limits and run as UID/GID 65532" {
  for v in acme-dev acme-prod globex-dev globex-prod; do
    out="$(render "$v")"
    [ "$(echo "$out" | yq -N 'select(.kind=="Deployment") | .spec.template.spec.automountServiceAccountToken' | grep -c '^false$')" = "3" ] || { echo "$v: token automounted"; false; }
    for r in cpu memory; do
      [ "$(echo "$out" | yq -N "select(.kind==\"Deployment\") | .spec.template.spec.containers[].resources.limits.$r" | grep -vc '^null$')" = "3" ] || { echo "$v: no $r limit"; false; }
    done
    for k in runAsUser runAsGroup; do
      [ "$(echo "$out" | yq -N "select(.kind==\"Deployment\") | .spec.template.spec.containers[].securityContext.$k" | grep -c '^65532$')" = "3" ] || { echo "$v: container $k"; false; }
    done
  done
}

@test "image is repository:tag by default and repository@digest when image.digest is set" {
  q='select(.kind=="Deployment") | .spec.template.spec.containers[].image'
  want="$(yq '.image.repository + ":" + .image.tag' "$CHART/values.yaml")"
  [ "$want" = "example.invalid/fleet-demo:0.1.0" ]
  [ "$(render acme-dev | yq -N "$q" | sort -u)" = "$want" ] || { render acme-dev | yq -N "$q"; false; }
  d="sha256:$(printf '%064d' 0 | tr 0 a)"
  out="$(helm template demo "$CHART" -f "$VALUES/acme-dev.yaml" --set image.digest="$d")"
  [ "$(echo "$out" | yq -N "$q" | sort -u)" = "example.invalid/fleet-demo@$d" ] || { echo "$out" | yq -N "$q"; false; }
  # a malformed digest or a latest tag is refused instead of rendered
  run helm template demo "$CHART" --set image.digest=sha256:abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"image.digest must look like sha256"* ]] || false
  run helm template demo "$CHART" --set image.tag=latest
  [ "$status" -ne 0 ]
  [[ "$output" == *"not latest"* ]] || false
  # the default values carry an empty digest (offline make up flow stays tag-based)
  [ "$(yq '.image.digest' "$CHART/values.yaml")" = "" ]
}

@test "the chart renders no Secret and no latest image tag" {
  for v in acme-dev acme-prod globex-dev globex-prod; do
    out="$(render "$v")"
    [ "$(echo "$out" | yq -N 'select(.kind=="Secret") | .metadata.name' | grep -vc '^$')" = "0" ] || { echo "$v renders a Secret"; false; }
    run grep -E 'image: .*:latest"?$' <<< "$out"
    [ "$status" -eq 1 ] || { echo "$v: $output"; false; }
  done
}
