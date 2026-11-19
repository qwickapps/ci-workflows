#!/usr/bin/env bash
#
# Regression test for the infra#101 LB guard's TS_API_KEY resolution in
# .github/workflows/deploy-app.yml.
#
# Both call sites of verify-ts-lb-target.sh (in the deploy-caprover and
# deploy-stable jobs) passed `--ts-api-key "${{ secrets.TS_API_KEY }}"`
# directly, with no fallback. When that GH Actions secret goes stale (the
# secrets-service master copy can be corrected without GH secret
# propagation catching up, or propagation itself can lag on self-hosted
# runners after a rotation), stage=live silently loses its LB-freshness
# guard with no fallback path — the same class of staleness problem
# mcp#333/ci-workflows#122 fixed for :release-candidate, applied to a
# credential instead of an image tag.
#
# mcp's own deploy.yml already has a proven fallback for exactly this
# ("TS_API_KEY fallback: fetch from secrets service if GitHub secret is a
# placeholder", using SECRETS_SERVICE_KEY against the secrets service's
# GET /v1/secrets/<project>/<env>/<key> endpoint with an x-service-key
# header). This fix ports that same pattern into deploy-app.yml so every
# consumer gets it once, instead of repeating it per repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/deploy-app.yml"

pass=0
fail=0
assert() {
  local desc="$1"; shift
  if "$@"; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc"
    fail=$((fail + 1))
  fi
}

echo "== deploy-app.yml: live-state credentials resolve through the correct sources =="

assert "workflow file exists" \
  test -f "$WORKFLOW"

CALL_SITE_COUNT=$(grep -c -- '--ts-api-key "\$TS_API_KEY_RESOLVED"' "$WORKFLOW" || true)
assert "all four live-state checks use the resolved (fallback-aware) key, never the raw secret" \
  test "$CALL_SITE_COUNT" -eq 4

RAW_SECRET_COUNT=$(grep -c -- '--ts-api-key "\${{ secrets.TS_API_KEY }}"' "$WORKFLOW" || true)
assert "no call site still passes the raw GH secret directly (bypassing the fallback)" \
  test "$RAW_SECRET_COUNT" -eq 0

FALLBACK_BLOCK_COUNT=$(grep -c 'TS_API_KEY_RESOLVED="\${TS_API_KEY:-}"' "$WORKFLOW" || true)
assert "fallback resolution block present at all four live-state checks" \
  test "$FALLBACK_BLOCK_COUNT" -eq 4

PLACEHOLDER_CHECK_COUNT=$(grep -c 'if \[ "\$TS_API_KEY_RESOLVED" = "-" \] || \[ -z "\$TS_API_KEY_RESOLVED" \]; then' "$WORKFLOW" || true)
assert "'-' placeholder handling present at all four live-state checks (matches mcp's TS_AUTHKEY/TS_API_KEY convention)" \
  test "$PLACEHOLDER_CHECK_COUNT" -eq 4

# The base URL and path are built via variable interpolation
# (_SEC_URL="..." then "${_SEC_URL}/v1/secrets/...") rather than one literal
# string, so check both parts independently.
SECRETS_URL_COUNT=$(grep -c '_SEC_URL="http://qwickapps-secrets-live.taile324e7.ts.net:7007"' "$WORKFLOW" || true)
assert "uses the canonical secrets-service host in four Tailscale plus two Coolify fallback blocks" \
  test "$SECRETS_URL_COUNT" -eq 6

SECRETS_PATH_COUNT=$(grep -c '\${_SEC_URL}/v1/secrets/infrastructure/tailscale/TS_API_KEY' "$WORKFLOW" || true)
assert "fetches the same secrets-service path mcp's deploy.yml uses for TS_API_KEY at all four checks" \
  test "$SECRETS_PATH_COUNT" -eq 4

SERVICE_KEY_ENV_COUNT=$(grep -c 'SECRETS_SERVICE_KEY: \${{ secrets.SECRETS_SERVICE_KEY }}' "$WORKFLOW" || true)
assert "SECRETS_SERVICE_KEY threaded into all four live-state-check step environments" \
  test "$SERVICE_KEY_ENV_COUNT" -eq 4

COOLIFY_SECRET_COUNT=$(grep -c 'COOLIFY_TOKEN: \${{ secrets.COOLIFY_MOMO_DEPLOY_TOKEN }}' "$WORKFLOW" || true)
assert "the live momo scoped deploy token is threaded into both Coolify checks" \
  test "$COOLIFY_SECRET_COUNT" -eq 2

COOLIFY_PATH_COUNT=$(grep -c '\${_SEC_URL}/v1/secrets/infrastructure/caprover/COOLIFY_MOMO_DEPLOY_TOKEN' "$WORKFLOW" || true)
assert "Coolify fallback reads the live scoped momo deploy token, not unprovisioned/stale aliases" \
  test "$COOLIFY_PATH_COUNT" -eq 2

COOLIFY_BAD_ALIAS_COUNT=$(grep -c 'secrets.COOLIFY_API_TOKEN\|/coolify/COOLIFY_API_TOKEN' "$WORKFLOW" || true)
assert "no unprovisioned COOLIFY_API_TOKEN secret reference or fallback path remains" \
  test "$COOLIFY_BAD_ALIAS_COUNT" -eq 0

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
