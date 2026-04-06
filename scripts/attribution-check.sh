#!/usr/bin/env bash
# attribution-check.sh
# Checks all commits in a PR for AI co-authorship attribution patterns.
# Exits with code 1 if any AI attribution is found.
#
# Usage:
#   ./scripts/attribution-check.sh <base_sha> <head_sha>
#
# Environment variables:
#   BASE_SHA   - Base commit SHA (default: $1)
#   HEAD_SHA   - Head commit SHA (default: $2)
#   PR_NUMBER  - Pull request number (optional, for reporting)
#
# Exit codes:
#   0 - No AI attribution found
#   1 - AI attribution detected
#   2 - Usage error

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BASE_SHA="${BASE_SHA:-${1:-}}"
HEAD_SHA="${HEAD_SHA:-${2:-}}"

# Patterns to detect AI co-authorship in commit trailers
AI_PATTERNS=(
  "Co-Authored-By:.*[Cc]laude"
  "Co-Authored-By:.*[Cc]opilot"
  "Co-Authored-By:.*GPT"
  "Co-Authored-By:.*OpenAI"
  "Co-Authored-By:.*[Aa]nthropic"
  "Co-Authored-By:.*[Gg]emini"
  "Co-Authored-By:.*[Cc]odex"
  "Co-Authored-By:.*AI Assistant"
  "Co-Authored-By:.*noreply@anthropic\.com"
  "Co-Authored-By:.*noreply@openai\.com"
  "Co-Authored-By:.*noreply@github\.com"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log_info()    { echo -e "${GREEN}[attribution-check]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[attribution-check] WARNING:${NC} $*"; }
log_error()   { echo -e "${RED}[attribution-check] ERROR:${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------

if [[ -z "$BASE_SHA" || -z "$HEAD_SHA" ]]; then
  log_error "Missing required arguments."
  echo "Usage: $0 <base_sha> <head_sha>"
  echo "       or set BASE_SHA and HEAD_SHA environment variables."
  exit 2
fi

log_info "Checking commits from ${BASE_SHA}..${HEAD_SHA}"
if [[ -n "${PR_NUMBER:-}" ]]; then
  log_info "PR #${PR_NUMBER}"
fi

# ---------------------------------------------------------------------------
# Gather commit messages
# ---------------------------------------------------------------------------

COMMITS=$(git log --format="%H %s" "${BASE_SHA}..${HEAD_SHA}" 2>/dev/null) || {
  log_error "Failed to list commits between ${BASE_SHA} and ${HEAD_SHA}."
  log_error "Make sure you have fetched enough history (use fetch-depth: 0 in checkout)."
  exit 2
}

if [[ -z "$COMMITS" ]]; then
  log_info "No commits found in range. Nothing to check."
  exit 0
fi

COMMIT_COUNT=$(echo "$COMMITS" | wc -l | tr -d ' ')
log_info "Scanning ${COMMIT_COUNT} commit(s) for AI attribution..."

# ---------------------------------------------------------------------------
# Scan each commit's full message (including trailers)
# ---------------------------------------------------------------------------

VIOLATIONS=()
CHECKED=0

while IFS= read -r line; do
  SHA=$(echo "$line" | cut -d' ' -f1)
  SUBJECT=$(echo "$line" | cut -d' ' -f2-)

  # Get the full commit message (body + trailers)
  FULL_MSG=$(git log -1 --format="%B" "$SHA" 2>/dev/null) || continue

  for pattern in "${AI_PATTERNS[@]}"; do
    if echo "$FULL_MSG" | grep -qiE "$pattern"; then
      VIOLATIONS+=("${SHA:0:12}: ${SUBJECT} [matched: ${pattern}]")
      break  # Only report each commit once
    fi
  done

  CHECKED=$((CHECKED + 1))
done <<< "$COMMITS"

# ---------------------------------------------------------------------------
# Report results
# ---------------------------------------------------------------------------

echo ""
log_info "Scanned ${CHECKED} commit(s)."

if [[ ${#VIOLATIONS[@]} -gt 0 ]]; then
  echo ""
  log_error "AI co-authorship attribution detected in ${#VIOLATIONS[@]} commit(s):"
  echo ""
  for v in "${VIOLATIONS[@]}"; do
    echo -e "  ${RED}✗${NC}  ${v}"
  done
  echo ""
  log_error "Commits containing AI co-authorship trailers are not permitted in PRs."
  log_error "Please squash or reword the affected commits to remove the attribution."
  echo ""
  exit 1
fi

log_info "No AI attribution found. All ${CHECKED} commit(s) are clean."
exit 0
