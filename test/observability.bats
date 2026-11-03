#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CFG="$ROOT/infrastructure/base/monitoring/config"
  RULES="$CFG/slo-rules.yaml"
}

@test "dashboard JSON files parse and have the stable uid and title" {
  [ -f "$CFG/dashboards/platform.json" ]
  [ -f "$CFG/dashboards/demo-slis.json" ]
  jq -e '.uid == "platform-health" and .title == "Platform health" and (.panels | length) > 0' "$CFG/dashboards/platform.json"
  jq -e '.uid == "demo-slis" and .title == "Demo SLIs" and (.panels | length) > 0' "$CFG/dashboards/demo-slis.json"
}

@test "dashboards query the metrics they are about" {
  grep -q gotk_reconcile_condition "$CFG/dashboards/platform.json"
  grep -q kube_node_status_allocatable "$CFG/dashboards/platform.json"
  grep -q http_request_duration_seconds_bucket "$CFG/dashboards/demo-slis.json"
  grep -q http_requests_total "$CFG/dashboards/demo-slis.json"
}

@test "dashboards ConfigMaps carry the sidecar label and embed the JSON" {
  out="$(cd "$CFG" && kustomize build .)"
  [ "$(echo "$out" | yq -N 'select(.kind=="ConfigMap" and .metadata.labels.grafana_dashboard=="1") | .metadata.name' | wc -l | tr -d ' ')" = "2" ]
  echo "$out" | yq -N 'select(.kind=="ConfigMap" and .metadata.labels.grafana_dashboard=="1") | .metadata.namespace' | grep -qx monitoring
}

@test "PrometheusRule demo-slo contains alerts DemoErrorBudgetBurnFast and DemoErrorBudgetBurnSlow" {
  [ "$(yq -N '.metadata.name' "$RULES")" = "demo-slo" ]
  alerts="$(yq -N '.spec.groups[].rules[].alert' "$RULES")"
  echo "$alerts" | grep -qx DemoErrorBudgetBurnFast
  echo "$alerts" | grep -qx DemoErrorBudgetBurnSlow
}

@test "every alert expr references http_requests_total" {
  n="$(yq -N '[.spec.groups[].rules[] | select(has("alert"))] | length' "$RULES")"
  [ "$n" -ge 2 ]
  m="$(yq -N '[.spec.groups[].rules[] | select(has("alert")) | select(.expr | contains("http_requests_total"))] | length' "$RULES")"
  [ "$n" = "$m" ]
}

@test "promtool check rules passes" {
  . "$ROOT/versions.env"
  tmp="$BATS_TEST_TMPDIR/rules"; mkdir -p "$tmp"; chmod 755 "$tmp"
  yq -N '.spec' "$RULES" > "$tmp/rules.yaml"
  if command -v promtool > /dev/null 2>&1; then
    promtool check rules "$tmp/rules.yaml"
  elif command -v docker > /dev/null 2>&1; then
    docker run --rm -v "$tmp:/r:ro" --entrypoint promtool "$PROMTOOL_IMAGE" check rules /r/rules.yaml
  else
    echo "neither promtool nor docker is available" >&2
    false
  fi
}

@test "Flux controllers are scraped and the rules apply after the monitoring CRDs" {
  [ "$(yq -N 'select(.kind=="PodMonitor") | .metadata.name' "$CFG/flux-podmonitor.yaml")" = "flux-controllers" ]
  c="$ROOT/infrastructure/base/components.yaml"
  [ "$(yq -N 'select(.kind=="Kustomization" and .metadata.name=="monitoring-config") | .spec.dependsOn[0].name' "$c")" = "monitoring" ]
  [ "$(yq -N 'select(.kind=="Kustomization" and .metadata.name=="monitoring-config") | .spec.path' "$c")" = "./infrastructure/base/monitoring/config" ]
}
