#!/usr/bin/env bash
# Mint a GitHub App installation token with openssl + curl (no third-party action).
# Env: APP_ID, APP_PRIVATE_KEY (PEM), REPO (owner/name). Prints the token on stdout.
# Used by promote.yml only when the repository variable USE_APP_TOKEN is 'true'.
set -euo pipefail

: "${APP_ID:?APP_ID is required}" "${APP_PRIVATE_KEY:?APP_PRIVATE_KEY is required}" "${REPO:?REPO is required}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

now="$(date +%s)"
header="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
payload="$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)"
key="$(mktemp)"
trap 'rm -f "$key"' EXIT
printf '%s\n' "$APP_PRIVATE_KEY" > "$key"
sig="$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key" | b64url)"
jwt="$header.$payload.$sig"

api="${GITHUB_API_URL:-https://api.github.com}"
auth=(-H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json")
command -v yq > /dev/null 2>&1 || { echo "app-token: yq not found on PATH" >&2; exit 1; }
inst="$(curl -fsSL "${auth[@]}" "$api/repos/$REPO/installation" | yq -p=json -r '.id // ""')"
[ -n "$inst" ] || { echo "app-token: could not find an installation for $REPO" >&2; exit 1; }
token="$(curl -fsSL -X POST "${auth[@]}" "$api/app/installations/$inst/access_tokens" | yq -p=json -r '.token // ""')"
[ -n "$token" ] || { echo "app-token: GitHub returned no installation token" >&2; exit 1; }
printf '%s\n' "$token"
