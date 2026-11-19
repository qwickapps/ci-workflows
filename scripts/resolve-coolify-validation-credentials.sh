#!/usr/bin/env bash
# Resolve fail-closed credentials for Momo validation deployments.
# Only the scoped infrastructure/caprover/COOLIFY_MOMO_DEPLOY_TOKEN source is
# accepted; stale generic Coolify aliases are intentionally unsupported.
set -euo pipefail

: "${GITHUB_ENV:?GITHUB_ENV is required}"
COOLIFY_MOMO_DEPLOY_TOKEN="${COOLIFY_MOMO_DEPLOY_TOKEN:-}"
TS_RESOLVED="${TS_API_KEY:-}"

fetch_secret() {
  local path="$1"
  [ -n "${SECRETS_SERVICE_KEY:-}" ] || return 1
  local response
  response="$(curl -fsS --max-time 10 \
    "http://qwickapps-secrets-live.taile324e7.ts.net:7007/v1/secrets/${path}" \
    -H "x-service-key: ${SECRETS_SERVICE_KEY}")" || return 1
  printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("value", ""))'
}

if [ -z "$COOLIFY_MOMO_DEPLOY_TOKEN" ] || [ "$COOLIFY_MOMO_DEPLOY_TOKEN" = "-" ]; then
  COOLIFY_MOMO_DEPLOY_TOKEN="$(fetch_secret infrastructure/caprover/COOLIFY_MOMO_DEPLOY_TOKEN || true)"
fi
if [ -z "$TS_RESOLVED" ] || [ "$TS_RESOLVED" = "-" ]; then
  TS_RESOLVED="$(fetch_secret infrastructure/tailscale/TS_API_KEY || true)"
fi

if [ -z "$COOLIFY_MOMO_DEPLOY_TOKEN" ] || [ "$COOLIFY_MOMO_DEPLOY_TOKEN" = "-" ]; then
  echo "::error::scoped COOLIFY_MOMO_DEPLOY_TOKEN could not be resolved; refusing secondary deployment"
  exit 1
fi
if [ -z "$TS_RESOLVED" ] || [ "$TS_RESOLVED" = "-" ]; then
  echo "::error::TS_API_KEY could not be resolved; topology verification cannot be skipped"
  exit 1
fi

echo "::add-mask::$COOLIFY_MOMO_DEPLOY_TOKEN"
echo "::add-mask::$TS_RESOLVED"
{
  echo "COOLIFY_MOMO_DEPLOY_TOKEN=$COOLIFY_MOMO_DEPLOY_TOKEN"
  echo "TS_API_KEY_RESOLVED=$TS_RESOLVED"
} >> "$GITHUB_ENV"
