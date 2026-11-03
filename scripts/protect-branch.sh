#!/usr/bin/env bash
# Apply branch protection on main and the test/prod GitHub Environments with required reviewers.
# Usage: scripts/protect-branch.sh [--dry-run] --repo owner/name --reviewers login[,login...] [--branch main]
#   --dry-run   print the exact gh api calls and execute nothing (--repo defaults to OWNER/REPO)
#   --repo      required for a real run; there is no default and it never runs implicitly
#   --reviewers comma-separated GitHub logins for the environments (or env PROTECT_REVIEWERS)
# Required status checks are the job ids of .github/workflows/validate.yml.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dry=0
repo=""
branch=main
reviewers="${PROTECT_REVIEWERS:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --repo) [ $# -ge 2 ] || { echo "protect-branch: --repo needs owner/name" >&2; exit 2; }; repo="$2"; shift 2 ;;
    --reviewers) [ $# -ge 2 ] || { echo "protect-branch: --reviewers needs a value" >&2; exit 2; }; reviewers="$2"; shift 2 ;;
    --branch) [ $# -ge 2 ] || { echo "protect-branch: --branch needs a value" >&2; exit 2; }; branch="$2"; shift 2 ;;
    *) echo "protect-branch: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ -z "$repo" ]; then
  if [ "$dry" -eq 1 ]; then
    repo="OWNER/REPO"
  else
    echo "protect-branch: --repo owner/name is required (use --dry-run to preview)" >&2
    exit 2
  fi
fi
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

checks_json="$(yq -o=json -I=0 '[.jobs | keys | .[]]' "$ROOT/.github/workflows/validate.yml")"
protection="$(cat << JSON
{
  "required_status_checks": { "strict": true, "contexts": $checks_json },
  "enforce_admins": true,
  "required_pull_request_reviews": { "required_approving_review_count": 1, "require_code_owner_reviews": true, "dismiss_stale_reviews": true },
  "restrictions": null
}
JSON
)"

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
