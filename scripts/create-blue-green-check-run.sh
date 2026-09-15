#!/usr/bin/env bash
#
# create-blue-green-check-run.sh -- creates a GitHub Check Run tied to a
# specific commit sha, used by deploy-app.yml as the tamper-evident,
# independently-auditable record for two aos#193 Phase 1 mechanisms:
#
#   - `blue-green/first-deploy-used`: a single-use marker written on a
#     successful first-deploy live promotion, so a second "first deploy"
#     can never be claimed for the same app on the same commit even if
#     CapRover/GHCR history were somehow cleared afterward (§2).
#   - `blue-green/live-e2e-approved`: the "live validated and approved"
#     record deploy-stable's gate requires when the caller opts into
#     require_live_approval_check (§1/§5). Its JSON body carries the exact
#     payload the stable gate re-checks -- see verify-stable-gate.sh.
#
# A Check Run (not a workflow artifact) is used deliberately: tied to
# head_sha (immutable), queryable independently via
# `GET /repos/{owner}/{repo}/commits/{sha}/check-runs` with the same
# GITHUB_TOKEN every job already has, and visible on the commit/PR in the
# GitHub UI for human audit (aos#193 design, §2).
#
# Usage:
#   create-blue-green-check-run.sh \
#     --github-token <token with checks:write> \
#     --repo         <owner>/<repo> \
#     --sha          <commit-sha> \
#     --name         blue-green/first-deploy-used | blue-green/live-e2e-approved \
#     --title        <short title> \
#     --summary      <short human-readable summary> \
#     [--conclusion  success]  (default: success -- this script only ever
#                               records a POSITIVE record; a failed
#                               e2e/approval simply never reaches this
#                               script, by construction) \
#     [--output-json <JSON object>]   (merged into output.text verbatim,
#                                       so a caller downstream -- e.g.
#                                       verify-stable-gate.sh -- can parse
#                                       it back out)
#
# Emits the created check run's `id` and `html_url` to stderr for the
# workflow log; nothing meaningful goes to stdout other than the raw API
# response (kept off stdout intentionally so callers piping this script's
# stdout elsewhere never have to strip diagnostics).

set -euo pipefail

GITHUB_TOKEN=""
REPO=""
SHA=""
NAME=""
TITLE=""
SUMMARY=""
CONCLUSION="success"
OUTPUT_JSON=""

usage() {
  cat >&2 <<'EOF'
Usage:
  create-blue-green-check-run.sh \
    --github-token <token> --repo <owner/repo> --sha <sha> --name <name> \
    --title <title> --summary <summary> \
    [--conclusion <success|...>] [--output-json <json-object>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github-token) GITHUB_TOKEN="$2"; shift 2 ;;
    --repo)         REPO="$2"; shift 2 ;;
    --sha)          SHA="$2"; shift 2 ;;
    --name)         NAME="$2"; shift 2 ;;
    --title)        TITLE="$2"; shift 2 ;;
    --summary)      SUMMARY="$2"; shift 2 ;;
    --conclusion)   CONCLUSION="$2"; shift 2 ;;
    --output-json)  OUTPUT_JSON="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "::error::unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

for var in GITHUB_TOKEN REPO SHA NAME TITLE SUMMARY; do
  if [ -z "${!var}" ]; then
    flag="$(printf '%s' "$var" | tr '[:upper:]_' '[:lower:]-')"
    echo "::error::missing required argument: --$flag" >&2
    usage
    exit 2
  fi
done

if [ -n "$OUTPUT_JSON" ]; then
  if ! printf '%s' "$OUTPUT_JSON" | jq -e . >/dev/null 2>&1; then
    echo "::error::--output-json is not valid JSON: $OUTPUT_JSON" >&2
    exit 2
  fi
fi

export GH_TOKEN="$GITHUB_TOKEN"

TEXT_VALUE="$OUTPUT_JSON"
if [ -z "$TEXT_VALUE" ]; then
  TEXT_VALUE='{}'
fi

PAYLOAD="$(jq -nc \
  --arg name "$NAME" \
  --arg sha "$SHA" \
  --arg title "$TITLE" \
  --arg summary "$SUMMARY" \
  --arg conclusion "$CONCLUSION" \
  --arg text "$TEXT_VALUE" \
  '{
    name: $name,
    head_sha: $sha,
    status: "completed",
    conclusion: $conclusion,
    output: {
      title: $title,
      summary: $summary,
      text: $text
    }
  }')"

echo "create-blue-green-check-run: creating '${NAME}' on ${REPO}@${SHA} (conclusion=${CONCLUSION})..." >&2

RESPONSE="$(printf '%s' "$PAYLOAD" | gh api "repos/${REPO}/check-runs" --input -)"

if ! printf '%s' "$RESPONSE" | jq -e '.id' >/dev/null 2>&1; then
  echo "::error::create-blue-green-check-run: unexpected response creating '${NAME}':" >&2
  echo "$RESPONSE" >&2
  exit 1
fi

CHECK_RUN_ID="$(printf '%s' "$RESPONSE" | jq -r '.id')"
CHECK_RUN_URL="$(printf '%s' "$RESPONSE" | jq -r '.html_url // empty')"
echo "create-blue-green-check-run: created '${NAME}' id=${CHECK_RUN_ID} ${CHECK_RUN_URL}" >&2
