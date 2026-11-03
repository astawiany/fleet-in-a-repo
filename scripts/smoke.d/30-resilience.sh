#!/usr/bin/env bash
# Resilience: delete one pod of the demo api Deployment; within SMOKE_RESILIENCE_TIMEOUT (60) s
# the Deployment is back to its desired replicas, counting only Ready pods other than the
# deleted one that are not terminating.
# Usage: 30-resilience.sh <cluster>   (KUBECONFIG points at the cluster)
set -uo pipefail

cluster="$1"
NS=demo
DEPLOY=demo-api
SELECTOR="app.kubernetes.io/instance=demo,app.kubernetes.io/component=api"
TIMEOUT="${SMOKE_RESILIENCE_TIMEOUT:-60}"
POLL="${SMOKE_POLL:-2}"

desired="$(kubectl -n "$NS" get deployment "$DEPLOY" -o jsonpath='{.spec.replicas}' 2>&1)"
if ! [[ "$desired" =~ ^[0-9]+$ ]] || [ "$desired" -lt 1 ]; then
  echo "FAIL resilience $cluster deployment/$DEPLOY (cannot read desired replicas: $desired)"
  exit 0
fi
victim="$(kubectl -n "$NS" get pods -l "$SELECTOR" -o json 2> /dev/null \
  | jq -r '[.items[] | select(.metadata.deletionTimestamp == null)][0].metadata.name // empty')"
if [ -z "$victim" ]; then
  echo "FAIL resilience $cluster deployment/$DEPLOY (no running api pod to delete)"
  exit 0
fi
if ! kubectl -n "$NS" delete pod "$victim" --wait=false > /dev/null; then
  echo "FAIL resilience $cluster pod/$victim (delete failed)"
  exit 0
fi

start=$SECONDS
ready=0
while :; do
  ready="$(kubectl -n "$NS" get pods -l "$SELECTOR" -o json 2> /dev/null | jq --arg v "$victim" '
    [.items[]
      | select(.metadata.name != $v and .metadata.deletionTimestamp == null)
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))]
    | length')"
  [ -n "$ready" ] || ready=0
  elapsed=$((SECONDS - start))
  if [ "$ready" -ge "$desired" ]; then
    echo "PASS resilience $cluster deployment/$DEPLOY (pod/$victim deleted; $ready/$desired Ready after ${elapsed}s)"
    exit 0
  fi
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo "FAIL resilience $cluster deployment/$DEPLOY (pod/$victim deleted; only $ready/$desired Ready after ${TIMEOUT}s)"
    exit 0
  fi
  sleep "$POLL"
done
