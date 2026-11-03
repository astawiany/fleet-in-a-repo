#!/usr/bin/env bash
# Security, for the application namespace demo (the platform's own kube-proxy/kindnet pods in
# kube-system are privileged by design on kind and out of scope):
#   - no pod runs a privileged container (containers, initContainers, ephemeralContainers);
#   - a default-deny ingress NetworkPolicy (policyTypes Ingress, no ingress rules) selects every pod.
# Usage: 50-security.sh <cluster>   (KUBECONFIG points at the cluster)
set -uo pipefail

cluster="$1"
NS=demo

if ! pods="$(kubectl -n "$NS" get pods -o json 2>&1)"; then
  echo "FAIL security $cluster pods ($(head -n 1 <<< "$pods"))"
  exit 0
fi
if ! pols="$(kubectl -n "$NS" get networkpolicies -o json 2>&1)"; then
  echo "FAIL security $cluster networkpolicies ($(head -n 1 <<< "$pols"))"
  exit 0
fi

bad="$(jq -r --slurpfile pols <(cat <<< "$pols") '
  [$pols[0].items[]
    | select((.spec.policyTypes // []) | index("Ingress"))
    | select((.spec.ingress // []) | length == 0)
    | select((.spec.podSelector.matchExpressions // []) | length == 0)] as $deny
  | if (.items | length) == 0 then "no pods in namespace demo"
    else
      ([.items[] | . as $p
         | ((.spec.containers // []) + (.spec.initContainers // []) + (.spec.ephemeralContainers // []))[]
         | select(.securityContext.privileged == true)
         | "pod/\($p.metadata.name) container \(.name) is privileged"]
       + (if ($deny | length) == 0 then ["no default-deny ingress NetworkPolicy"]
          else [.items[] | . as $p
                 | select([$deny[] | (.spec.podSelector.matchLabels // {}) | to_entries
                           | all(. as $e | ($p.metadata.labels // {})[$e.key] == $e.value)] | any | not)
                 | "pod/\($p.metadata.name) not covered by a default-deny NetworkPolicy"]
          end))
      | join("; ")
    end' <<< "$pods")"

if [ -n "$bad" ]; then
  echo "FAIL security $cluster $bad"
else
  echo "PASS security $cluster (no privileged pods; default-deny ingress covers all $(jq '.items | length' <<< "$pods") pods)"
fi
