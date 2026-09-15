#!/usr/bin/env bash
#
# verify-stable-gate.sh -- aos#193 Phase 1 §1/§5: deploy-stable's own gate,
# run only when the caller passes require_live_approval_check: true.
#
# Requires ALL of the following, fail-closed with no bypass:
#
#   1. Exactly one `blue-green/live-e2e-approved` check run on the exact
#      commit sha about to deploy to stable. Zero (never approved) or more
#      than one (ambiguous -- which one is authoritative?) both refuse.
#   2. That check run's conclusion == 'success'.
#   3. Its output.text parses as JSON carrying {repo, sha, stage,
#      e2e_digest, directive_payload, directive_signature, directive_body}
#      whose repo/sha/stage match exactly what THIS run is about to deploy
#      (stage must be 'live' -- the record must be of a live promotion,
#      never of anything else).
#   4. directive_payload/directive_signature/directive_body are non-null,
#      AND a real `aos directive verify --require-signer prime
#      --as ci-workflows-stable-gate ...` call against them succeeds.
#
# aos#193's own design doc (latest comment) is explicit that #4 is
# expected to fail today: the CI-invocation signing bridge that would let a
# real prime-signed directive get attached to the live-e2e-approved check
# run does not exist yet. Until it does, directive_payload/signature/body
# are recorded as null by create-blue-green-check-run's caller (see
# deploy-app.yml's "Create live-e2e-approved check run" step), and this
# script refuses on that null exactly as it would refuse an invalid
# signature -- same fail-closed code path, not a special case. That is
# correct and intentional: require_live_approval_check: true is not
# supposed to be usable in production until aos#193 §1's signing bridge is
# built, and this script must not quietly treat "no signature" as "signature
# not required".
#
# Usage:
#   verify-stable-gate.sh \
#     --github-token <token with checks:read> \
#     --repo         <owner>/<repo> \
#     --sha          <commit-sha being deployed to stable> \
#     [--checking-identity ci-workflows-stable-gate] \
#     [--required-signer   prime]
#
# Exit 0 only when every check above passes. Exit 1 (with a clear,
# specifically-named reason on stderr) on any failure.

set -euo pipefail

GITHUB_TOKEN=""
REPO=""
SHA=""
CHECKING_IDENTITY="ci-workflows-stable-gate"
REQUIRED_SIGNER="prime"
CHECK_NAME="blue-green/live-e2e-approved"

usage() {
  cat >&2 <<'EOF'
Usage:
  verify-stable-gate.sh --github-token <token> --repo <owner/repo> --sha <sha> \
    [--checking-identity <name>] [--required-signer <name>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github-token)      GITHUB_TOKEN="$2"; shift 2 ;;
    --repo)              REPO="$2"; shift 2 ;;
    --sha)               SHA="$2"; shift 2 ;;
    --checking-identity) CHECKING_IDENTITY="$2"; shift 2 ;;
    --required-signer)   REQUIRED_SIGNER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "::error::unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

for var in GITHUB_TOKEN REPO SHA; do
  if [ -z "${!var}" ]; then
    flag="$(printf '%s' "$var" | tr '[:upper:]_' '[:lower:]-')"
    echo "::error::missing required argument: --$flag" >&2
    usage
    exit 2
  fi
done

export GH_TOKEN="$GITHUB_TOKEN"

refuse() {
  echo "::error::verify-stable-gate REFUSED (${1}): ${2}" >&2
  exit 1
}

# ── 1/2: exactly one check run, conclusion == success ────────────────────
CHECK_NAME_ENCODED="$(jq -rn --arg n "$CHECK_NAME" '$n | @uri')"
RESPONSE="$(gh api "repos/${REPO}/commits/${SHA}/check-runs?check_name=${CHECK_NAME_ENCODED}" 2>&1)" \
  || refuse "check_runs_query_failed" "could not query check-runs for ${REPO}@${SHA}: ${RESPONSE:-<no output>}"

if ! printf '%s' "$RESPONSE" | jq -e . >/dev/null 2>&1; then
  refuse "check_runs_query_failed" "non-JSON response from check-runs API"
fi

COUNT="$(printf '%s' "$RESPONSE" | jq -r '.total_count // 0')"
if [ "$COUNT" != "1" ]; then
  refuse "wrong_check_run_count" "expected exactly 1 '${CHECK_NAME}' check run on ${SHA}, found ${COUNT} -- zero means never approved, more than one is ambiguous and neither is accepted"
fi

