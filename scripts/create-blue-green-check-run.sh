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
#     --name         blue-green/first-deploy-used/<app> | blue-green/live-e2e-approved/<app> \
#     --title        <short title> \
#     --summary      <short human-readable summary> \
#     [--conclusion  success]  (default: success -- this script only ever
#                               records a POSITIVE record; a failed
#                               e2e/approval simply never reaches this
#                               script, by construction) \
#     [--output-json <JSON object>]   (merged into output.text verbatim,
#                                       so a caller downstream -- e.g.
#                                       verify-stable-gate.sh -- can parse
#                                       it back out) \
#     [--external-id <opaque id>]     (recorded verbatim on the check run's
#                                       `external_id` field, expected as
#                                       "<github.run_id>-<github.run_attempt>".
#                                       aos#193 review finding #1 (BLOCKER,
#                                       round 2): THIS field is exactly
#                                       what read-side callers
#                                       (verify-stable-gate.sh,
#                                       check-first-deploy-proof.sh, via
#                                       scripts/lib/check-run-binding.sh)
#                                       independently re-verify against the
#                                       GitHub Actions API on read --
#                                       `GET /repos/{repo}/actions/runs/
#                                       {run_id}`, checking head_sha,
#                                       repository, status, and
#                                       referenced_workflows[]. This
#                                       replaces the previous design, which
#                                       instead trusted a self-reported
#                                       `output.text.workflow_ref` string --
#                                       broken two ways (a real record's
#                                       workflow_ref names the CALLER's
#                                       workflow inside a reusable workflow,
#                                       never deploy-app.yml itself, so it
#                                       never actually matched; and it was
#                                       trivially forgeable text besides).
#                                       See check-run-binding.sh's header
#                                       for the full story.) \
#     [--on-permission-denied fail|skip]  (default: fail. aos#193 review
#                                       finding #1: deploy-caprover's and
#                                       deploy-stable's job-level
#                                       permissions blocks deliberately do
#                                       NOT grant checks:write/read today
#                                       -- see deploy-app.yml's comments --
#                                       so a caller that opts into
#                                       require_live_approval_check before
#                                       that Phase 1b follow-up lands will
#                                       hit a 403 here. `skip` logs a clear
#                                       warning and exits 0 instead of
#                                       failing the whole job -- safe ONLY
#                                       for a record whose absence a
#                                       downstream fail-closed gate already
#                                       treats as "not approved"/"not used"
#                                       (both blue-green check runs are:
#                                       verify-stable-gate.sh refuses with
#                                       zero matching check runs; and for
#                                       the first-deploy-used marker
#                                       specifically, a missing marker does
#                                       NOT "fall through to today's real
#                                       stable-health check" -- it falls
#                                       through to check-first-deploy-proof.sh's
#                                       OTHER two signals, which are the
#                                       actual backstop: a real first
#                                       deploy always retags the image
#                                       :stable (see resolve-stage's
#                                       NEXT_TAG="${IMAGE_BASE}:stable"),
#                                       so a REPEAT first-deploy claim on a
#                                       later commit is still caught by
#                                       GHCR release/stable tag-history
#                                       once that retag has happened, even
#                                       with zero markers recorded).
#                                       Never use `skip` for a step whose
#                                       success gates something.)
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
EXTERNAL_ID=""
ON_PERMISSION_DENIED="fail"

usage() {
  cat >&2 <<'EOF'
Usage:
  create-blue-green-check-run.sh \
    --github-token <token> --repo <owner/repo> --sha <sha> --name <name> \
    --title <title> --summary <summary> \
    [--conclusion <success|...>] [--output-json <json-object>] \
    [--external-id <id>] [--on-permission-denied fail|skip]
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
    --external-id)  EXTERNAL_ID="$2"; shift 2 ;;
    --on-permission-denied) ON_PERMISSION_DENIED="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "::error::unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

case "$ON_PERMISSION_DENIED" in
  fail|skip) ;;
  *) echo "::error::--on-permission-denied must be 'fail' or 'skip', got: $ON_PERMISSION_DENIED" >&2; exit 2 ;;
esac

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
  --arg external_id "$EXTERNAL_ID" \
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
  }
  + (if $external_id != "" then {external_id: $external_id} else {} end)')"

echo "create-blue-green-check-run: creating '${NAME}' on ${REPO}@${SHA} (conclusion=${CONCLUSION})..." >&2

ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT
set +e
RESPONSE="$(printf '%s' "$PAYLOAD" | gh api "repos/${REPO}/check-runs" --input - 2>"$ERR_FILE")"
API_EXIT=$?
set -e

if [ "$API_EXIT" -ne 0 ]; then
  # aos#193 review finding #1's fallback: deploy-caprover/deploy-stable
  # deliberately do NOT get checks:write/read in their job-level
  # permissions today (a job's permissions block is validated for the
  # WHOLE reusable workflow at dispatch time regardless of any step's or
  # job's `if:` -- confirmed empirically against this org's own
  # qwickapps/forge#254 incident shape: a job with elevated permissions
  # gated by `if: false` still trips startup_failure with zero jobs
  # created). A 403 here is therefore an EXPECTED outcome for any caller
  # that opts into require_live_approval_check before the 14 callers'
  # top-level permissions grant checks down (a required Phase 1b
  # follow-up) -- not a bug in this script.
  if grep -qiE "HTTP 403|Resource not accessible by integration" "$ERR_FILE" && [ "$ON_PERMISSION_DENIED" = "skip" ]; then
    echo "::warning::create-blue-green-check-run: '${NAME}' was NOT created -- GITHUB_TOKEN lacks checks:write on this job (aos#193 Phase 1b: checks:write must land in the 14 callers' top-level permissions before require_live_approval_check works in production). Skipping, not failing this deploy -- a downstream fail-closed reader already treats a missing record correctly." >&2
    exit 0
  fi
  echo "::error::create-blue-green-check-run: gh api failed creating '${NAME}':" >&2
  cat "$ERR_FILE" >&2
  exit 1
fi

if ! printf '%s' "$RESPONSE" | jq -e '.id' >/dev/null 2>&1; then
  echo "::error::create-blue-green-check-run: unexpected response creating '${NAME}':" >&2
  echo "$RESPONSE" >&2
  exit 1
fi

CHECK_RUN_ID="$(printf '%s' "$RESPONSE" | jq -r '.id')"
CHECK_RUN_URL="$(printf '%s' "$RESPONSE" | jq -r '.html_url // empty')"
echo "create-blue-green-check-run: created '${NAME}' id=${CHECK_RUN_ID} ${CHECK_RUN_URL}" >&2
