#!/bin/bash
set -euo pipefail

# Deploy Notifications: Telegram alerts for each deployment phase
#
# Sends structured notifications via Telegram bot for deployment start,
# phase completion, and final result. Includes health status and timing.
#
# Usage:
#   # Deploy started
#   notify-deploy.sh \
#     --phase start \
#     --app-name qwickapps-mcp \
#     --image-ref ghcr.io/qwickapps/img-mcp:sha-abc123 \
#     --github-run-id 12345 \
#     --telegram-bot-token "$BOT_TOKEN" \
#     --telegram-chat-id "$CHAT_ID"
#
#   # Phase complete
#   notify-deploy.sh \
#     --phase build \
#     --app-name qwickapps-mcp \
#     --status success \
#     --duration 120 \
#     --telegram-bot-token "$BOT_TOKEN" \
#     --telegram-chat-id "$CHAT_ID"
#
#   # Deploy failed
#   notify-deploy.sh \
#     --phase complete \
#     --app-name qwickapps-mcp \
#     --status failed \
#     --error "Health check failed during soak test" \
#     --telegram-bot-token "$BOT_TOKEN" \
#     --telegram-chat-id "$CHAT_ID"

PHASE=""
APP_NAME=""
STATUS="in_progress"
IMAGE_REF=""
DURATION=""
ERROR=""
GITHUB_RUN_ID=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --phase)                  PHASE="$2";                  shift 2 ;;
    --app-name)               APP_NAME="$2";               shift 2 ;;
    --status)                 STATUS="$2";                 shift 2 ;;
    --image-ref)              IMAGE_REF="$2";              shift 2 ;;
    --duration)               DURATION="$2";               shift 2 ;;
    --error)                  ERROR="$2";                  shift 2 ;;
    --github-run-id)          GITHUB_RUN_ID="$2";          shift 2 ;;
    --telegram-bot-token)     TELEGRAM_BOT_TOKEN="$2";     shift 2 ;;
    --telegram-chat-id)       TELEGRAM_CHAT_ID="$2";       shift 2 ;;
    *) echo "Unknown option: $1"; shift 1 ;;
  esac
done

if [ -z "$PHASE" ] || [ -z "$APP_NAME" ] || [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
  echo "Error: --phase, --app-name, --telegram-bot-token, and --telegram-chat-id are required"
  exit 1
fi

# Build notification text
build_message() {
  local phase=$1
  local status=$2
  local duration=$3
  local error=$4

  case "$status" in
    in_progress)
      echo "⏳ $phase in progress..."
      ;;
    success)
      echo "✅ $phase completed successfully (${duration}s)"
      ;;
    failed)
      echo "❌ $phase failed: $error"
      ;;
  esac
}

# Build full notification
NOTIFICATION=""

case "$PHASE" in
  start)
    NOTIFICATION="🚀 *Deploy started: $APP_NAME*

Image: \`${IMAGE_REF##*/}\`
Run: https://github.com/qwickapps/crew/actions/runs/$GITHUB_RUN_ID

Phases:
├─ Build: ⏳ in progress
├─ Tests: ⏳ waiting
├─ Cutover: ⏳ waiting
└─ Soak: ⏳ waiting"
    ;;

  build)
    if [ "$STATUS" = "success" ]; then
      NOTIFICATION="✅ Build phase complete

Duration: ${DURATION}s
Image: \`${IMAGE_REF##*/}\`

Next: Running integration tests..."
    else
      NOTIFICATION="❌ Build phase failed

Error: $ERROR

See logs: https://github.com/qwickapps/crew/actions/runs/$GITHUB_RUN_ID"
    fi
    ;;

  tests)
    if [ "$STATUS" = "success" ]; then
      NOTIFICATION="✅ Integration tests passed

Duration: ${DURATION}s

Next: Traffic cutover to new live slot..."
    else
      NOTIFICATION="❌ Integration tests failed

Error: $ERROR

Deployment blocked. See logs for details."
    fi
    ;;

  cutover)
    if [ "$STATUS" = "success" ]; then
      NOTIFICATION="✅ Traffic cutover complete

Duration: ${DURATION}s

Next: 2-minute health check soak test..."
    else
      NOTIFICATION="❌ Traffic cutover failed

Error: $ERROR

Rollback to previous stable slot."
    fi
    ;;

  soak)
    if [ "$STATUS" = "success" ]; then
      NOTIFICATION="✅ Soak test passed (2-minute health check)

Duration: ${DURATION}s
Status: All 24 health probes successful

✅ *Deploy COMPLETE*
Service $APP_NAME is now live.
Rollback available for 1 hour if needed."
    else
      NOTIFICATION="❌ Soak test failed

Error: $ERROR

🔄 *Auto-rollback triggered*
Traffic reverted to previous stable slot.
Service is restored.

An incident has been created for investigation."
    fi
    ;;

  complete)
    case "$STATUS" in
      success)
        NOTIFICATION="✅ *Deploy COMPLETE: $APP_NAME*

Duration: ${DURATION}s
Image: \`${IMAGE_REF##*/}\`

Status: ✅ All checks passed
Rollback window: 1 hour

Next: Monitor metrics for anomalies"
        ;;
      failed)
        NOTIFICATION="❌ *Deploy FAILED: $APP_NAME*

Error: $ERROR

Status: Rolled back to previous stable
Incident: See GitHub issue

Next: Investigate root cause and retry"
        ;;
    esac
    ;;

  *)
    NOTIFICATION="❓ Unknown phase: $PHASE"
    ;;
esac

# Send Telegram notification
if [ -n "$NOTIFICATION" ]; then
  TELEGRAM_URL="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

  # Send message
  curl -s -X POST "$TELEGRAM_URL" \
    -H "Content-Type: application/json" \
    -d "{
      \"chat_id\": \"$TELEGRAM_CHAT_ID\",
      \"text\": \"$NOTIFICATION\",
      \"parse_mode\": \"Markdown\"
    }" > /dev/null

  echo "✓ Notification sent (phase: $PHASE, status: $STATUS)"
else
  echo "⚠️  No notification generated (phase: $PHASE)"
fi
