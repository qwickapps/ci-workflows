#!/usr/bin/env bash
# pr-status-comment.sh
# Posts CI validation results as a PR comment via the GitHub API.
#
# Usage:
#   ./scripts/pr-status-comment.sh
#
# Required environment variables:
#   GITHUB_TOKEN    - GitHub token with repo/PR comment permissions
#   GITHUB_REPO     - Repository in "owner/repo" format
#   PR_NUMBER       - Pull request number
#   CHECK_STATUS    - "pass" or "fail"
#   CHECK_OUTPUT    - Human-readable summary of check results
#
# Optional environment variables:
#   COMMENT_HEADER  - Override the comment header line
#   DRY_RUN         - Set to "true" to print comment without posting
#
# Exit codes:
#   0 - Comment posted (or dry run completed)
#   1 - Missing required variables or API error
#   2 - Usage error

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[pr-status-comment]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[pr-status-comment] WARNING:${NC} $*"; }
log_error() { echo -e "${RED}[pr-status-comment] ERROR:${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Validate required variables
# ---------------------------------------------------------------------------

REQUIRED_VARS=(GITHUB_TOKEN GITHUB_REPO PR_NUMBER CHECK_STATUS CHECK_OUTPUT)
MISSING=()

for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    MISSING+=("$var")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  log_error "Missing required environment variables: ${MISSING[*]}"
  exit 1
fi

if [[ "$CHECK_STATUS" != "pass" && "$CHECK_STATUS" != "fail" ]]; then
  log_error "CHECK_STATUS must be 'pass' or 'fail', got: '${CHECK_STATUS}'"
  exit 2
fi

# ---------------------------------------------------------------------------
# Build comment body
# ---------------------------------------------------------------------------

if [[ "$CHECK_STATUS" == "pass" ]]; then
  STATUS_ICON="✅"
  STATUS_LABEL="All checks passed"
else
  STATUS_ICON="❌"
  STATUS_LABEL="One or more checks failed"
fi

HEADER="${COMMENT_HEADER:-## CI Validation Report}"
TIMESTAMP=$(date -u "+%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "unknown time")

COMMENT_BODY="${HEADER}

${STATUS_ICON} **${STATUS_LABEL}**

\`\`\`
${CHECK_OUTPUT}
\`\`\`

---
*Posted by [ci-workflows](https://github.com/qwickapps/ci-workflows) at ${TIMESTAMP}*"

# ---------------------------------------------------------------------------
# Post or dry-run
# ---------------------------------------------------------------------------

if [[ "${DRY_RUN:-false}" == "true" ]]; then
  log_info "DRY_RUN=true — comment that would be posted to PR #${PR_NUMBER} on ${GITHUB_REPO}:"
  echo ""
  echo "$COMMENT_BODY"
  echo ""
  exit 0
fi

log_info "Posting status comment to ${GITHUB_REPO}#${PR_NUMBER}..."

# Escape the comment body for JSON
ESCAPED_BODY=$(printf '%s' "$COMMENT_BODY" | python3 -c "
import sys, json
body = sys.stdin.read()
print(json.dumps(body))
" 2>/dev/null) || {
  # Fallback: basic escaping if python3 unavailable
  ESCAPED_BODY=$(printf '%s' "$COMMENT_BODY" \
    | sed 's/\\/\\\\/g' \
    | sed 's/"/\\"/g' \
    | sed ':a;N;$!ba;s/\n/\\n/g')
  ESCAPED_BODY="\"${ESCAPED_BODY}\""
}

API_URL="https://api.github.com/repos/${GITHUB_REPO}/issues/${PR_NUMBER}/comments"

HTTP_STATUS=$(curl -s -o /tmp/pr_comment_response.json -w "%{http_code}" \
  -X POST \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "Content-Type: application/json" \
  --data "{\"body\": ${ESCAPED_BODY}}" \
  "$API_URL")

if [[ "$HTTP_STATUS" == "201" ]]; then
  COMMENT_URL=$(python3 -c "import json,sys; d=json.load(open('/tmp/pr_comment_response.json')); print(d.get('html_url',''))" 2>/dev/null || echo "")
  log_info "Comment posted successfully (HTTP ${HTTP_STATUS})."
  if [[ -n "$COMMENT_URL" ]]; then
    log_info "Comment URL: ${COMMENT_URL}"
  fi
  exit 0
else
  log_error "Failed to post comment (HTTP ${HTTP_STATUS})."
  if [[ -f /tmp/pr_comment_response.json ]]; then
    log_error "API response:"
    cat /tmp/pr_comment_response.json >&2
  fi
  exit 1
fi
