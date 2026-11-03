#!/usr/bin/env bash
# Apply branch protection on main and the test/prod/release GitHub Environments with required reviewers.
# Usage: scripts/protect-branch.sh [--dry-run] --repo owner/name --reviewers login[,login...]
#          [--branch main] [--approvals N] [--enforce-admins] [--no-protect-tags]
#   --dry-run        print the exact gh api calls and execute nothing (--repo defaults to astawiany/fleet-in-a-repo)
#   --repo           required for a real run; there is no default and it never runs implicitly
#   --reviewers      comma-separated GitHub logins for the environments (or env PROTECT_REVIEWERS)
#   --approvals N    approving PR reviews required on the branch, 0-6 (default 1). With 1 or more,
#                    code-owner review is required too. A solo owner cannot approve their own PR:
#                    use 0 (the status checks still gate merges); see .github/README.md.
#   --enforce-admins apply the rules to admins as well (default off, so an owner is never locked out)
#   --no-protect-tags skip the tag ruleset "release-tags". By default it is created (or updated): only
#                    repository admins may create, move or delete chart-v* tags. That ruleset is what
#                    makes a release signature trustworthy (any chart-v* tag runs the release.yml of its
#                    own commit), so opt out only on a repository that never publishes.
# Required status checks are the job ids of .github/workflows/validate.yml, except the jobs in
# OPTIONAL_JOBS (they depend on external vulnerability databases and must not block merges).
# The release Environment only accepts deployments from chart-v* tags.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dry=0
repo=""
branch=main
approvals=1
enforce_admins=false
protect_tags=1
OPTIONAL_JOBS="security"
reviewers="${PROTECT_REVIEWERS:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --repo) [ $# -ge 2 ] || { echo "protect-branch: --repo needs owner/name" >&2; exit 2; }; repo="$2"; shift 2 ;;
    --reviewers) [ $# -ge 2 ] || { echo "protect-branch: --reviewers needs a value" >&2; exit 2; }; reviewers="$2"; shift 2 ;;
    --branch) [ $# -ge 2 ] || { echo "protect-branch: --branch needs a value" >&2; exit 2; }; branch="$2"; shift 2 ;;
    --approvals) [ $# -ge 2 ] || { echo "protect-branch: --approvals needs a number" >&2; exit 2; }; approvals="$2"; shift 2 ;;
    --enforce-admins) enforce_admins=true; shift ;;
    --no-protect-tags) protect_tags=0; shift ;;
    *) echo "protect-branch: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ -z "$repo" ]; then
  if [ "$dry" -eq 1 ]; then
    repo="astawiany/fleet-in-a-repo"
  else
    echo "protect-branch: --repo owner/name is required (use --dry-run to preview)" >&2
    exit 2
  fi
fi
[[ "$approvals" =~ ^[0-6]$ ]] || { echo "protect-branch: --approvals must be a number from 0 to 6 (got '$approvals')" >&2; exit 2; }
if [ "$approvals" -ge 1 ]; then code_owners=true; else code_owners=false; fi
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "protect-branch: --repo must look like owner/name" >&2; exit 2; }
[ -n "$reviewers" ] || { echo "protect-branch: reviewers are required (--reviewers a,b or PROTECT_REVIEWERS)" >&2; exit 2; }
command -v yq > /dev/null 2>&1 || { echo "protect-branch: yq not found on PATH" >&2; exit 2; }

# All argument validation and read-only lookups happen before the first write.
IFS=',' read -r -a raw_logins <<< "$reviewers"
logins=()
for l in ${raw_logins[@]+"${raw_logins[@]}"}; do
  l="${l//[[:space:]]/}"
  [ -n "$l" ] || continue
  logins+=("$l")
done
if [ "${#logins[@]}" -eq 0 ]; then
  echo "protect-branch: no valid reviewers given (empty or blank entries only)" >&2
  exit 2
