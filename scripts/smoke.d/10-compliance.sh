#!/usr/bin/env bash
# Compliance: the demo Deployments (web, api, worker of release "demo" in namespace demo) carry
# the chart's required labels on the Deployment and on the pod template, and every one of their
# pod templates is selected by at least one NetworkPolicy.
# Usage: 10-compliance.sh <cluster>   (KUBECONFIG points at the cluster)
set -uo pipefail

cluster="$1"
NS=demo
DEPLOYMENTS="demo-web demo-api demo-worker"
# Labels every demo workload must carry (apps/demo/chart/templates/_helpers.tpl demo.labels).
REQUIRED='["app.kubernetes.io/name","app.kubernetes.io/instance","app.kubernetes.io/part-of","app.kubernetes.io/component","app.kubernetes.io/managed-by"]'

# shellcheck disable=SC2086 # one name per word
if ! deps="$(kubectl -n "$NS" get deployment $DEPLOYMENTS -o json 2>&1)"; then
  echo "FAIL compliance $cluster deployments ($(head -n 1 <<< "$deps"))"
  exit 0
fi
if ! pols="$(kubectl -n "$NS" get networkpolicies -o json 2>&1)"; then
  echo "FAIL compliance $cluster networkpolicies ($(head -n 1 <<< "$pols"))"
  exit 0
fi

# A selector covers a pod template when it has no matchExpressions and its matchLabels are a
# subset of the template's labels (an empty selector covers every pod).
bad="$(jq -r --argjson req "$REQUIRED" --slurpfile pols <(cat <<< "$pols") '
  [.items[]
    | . as $d
    | (($req - (.metadata.labels // {} | keys)) | map("deployment/\($d.metadata.name) missing label \(.)")) +
      (($req - (.spec.template.metadata.labels // {} | keys)) | map("deployment/\($d.metadata.name) pod template missing label \(.)")) +
      (if [$pols[0].items[]
            | select((.spec.podSelector.matchExpressions // []) | length == 0)
            | (.spec.podSelector.matchLabels // {}) | to_entries
            | all(. as $e | ($d.spec.template.metadata.labels // {})[$e.key] == $e.value)]
          | any
       then [] else ["deployment/\($d.metadata.name) not selected by any NetworkPolicy"] end)
    | .[]]
  | join("; ")' <<< "$deps")"

if [ -n "$bad" ]; then
  echo "FAIL compliance $cluster $bad"
else
  echo "PASS compliance $cluster ($(jq '.items | length' <<< "$deps") deployments labelled and covered by NetworkPolicy)"
fi
