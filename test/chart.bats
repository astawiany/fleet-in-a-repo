#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHART="$ROOT/apps/demo/chart"
  VALUES="$ROOT/apps/demo/values"
}

render() { helm template demo "$CHART" -f "$VALUES/$1.yaml" 2>/dev/null; }

@test "acme-dev renders FEATURE_NEW_BANNER=true and globex-dev renders false" {
  run bash -c "helm template demo '$CHART' -f '$VALUES/acme-dev.yaml' 2>/dev/null | yq -N 'select(.kind==\"Deployment\") | .spec.template.spec.containers[].env[] | select(.name==\"FEATURE_NEW_BANNER\") | .value' | sort -u"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  run bash -c "helm template demo '$CHART' -f '$VALUES/globex-dev.yaml' 2>/dev/null | yq -N 'select(.kind==\"Deployment\") | .spec.template.spec.containers[].env[] | select(.name==\"FEATURE_NEW_BANNER\") | .value' | sort -u"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "prod renders replicas 2 for web and dev renders 1" {
  run bash -c "helm template demo '$CHART' -f '$VALUES/acme-prod.yaml' 2>/dev/null | yq -N 'select(.kind==\"Deployment\" and .metadata.name==\"demo-web\") | .spec.replicas'"
  [ "$output" = "2" ]
  run bash -c "helm template demo '$CHART' -f '$VALUES/acme-dev.yaml' 2>/dev/null | yq -N 'select(.kind==\"Deployment\" and .metadata.name==\"demo-web\") | .spec.replicas'"
  [ "$output" = "1" ]
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
    ! echo "$out" | grep -q 'privileged: true'
  done
}

@test "every Deployment carries the required labels" {
  out="$(render acme-dev)"
  for k in name part-of component managed-by instance; do
    [ "$(echo "$out" | yq -N "select(.kind==\"Deployment\") | .metadata.labels.\"app.kubernetes.io/$k\"" | grep -vc '^null$')" = "3" ]
  done
  [ "$(echo "$out" | yq -N 'select(.kind=="Deployment") | .metadata.labels."app.kubernetes.io/part-of"' | sort -u)" = "fleet-demo" ]
}

@test "a NetworkPolicy exists" {
  run bash -c "helm template demo '$CHART' -f '$VALUES/acme-dev.yaml' 2>/dev/null | yq -N 'select(.kind==\"NetworkPolicy\") | .metadata.name'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
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