fi
entries=""
for l in "${logins[@]}"; do
  if [ "$dry" -eq 1 ]; then
    id="\"<id of $l: gh api users/$l --jq .id>\""
  else
    id="$(gh api "users/$l" --jq .id)"
  fi
  entries="${entries:+$entries, }{ \"type\": \"User\", \"id\": $id }"
done

# shellcheck disable=SC2016 # $opt and $j are yq variables
checks_json="$(OPTIONAL="$OPTIONAL_JOBS" yq -o=json -I=0 \
  '(strenv(OPTIONAL) | split(" ")) as $opt | [.jobs | keys | .[] | select(. as $j | $opt | contains([$j]) | not)]' \
  "$ROOT/.github/workflows/validate.yml")"
protection="$(cat << JSON
{
  "required_status_checks": { "strict": true, "contexts": $checks_json },
  "enforce_admins": $enforce_admins,
  "required_pull_request_reviews": { "required_approving_review_count": $approvals, "require_code_owner_reviews": $code_owners, "dismiss_stale_reviews": true },
  "restrictions": null
}
JSON
)"

# RepositoryRole 5 is the built-in admin role: only admins can create, move or delete chart-v* tags.
ruleset='{
  "name": "release-tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/chart-v*"], "exclude": [] } },
  "rules": [ { "type": "creation" }, { "type": "update" }, { "type": "deletion" } ],
  "bypass_actors": [ { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" } ]
}'

# Read-only lookups that make re-runs idempotent (before the first run they find nothing).
tag_policy_id=""
ruleset_id=""
if [ "$dry" -eq 0 ]; then
  tag_policy_id="$(gh api "repos/$repo/environments/release/deployment-branch-policies" \
    --jq '.branch_policies[] | select(.type == "tag" and .name == "chart-v*") | .id' 2> /dev/null || true)"
  if [ "$protect_tags" -eq 1 ]; then
    ruleset_id="$(gh api "repos/$repo/rulesets" --jq '.[] | select(.name == "release-tags") | .id')"
  fi
fi

# run_gh <stdin-body|-> args...: print the call; execute only outside dry-run.
call() { # body, then gh api args
  local body="$1"; shift
  if [ "$dry" -eq 1 ]; then
    echo "gh api $* --input - <<'JSON'"
    echo "$body"
    echo "JSON"
  else
    echo "$body" | gh api "$@" --input -
  fi
}

if [ "$dry" -eq 1 ]; then echo "# dry run: nothing is executed"; fi
call "$protection" --method PUT "repos/$repo/branches/$branch/protection"

for env in test prod; do
  call "{ \"reviewers\": [ $entries ], \"deployment_branch_policy\": null }" --method PUT "repos/$repo/environments/$env"
done

# release: same reviewers; deployments only from refs matching the chart-v* tag policy.
call "{ \"reviewers\": [ $entries ], \"deployment_branch_policy\": { \"protected_branches\": false, \"custom_branch_policies\": true } }" \
  --method PUT "repos/$repo/environments/release"
if [ -z "$tag_policy_id" ]; then
  call '{ "name": "chart-v*", "type": "tag" }' --method POST "repos/$repo/environments/release/deployment-branch-policies"
fi

if [ "$protect_tags" -eq 0 ]; then
  echo "protect-branch: WARNING: --no-protect-tags: anyone with write access can push a chart-v* tag and get a release signature that matches docs/security.md" >&2
fi
if [ "$protect_tags" -eq 1 ]; then
  if [ "$dry" -eq 1 ]; then
    echo "# release-tags: POST creates it; a re-run updates the existing ruleset with PUT repos/$repo/rulesets/<id>"
  fi
  if [ -n "$ruleset_id" ]; then
    call "$ruleset" --method PUT "repos/$repo/rulesets/$ruleset_id"
  else
    call "$ruleset" --method POST "repos/$repo/rulesets"
  fi
fi
