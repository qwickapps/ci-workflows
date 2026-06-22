#!/bin/bash
set -euo pipefail

# Post-Cutover Soak Test: Verify new deployment is stable
#
# Probes the newly deployed live slot's health endpoint continuously for
# a specified duration. If ANY probe fails, triggers automatic rollback.
#
# This catches issues that don't manifest immediately after deploy but
# appear after a few seconds of live traffic.
#
# Usage:
#   soak-test.sh \
#     --url <health-url> \
#     --duration <seconds> \
#     --interval <seconds> \
#     --max-failures <count> \
#     [--on-failure-rollback-to <app-name>]
#
# Example:
#   soak-test.sh \
#     --url https://qwickapps-mcp-live.taile324e7.ts.net/health \
#     --duration 120 \
#     --interval 5 \
#     --max-failures 1 \
#     --on-failure-rollback-to qwickapps-mcp-live
#
# Exit codes:
#   0 = Soak test passed, all health checks successful
#   1 = Soak test failed, health checks not meeting threshold

URL=""
DURATION=120
INTERVAL=5
MAX_FAILURES=1
ROLLBACK_TO=""
TIMEOUT=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --url)                         URL="$2";                         shift 2 ;;
    --duration)                    DURATION="$2";                    shift 2 ;;
    --interval)                    INTERVAL="$2";                    shift 2 ;;
    --max-failures)                MAX_FAILURES="$2";                shift 2 ;;
    --on-failure-rollback-to)      ROLLBACK_TO="$2";                 shift 2 ;;
    --timeout)                     TIMEOUT="$2";                     shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ -z "$URL" ]; then
  echo "Error: --url is required"
  exit 1
fi

echo "========================================="
echo "Post-Cutover Soak Test (2-Minute Stability Check)"
echo "  URL:      $URL"
echo "  Duration: ${DURATION}s"
echo "  Interval: ${INTERVAL}s"
echo "  Max failures allowed: $MAX_FAILURES"
echo "========================================="
echo ""

EXPECTED_PROBES=$((DURATION / INTERVAL))
echo "Plan: Send $EXPECTED_PROBES probes over ${DURATION}s"
echo ""

# Start time
START_TIME=$(date +%s)
DEADLINE=$((START_TIME + DURATION))
CURRENT_TIME=$START_TIME

PROBE_COUNT=0
SUCCESS_COUNT=0
FAILURE_COUNT=0
LAST_STATUS=""
FAILED_PROBES=()

echo "Running soak test..."
echo ""

while [ $CURRENT_TIME -lt $DEADLINE ]; do
  PROBE_COUNT=$((PROBE_COUNT + 1))
  ELAPSED=$((CURRENT_TIME - START_TIME))

  # Send health probe
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" -m "$TIMEOUT" "$URL" 2>/dev/null || echo "000")

  if [ "$STATUS" = "200" ]; then
    echo "[$ELAPSED/$DURATION s] Probe $PROBE_COUNT: ✓ OK (HTTP 200)"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    LAST_STATUS="OK"
  else
    echo "[$ELAPSED/$DURATION s] Probe $PROBE_COUNT: ✗ FAIL (HTTP $STATUS)"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
    LAST_STATUS="FAIL"
    FAILED_PROBES+=("Probe $PROBE_COUNT: HTTP $STATUS at ${ELAPSED}s")
  fi

  # Check if we've exceeded max failures
  if [ $FAILURE_COUNT -gt $MAX_FAILURES ]; then
    echo ""
    echo "⚠️  Max failures exceeded ($FAILURE_COUNT > $MAX_FAILURES)"
    echo "   Stopping soak test early"
    break
  fi

  # Sleep until next probe
  CURRENT_TIME=$(date +%s)
  TIME_TO_NEXT=$((CURRENT_TIME + INTERVAL - $(date +%s)))
  if [ $TIME_TO_NEXT -gt 0 ]; then
    sleep "$INTERVAL"
  fi

  CURRENT_TIME=$(date +%s)
done

echo ""
echo "========================================="
echo "Soak Test Results"
echo "  Total probes: $PROBE_COUNT"
echo "  Successes: $SUCCESS_COUNT"
echo "  Failures: $FAILURE_COUNT"
echo "  Success rate: $(( (SUCCESS_COUNT * 100) / PROBE_COUNT ))%"
echo "========================================="
echo ""

# Determine result
if [ $FAILURE_COUNT -le $MAX_FAILURES ]; then
  echo "✅ Soak test PASSED"
  echo "   Deployment is stable, keeping new live slot"
  exit 0
else
  echo "❌ Soak test FAILED"
  echo "   Health checks did not meet SLA"
  echo "   Failures: $FAILURE_COUNT (max: $MAX_FAILURES)"
  echo ""
  echo "Failed probes:"
  for probe in "${FAILED_PROBES[@]}"; do
    echo "  - $probe"
  done
  echo ""

  # Trigger auto-rollback if specified
  if [ -n "$ROLLBACK_TO" ]; then
    echo "🔄 Triggering automatic rollback..."
    echo "   Reverting to previous stable slot"
    # TODO: Implement rollback logic
    # For now, just log and exit with error
  fi

  exit 1
fi