CONCLUSION="$(printf '%s' "$RESPONSE" | jq -r '.check_runs[0].conclusion // "null"')"
if [ "$CONCLUSION" != "success" ]; then
  refuse "check_run_not_successful" "'${CHECK_NAME}' on ${SHA} has conclusion='${CONCLUSION}', not 'success'"
fi

# ── 3: parse and cross-check the embedded payload ────────────────────────
OUTPUT_TEXT="$(printf '%s' "$RESPONSE" | jq -r '.check_runs[0].output.text // ""')"
if [ -z "$OUTPUT_TEXT" ] || ! printf '%s' "$OUTPUT_TEXT" | jq -e . >/dev/null 2>&1; then
  refuse "malformed_check_run_output" "'${CHECK_NAME}' output.text is missing or not valid JSON"
fi

RECORD_REPO="$(printf '%s' "$OUTPUT_TEXT" | jq -r '.repo // ""')"
RECORD_SHA="$(printf '%s' "$OUTPUT_TEXT" | jq -r '.sha // ""')"
RECORD_STAGE="$(printf '%s' "$OUTPUT_TEXT" | jq -r '.stage // ""')"

if [ "$RECORD_REPO" != "$REPO" ]; then
  refuse "payload_repo_mismatch" "check run records repo='${RECORD_REPO}', expected '${REPO}'"
fi
if [ "$RECORD_SHA" != "$SHA" ]; then
  refuse "payload_sha_mismatch" "check run records sha='${RECORD_SHA}', expected '${SHA}'"
fi
if [ "$RECORD_STAGE" != "live" ]; then
  refuse "payload_stage_mismatch" "check run records stage='${RECORD_STAGE}', expected 'live'"
fi

# ── 4: directive signature verification (fails closed today -- see the
#    module docstring above) ──────────────────────────────────────────────
DIRECTIVE_PAYLOAD="$(printf '%s' "$OUTPUT_TEXT" | jq -r '.directive_payload // empty')"
DIRECTIVE_SIGNATURE="$(printf '%s' "$OUTPUT_TEXT" | jq -r '.directive_signature // empty')"
DIRECTIVE_BODY="$(printf '%s' "$OUTPUT_TEXT" | jq -r '.directive_body // empty')"

if [ -z "$DIRECTIVE_PAYLOAD" ] || [ -z "$DIRECTIVE_SIGNATURE" ] || [ -z "$DIRECTIVE_BODY" ]; then
  refuse "missing_directive_signature" \
    "'${CHECK_NAME}' carries no directive_payload/signature/body yet -- the aos#193 §1 CI-invocation signing bridge is not built (see aos#193's latest comment); require_live_approval_check cannot succeed until it is, by design"
fi

if ! command -v aos >/dev/null 2>&1; then
  refuse "aos_cli_unavailable" "the 'aos' CLI is not on PATH on this runner -- cannot verify a directive without it"
fi

# aos directive verify refuses outright (no_durable_nonce_store) with no
# $AOS_ENVIRONMENT_ROOT known, before ever touching the payload -- see
# aos.cli._cmd_directive_verify. That refusal is itself a correct
# fail-closed outcome for this gate, so it is deliberately NOT worked
# around here (e.g. by pointing at a fresh throwaway directory every run,
# which would silently defeat replay protection).
AOS_JSON=""
AOS_EXIT=0
AOS_JSON="$(aos directive verify \
  --payload "$DIRECTIVE_PAYLOAD" \
  --signature "$DIRECTIVE_SIGNATURE" \
  --body "$DIRECTIVE_BODY" \
  --as "$CHECKING_IDENTITY" \
  --require-signer "$REQUIRED_SIGNER" \
  --json 2>&1)" || AOS_EXIT=$?

if [ "$AOS_EXIT" -ne 0 ]; then
  AOS_CHECK="$(printf '%s' "$AOS_JSON" | tail -n1 | jq -r '.check // "unknown"' 2>/dev/null || echo "unknown")"
  AOS_REASON="$(printf '%s' "$AOS_JSON" | tail -n1 | jq -r '.reason // .' 2>/dev/null || printf '%s' "$AOS_JSON")"
  refuse "directive_verify_failed:${AOS_CHECK}" "aos directive verify refused: ${AOS_REASON}"
fi

echo "verify-stable-gate: PASS -- '${CHECK_NAME}' on ${REPO}@${SHA} is valid, single, successful, payload-matched, and directive-verified (signer=${REQUIRED_SIGNER}, target=${CHECKING_IDENTITY})" >&2
