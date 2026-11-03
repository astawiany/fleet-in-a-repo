#!/usr/bin/env bash
# Observability: every active Prometheus target is up (read through the API server proxy of
# Service monitoring/kps-prometheus), and Grafana (Service and Secret monitoring/kube-prometheus-stack-grafana:
# the grafana subchart ignores the parent's fullnameOverride) serves both dashboards, uids platform-health and demo-slis.
# Retries for SMOKE_RETRY_TIMEOUT (120) s: freshly created targets start as "unknown".
# Usage: 40-observability.sh <cluster>   (KUBECONFIG points at the cluster)
set -uo pipefail
export LC_ALL=C # "0.012", not "0,012", whatever the user locale

cluster="$1"
NS=monitoring
TARGETS="/api/v1/namespaces/$NS/services/http:kps-prometheus:9090/proxy/api/v1/targets?state=active"
GRAFANA=kube-prometheus-stack-grafana
DASHBOARDS="platform-health demo-slis"
TIMEOUT="${SMOKE_RETRY_TIMEOUT:-120}"
POLL="${SMOKE_POLL:-5}"

tmp="$(mktemp -d)"
pf=""
cleanup() {
  if [ -n "$pf" ]; then
    kill "$pf" 2> /dev/null
    wait "$pf" 2> /dev/null
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# targets_problems: print what is wrong with the targets, nothing when all are up.
targets_problems() {
  local json
  if ! json="$(kubectl get --raw "$TARGETS" 2>&1)"; then
    echo "prometheus unreachable: $(head -n 1 <<< "$json")"
    return
  fi
  jq -r '
    (.data.activeTargets // []) as $t
    | if ($t | length) == 0 then "no active Prometheus targets"
      else [$t[] | select(.health != "up")
              | "target \(.scrapePool) \(.labels.instance) \(.health): \(.lastError)"] | join("; ")
      end' <<< "$json" 2> /dev/null || echo "unexpected Prometheus answer"
}

# dashboards_problems: print the dashboards Grafana does not serve, nothing when all are there.
dashboards_problems() {
  local secret user pass creds port="" missing="" uid code
  if ! secret="$(kubectl -n "$NS" get secret "$GRAFANA" -o json 2>&1)"; then
    echo "grafana secret: $(head -n 1 <<< "$secret")"
    return
  fi
  user="$(jq -r '.data["admin-user"] | @base64d' <<< "$secret")"
  pass="$(jq -r '.data["admin-password"] | @base64d' <<< "$secret")"
  if [ -z "$pf" ] || ! kill -0 "$pf" 2> /dev/null; then
    kubectl -n "$NS" port-forward "svc/$GRAFANA" :80 > "$tmp/pf.log" 2>&1 &
    pf=$!
  fi
  for _ in $(seq 1 50); do
    port="$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) .*/\1/p' "$tmp/pf.log" | head -n 1)"
    [ -z "$port" ] || break
    kill -0 "$pf" 2> /dev/null || break
    sleep 0.2
  done
  if [ -z "$port" ]; then
    echo "grafana port-forward failed: $(head -n 1 "$tmp/pf.log")"
    return
  fi
  # Credentials go to curl as a config on stdin (-K -), never in argv (visible in ps); \ and "
  # are escaped for the config file's quoted string.
  creds="$(printf '%s:%s' "$user" "$pass" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  for uid in $DASHBOARDS; do
    code="$(printf 'user = "%s"\n' "$creds" | curl -K - -s -o /dev/null --max-time 10 -w '%{http_code}' \
      "http://127.0.0.1:$port/api/dashboards/uid/$uid")"
    [ "$code" = 200 ] || missing="$missing${missing:+; }dashboard $uid missing (HTTP $code)"
  done
  echo "$missing"
}

start=$SECONDS
while :; do
  problems="$(targets_problems)"
  d="$(dashboards_problems)"
  problems="$problems${problems:+${d:+; }}$d"
  if [ -z "$problems" ]; then
    n="$(kubectl get --raw "$TARGETS" | jq '.data.activeTargets | length')"
    echo "PASS observability $cluster ($n Prometheus targets up; dashboards ${DASHBOARDS// /, } present)"
    exit 0
  fi
  if [ $((SECONDS - start)) -ge "$TIMEOUT" ]; then
    echo "FAIL observability $cluster $problems"
    exit 0
  fi
  sleep "$POLL"
done
