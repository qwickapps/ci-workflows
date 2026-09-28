#!/usr/bin/env bash
set -euo pipefail

# Remove specific env var keys from a live CapRover app, surgically.
# Canonical source: qwickapps/ci-workflows scripts/caprover-remove-env-keys.sh
#
# Unlike configure-caprover-app.sh (which only MERGES canonical vars in and
# never removes stray/unlisted keys — see that script's header), this tool
# exists specifically to delete dead env var references that a normal
# pipeline deploy will never clean up. It touches ONLY the named keys; every
# other envVar, plus instanceCount/port/SSL/CMD, is preserved byte-for-byte.
#
# Usage:
#   caprover-remove-env-keys.sh \
#     --app-name APP --keys KEY1,KEY2 \
#     --caprover-url URL --caprover-password PASS \
#     [--dry-run true|false]   (default true — report only, no changes)
#
# dry-run output: for each requested key, whether it is currently present
# (and would be removed) or already absent (no-op).
#
# Apply mode (--dry-run false): does a single atomic envVars replace
# (existing envVars minus the requested keys), then re-fetches and verifies
# every requested key is gone. Exits non-zero if any requested key survives
# the update (CapRover silently ignoring/rejecting the write).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/caprover-api.sh
source "${SCRIPT_DIR}/lib/caprover-api.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  caprover-remove-env-keys.sh --app-name APP --keys KEY1,KEY2 \
    --caprover-url URL --caprover-password PASS [--dry-run true|false]
EOF
}

APP_NAME=""
KEYS_CSV=""
CAPROVER_URL=""
CAPROVER_PASSWORD=""
DRY_RUN="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)          APP_NAME="$2";          shift 2 ;;
    --keys)               KEYS_CSV="$2";          shift 2 ;;
    --caprover-url)       CAPROVER_URL="$2";      shift 2 ;;
    --caprover-password)  CAPROVER_PASSWORD="$2"; shift 2 ;;
    --dry-run)            DRY_RUN="$2";           shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$APP_NAME" || -z "$KEYS_CSV" || -z "$CAPROVER_URL" || -z "$CAPROVER_PASSWORD" ]]; then
  usage
  exit 1
fi

IFS=',' read -ra KEYS_ARR <<< "$KEYS_CSV"
KEYS_JSON="$(printf '%s\n' "${KEYS_ARR[@]}" | jq -R . | jq -s .)"

echo "========================================="
echo "CapRover Remove Env Keys"
echo "  app:      $APP_NAME"
echo "  keys:     $KEYS_CSV"
echo "  dry-run:  $DRY_RUN"
echo "========================================="

echo ""
echo "Authenticating with CapRover..."
TOKEN="$(caprover_login "$CAPROVER_URL" "$CAPROVER_PASSWORD")"
echo "  Authenticated"

CURL_ARGS=()
caprover_populate_curl_args "$CAPROVER_URL" CURL_ARGS

echo ""
echo "Fetching current app definition..."
ALL_DEFS=$(curl "${CURL_ARGS[@]}" -X GET "$CAPROVER_URL/api/v2/user/apps/appDefinitions" \
  -H "x-captain-auth: $TOKEN")
CURRENT_DEF=$(echo "$ALL_DEFS" | jq --arg name "$APP_NAME" '.data.appDefinitions[] | select(.appName == $name)')

if [ -z "$CURRENT_DEF" ] || [ "$CURRENT_DEF" = "null" ]; then
  echo "Error: app ${APP_NAME} was not found on ${CAPROVER_URL}" >&2
  exit 1
fi

EXISTING_ENV=$(echo "$CURRENT_DEF" | jq '.envVars // []')
EXISTING_COUNT=$(echo "$EXISTING_ENV" | jq 'length')

echo ""
echo "Current key presence:"
PRESENT_KEYS_JSON=$(echo "$EXISTING_ENV" | jq --argjson keys "$KEYS_JSON" \
  '[.[] | select(.key as $k | $keys | any(. == $k)) | .key]')
for key in "${KEYS_ARR[@]}"; do
  if echo "$PRESENT_KEYS_JSON" | jq -e --arg k "$key" 'any(. == $k)' >/dev/null 2>&1; then
    echo "  PRESENT: $key (would be removed)"
  else
    echo "  ABSENT:  $key (no-op)"
  fi
done

PRESENT_COUNT=$(echo "$PRESENT_KEYS_JSON" | jq 'length')
if [ "$PRESENT_COUNT" -eq 0 ]; then
  echo ""
  echo "No requested keys are present — nothing to do."
  exit 0
fi

if [ "$DRY_RUN" = "true" ]; then
  echo ""
  echo "Dry-run complete — no changes applied. Re-run with --dry-run false to apply."
  exit 0
fi

FILTERED_ENV=$(echo "$EXISTING_ENV" | jq --argjson keys "$KEYS_JSON" \
  '[.[] | select(.key as $k | ($keys | any(. == $k)) | not)]')
FILTERED_COUNT=$(echo "$FILTERED_ENV" | jq 'length')

MERGED=$(echo "$CURRENT_DEF" | jq --argjson env "$FILTERED_ENV" '.envVars = $env')

echo ""
echo "Applying atomic update (envVars: ${EXISTING_COUNT} -> ${FILTERED_COUNT})..."
UPDATE_RESPONSE=$(caprover_api_call "Remove env keys from ${APP_NAME}" \
  curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/update" \
  -H "Content-Type: application/json" \
  -H "x-captain-auth: $TOKEN" \
  -d "$MERGED")

UPDATE_STATUS=$(echo "$UPDATE_RESPONSE" | jq -r '.status')
if [ "$UPDATE_STATUS" != "100" ] && [ "$UPDATE_STATUS" != "1000" ]; then
  echo "Error: unexpected update response (status: $UPDATE_STATUS): $(echo "$UPDATE_RESPONSE" | jq -r '.description')" >&2
  exit 1
fi
echo "  Update applied (status: $UPDATE_STATUS)"

echo ""
echo "Verifying requested keys are gone..."
VERIFY_DEFS=$(curl "${CURL_ARGS[@]}" -X GET "$CAPROVER_URL/api/v2/user/apps/appDefinitions" \
  -H "x-captain-auth: $TOKEN")
VERIFY_DEF=$(echo "$VERIFY_DEFS" | jq --arg name "$APP_NAME" '.data.appDefinitions[] | select(.appName == $name)')
VERIFY_ENV=$(echo "$VERIFY_DEF" | jq '.envVars // []')

VERIFY_FAILED=0
for key in "${KEYS_ARR[@]}"; do
  if echo "$VERIFY_ENV" | jq -e --arg k "$key" 'any(.key == $k)' >/dev/null 2>&1; then
    echo "  FAIL: $key — still present in CapRover after update"
    VERIFY_FAILED=1
  else
    echo "  OK: $key — confirmed removed"
  fi
done

if [ "$VERIFY_FAILED" -ne 0 ]; then
  echo "Error: env key removal verification failed — CapRover state does not match request." >&2
  exit 1
fi

echo ""
echo "All requested keys removed and verified on ${APP_NAME}."
