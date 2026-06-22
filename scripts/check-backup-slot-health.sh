#!/bin/bash
set -euo pipefail

# Pre-deploy Safety Gate: Verify backup slot is healthy
#
# CRITICAL: Refuses to start deployment if the backup slot (stable/fallback)
# is unhealthy. This prevents cascading failures where a broken live slot
# and broken backup slot both fail, leaving service completely unavailable.
#
# Usage:
#   check-backup-slot-health.sh \
#     --app-name <name> \
#     --stage <build|uat|live> \
#     --caprover-url <url> \
#     --caprover-password <password> \
#     [--max-attempts 5] \
#     [--timeout 10]
#
# Exit codes:
#   0 = Backup slot is healthy, safe to proceed with deploy
#   1 = Backup slot is unhealthy, REFUSE deploy
#   2 = Unable to check backup slot (network error), REFUSE as safety measure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/caprover-api.sh
source "${SCRIPT_DIR}/lib/caprover-api.sh"

APP_NAME=""
STAGE=""
CAPROVER_URL=""
CAPROVER_PASSWORD=""
MAX_ATTEMPTS=5
TIMEOUT=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --app-name)          APP_NAME="$2";          shift 2 ;;
    --stage)             STAGE="$2";             shift 2 ;;
    --caprover-url)      CAPROVER_URL="$2";      shift 2 ;;
    --caprover-password) CAPROVER_PASSWORD="$2"; shift 2 ;;
    --max-attempts)      MAX_ATTEMPTS="$2";      shift 2 ;;
    --timeout)           TIMEOUT="$2";           shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ -z "$APP_NAME" ] || [ -z "$STAGE" ] || [ -z "$CAPROVER_URL" ] || [ -z "$CAPROVER_PASSWORD" ]; then
  echo "Error: --app-name, --stage, --caprover-url, and --caprover-password are required"
  exit 2
fi

echo "========================================="
echo "Pre-Deploy Safety Gate: Backup Slot Health Check"
echo "  app:   $APP_NAME"
echo "  stage: $STAGE"
echo "========================================="
echo ""

# Map stage to backup slot name
# Stage-specific mapping:
#   build → backup slot is not critical (skip check)
#   uat → uat-stable is the backup
#   live → live-stable is the backup
case "$STAGE" in
  build)
    echo "Build stage: backup slot check not critical (skip)"
    exit 0
    ;;
  uat)
    BACKUP_SLOT="${APP_NAME}-stable"
    ;;
  live)
    BACKUP_SLOT="${APP_NAME}-stable"
    ;;
  *)
    echo "ERROR: Unknown stage '$STAGE'"
    exit 2
    ;;
esac

echo "Verifying backup slot is healthy..."
echo "  Backup slot: $BACKUP_SLOT"
echo ""

# Authenticate with CapRover
TOKEN=$(caprover_login "$CAPROVER_URL" "$CAPROVER_PASSWORD" 2>/dev/null || echo "")
if [ -z "$TOKEN" ]; then
  echo "ERROR: Could not authenticate with CapRover"
  echo "⚠️  Unable to verify backup slot health — refusing deploy as safety measure"
  exit 2
fi

CURL_ARGS=()
caprover_populate_curl_args "$CAPROVER_URL" CURL_ARGS

# Fetch backup slot health
BACKUP_DEF=$(curl "${CURL_ARGS[@]}" -s -X GET "$CAPROVER_URL/api/v2/user/apps/appData/$BACKUP_SLOT" \
  -H "x-captain-auth: $TOKEN" 2>/dev/null || echo "{}")

if [ -z "$BACKUP_DEF" ] || [ "$BACKUP_DEF" = "{}" ]; then
  echo "ERROR: Could not fetch backup slot definition"
  echo "⚠️  Unable to verify backup slot health — refusing deploy as safety measure"
  exit 2
fi

# Check if backup slot is running
IS_RUNNING=$(echo "$BACKUP_DEF" | jq -r '.data.appDefinition.isAppBuilding // false')
if [ "$IS_RUNNING" = "true" ]; then
  echo "⚠️  Backup slot is currently building/deploying"
  echo "    Waiting for build to complete..."
fi

# Probe health endpoint
HEALTH_ENDPOINT=$(echo "$BACKUP_DEF" | jq -r '.data.appDefinition.customDomain // .data.appDefinition.appName' 2>/dev/null || echo "")
if [ -z "$HEALTH_ENDPOINT" ]; then
  # Try default Tailscale hostname
  HEALTH_ENDPOINT="${BACKUP_SLOT}.taile324e7.ts.net"
fi

HEALTH_URL="https://${HEALTH_ENDPOINT}/health"
echo "Probing health endpoint: $HEALTH_URL"
echo ""

ATTEMPT=1
while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
  echo "Attempt $ATTEMPT/$MAX_ATTEMPTS..."
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -m "$TIMEOUT" "$HEALTH_URL" 2>/dev/null || echo "000")

  if [ "$STATUS" = "200" ]; then
    echo "  ✅ Backup slot is HEALTHY (HTTP 200)"
    echo ""
    echo "========================================="
    echo "✅ Safety gate PASSED: Backup slot is healthy"
    echo "   Safe to proceed with deployment"
    echo "========================================="
    exit 0
  else
    echo "  ✗ Backup slot returned HTTP $STATUS (expected 200)"
  fi

  if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
    sleep 2
  fi

  ATTEMPT=$((ATTEMPT + 1))
done

# All attempts failed
echo ""
echo "========================================="
echo "❌ Safety gate FAILED: Backup slot is UNHEALTHY"
echo "   After $MAX_ATTEMPTS attempts, health check failing"
echo "   Status: HTTP $STATUS (expected 200)"
echo ""
echo "⚠️  REFUSING DEPLOYMENT — Cannot deploy when backup slot is unhealthy"
echo "   This protects against cascading failures."
echo ""
echo "Recovery:"
echo "  1. Investigate backup slot health: $HEALTH_URL"
echo "  2. Fix backup slot deployment"
echo "  3. Retry deploy after backup slot recovers"
echo "========================================="
exit 1
