#!/usr/bin/env bash
# Performance: p95 latency of GET /feature on the demo web Service over SMOKE_REQUESTS (200)
# requests is below SMOKE_P95_MS (200) ms, and every request answers 200. Requests go through
# `kubectl port-forward` (the MetalLB IPs live on the Docker network, unreachable from macOS),
# so the figure includes the API server tunnel and is an upper bound of in-cluster latency.
# Usage: 20-performance.sh <cluster>   (KUBECONFIG points at the cluster)
set -uo pipefail
export LC_ALL=C # "0.012", not "0,012", whatever the user locale

cluster="$1"
NS=demo
SVC=demo-web
REQUESTS="${SMOKE_REQUESTS:-200}"
P95_MS="${SMOKE_P95_MS:-200}"

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

kubectl -n "$NS" port-forward "svc/$SVC" :80 > "$tmp/pf.log" 2>&1 &
pf=$!
port=""
for _ in $(seq 1 50); do
  port="$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) .*/\1/p' "$tmp/pf.log" | head -n 1)"
  [ -z "$port" ] || break
  kill -0 "$pf" 2> /dev/null || break
  sleep 0.2
done
if [ -z "$port" ]; then
  echo "FAIL performance $cluster svc/$SVC (port-forward failed: $(head -n 1 "$tmp/pf.log"))"
  exit 0
fi

# Exactly one line per request: a failed curl still writes its -w line ("000 <time>"); only when it
# wrote nothing does the request count as "000 5" (the --max-time).
for _ in $(seq 1 "$REQUESTS"); do
  r="$(curl -s -o /dev/null --max-time 5 -w '%{http_code} %{time_total}' "http://127.0.0.1:$port/feature")"
  echo "${r:-000 5}"
done > "$tmp/results"

errors="$(awk '$1 != 200' "$tmp/results" | wc -l | tr -d ' ')"
count="$(wc -l < "$tmp/results" | tr -d ' ')"
# p95 = the ceil(0.95 * n)-th smallest latency, in whole milliseconds
p95="$(awk '{ printf "%d\n", $2 * 1000 + 0.5 }' "$tmp/results" | sort -n \
  | awk '{ v[NR] = $1 } END { i = int(NR * 0.95); if (i < NR * 0.95) i++; print v[i] }')"

if [ "$count" -ne "$REQUESTS" ] || [ "$errors" -ne 0 ]; then
  echo "FAIL performance $cluster svc/$SVC ($errors of $count requests to /feature did not return 200; p95=${p95}ms)"
elif [ "$p95" -ge "$P95_MS" ]; then
  echo "FAIL performance $cluster svc/$SVC (p95=${p95}ms >= ${P95_MS}ms over $count requests to /feature)"
else
  echo "PASS performance $cluster svc/$SVC (p95=${p95}ms < ${P95_MS}ms over $count requests to /feature)"
fi
