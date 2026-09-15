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
#   3. Its output.text parses as JSON carrying {repo, app_name, sha, stage,
#      e2e_digest, directive_payload, directive_signature, directive_body}
#      whose repo/app_name/sha/stage match exactly what THIS run is about
#      to deploy (stage must be 'live' -- the record must be of a live
#      promotion, never of anything else).
#   4. The check run's CREATION is itself independently verified against
#      the GitHub Actions API -- see aos#193 review finding #1 (BLOCKER,
#      round 2) and scripts/lib/check-run-binding.sh's header for the full
#      story. In short: this used to trust a SELF-REPORTED
#      `output.text.workflow_ref` string, which (a) a real record never
#      actually satisfied, because inside a reusable workflow
#      `github.workflow_ref` names the CALLER's workflow, not
#      deploy-app.yml -- so this refused every legitimate record -- and
#      (b) was trivially forgeable by any other same-repo workflow with
#      checks:write, since it's just text the creating step controls. The
#      fix instead requires: the record was created by the standard
#      Actions token (`check_run.app.slug == "github-actions"`), and the
#      run named by its `external_id` (`GET /repos/{repo}/actions/runs/
#      {run_id}`) has `head_sha` == this sha, `repository.full_name` ==
#      this repo, `status` == "completed", and `referenced_workflows[]`
#      contains an entry whose `path` starts with
#      "qwickapps/ci-workflows/.github/workflows/deploy-app.yml@" -- proof
#      the run that created this record actually EXECUTED this reusable
#      workflow, not merely claimed to.
#   5. directive_payload/directive_signature/directive_body are non-null,
#      AND a real `aos directive verify --require-signer prime
#      --as ci-workflows-stable-gate ...` call against them succeeds.
#
# aos#193's own design doc (latest comment) is explicit that #5 is
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
#     --app-name     <app> \
#     --sha          <commit-sha being deployed to stable> \
#     [--checking-identity ci-workflows-stable-gate] \
#     [--required-signer   prime] \
#     [--aos-bin <absolute path to the pinned aos binary>] (default: "aos",
#       resolved via PATH -- production call sites must always pass an
#       absolute path into a fresh, pin-verified per-job venv; see
#       deploy-app.yml. Left as a bare name here only so this script stays
#       directly testable against a mock on PATH.) \
#     [--aos-environment-root <dir>]  (a job-scoped, empty directory --
#       NEVER the shared runner's ambient $AOS_ENVIRONMENT_ROOT, if any.
#       When omitted, AOS_ENVIRONMENT_ROOT is explicitly unset for the aos
#       call rather than left to inherit whatever the environment has.) \
#     [--aos-manifest <absolute path to a committed, checksummed manifest>]
#       (default: unset -- see aos#193 review finding #4 below. Production
#       call sites must always pass deploy-app.yml's committed
#       scripts/aos-manifest/prime-manifest.yaml, checksum-verified by the
#       caller before this script ever runs.)
#
# aos#193 review finding #4 (HIGH, round 2): $AOS_MANIFEST is ALWAYS
# explicitly set via `env` to EXACTLY what --aos-manifest names (or, if
# --aos-manifest was not given, explicitly UNSET via `env -u`, never
# merely "not set by us") -- manifest resolution can never pick up an
# inherited, possibly-stale or environment-poisoned manifest from the
# shared macmini runner's ambient environment either way.
#
# This script previously claimed (incorrectly) that unsetting AOS_MANIFEST
# made `aos` "fall back to the pinned aos package's own bundled default
# manifest". That was never true: aos@41f0a59's own
# `DEFAULT_MANIFEST = Path(__file__).resolve().parent.parent / "config" /
# "agents.yaml"` (aos/cli.py), but aos's pyproject.toml packages only
# `aos*`/`scripts*` plus specific package-data globs (`hooks/*.sh`,
# `guard/data/*.yaml`) -- `config/agents.yaml` is NOT included in the built
# wheel at all. So with no manifest passed, the installed venv's default
# manifest path names a file that does not exist on disk, and verification
# fails closed TODAY only because there is no manifest at all to read --
# an ACCIDENTAL fail-closed, not a designed one, and the comment
# describing it as "falls back to a bundled default manifest declaring no
# signing_key for prime" was simply wrong (no such bundled manifest ships).
#
# The real fix: deploy-app.yml's call site passes --aos-manifest pointing
# at scripts/aos-manifest/prime-manifest.yaml -- a REAL manifest committed
# to ci-workflows itself (schema-valid `fleet/v2`, with a `prime` agent
# entry) whose sha256 the caller verifies against a hardcoded expected
# value before ever invoking this script, so a compromised runner can't
# silently swap the manifest file out from under a correct checksum
# recorded in this repo's own git history. That manifest's `prime` entry
# deliberately carries NO real `signing_key:` yet -- aos#123 §5 hasn't
# provisioned a real prime key into it (key custody moved into the secrets
# service; see aos's docs/adr/002-prime-key-isolation.md "Update" section)
# -- so `aos directive verify --require-signer prime` still cannot succeed
# against ANY payload today. That remains the intended, DOCUMENTED
# fail-closed guarantee this finding asked for: not an accident of a
# missing file, but a deliberate placeholder manifest whose shape and path
# are pinned and committed, with no real key inside it yet.
#
# Exit 0 only when every check above passes. Exit 1 (with a clear,
# specifically-named reason on stderr) on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/check-run-binding.sh
source "$SCRIPT_DIR/lib/check-run-binding.sh"

GITHUB_TOKEN=""
REPO=""
APP_NAME=""
SHA=""
CHECKING_IDENTITY="ci-workflows-stable-gate"
REQUIRED_SIGNER="prime"
AOS_BIN="aos"
AOS_ENV_ROOT=""
AOS_MANIFEST_PATH=""

usage() {
  cat >&2 <<'EOF'
Usage:
  verify-stable-gate.sh --github-token <token> --repo <owner/repo> --app-name <app> --sha <sha> \
    [--checking-identity <name>] [--required-signer <name>] \
    [--aos-bin <path>] [--aos-environment-root <dir>] [--aos-manifest <path>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github-token)      GITHUB_TOKEN="$2"; shift 2 ;;
    --repo)              REPO="$2"; shift 2 ;;
    --app-name)          APP_NAME="$2"; shift 2 ;;
    --sha)                SHA="$2"; shift 2 ;;
    --checking-identity) CHECKING_IDENTITY="$2"; shift 2 ;;
    --required-signer)   REQUIRED_SIGNER="$2"; shift 2 ;;
    --aos-bin)            AOS_BIN="$2"; shift 2 ;;
    --aos-environment-root) AOS_ENV_ROOT="$2"; shift 2 ;;
    --aos-manifest)       AOS_MANIFEST_PATH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "::error::unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

for var in GITHUB_TOKEN REPO APP_NAME SHA; do
  if [ -z "${!var}" ]; then
    flag="$(printf '%s' "$var" | tr '[:upper:]_' '[:lower:]-')"
    echo "::error::missing required argument: --$flag" >&2
    usage
    exit 2
  fi
done

CHECK_NAME="blue-green/live-e2e-approved/${APP_NAME}"

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

# ── 3: parse and cross-check the embedded payload (repo/app_name/sha/
#    stage) ─────────────────────────────────────────────────────────────
OUTPUT_TEXT="$(printf '%s' "$RESPONSE" | jq -r '.check_runs[0].output.text // ""')"
if [ -z "$OUTPUT_TEXT" ] || ! printf '%s' "$OUTPUT_TEXT" | jq -e . >/dev/null 2>&1; then
  refuse "malformed_check_run_output" "'${CHECK_NAME}' output.text is missing or not valid JSON"
fi

RECORD_REPO="$(printf '%s' "$OUTPUT_TEXT" | jq -r '.repo // ""')"
RECORD_APP_NAME="$(printf '%s' "$OUTPUT_TEXT" | jq -r '.app_name // ""')"
RECORD_SHA="$(printf '%s' "$OUTPUT_TEXT" | jq -r '.sha // ""')"
RECORD_STAGE="$(printf '%s' "$OUTPUT_TEXT" | jq -r '.stage // ""')"

if [ "$RECORD_REPO" != "$REPO" ]; then
  refuse "payload_repo_mismatch" "check run records repo='${RECORD_REPO}', expected '${REPO}'"
fi
if [ "$RECORD_APP_NAME" != "$APP_NAME" ]; then
  refuse "payload_app_name_mismatch" "check run records app_name='${RECORD_APP_NAME}', expected '${APP_NAME}' -- a different app's approval on this same commit does not count"
fi
if [ "$RECORD_SHA" != "$SHA" ]; then
  refuse "payload_sha_mismatch" "check run records sha='${RECORD_SHA}', expected '${SHA}'"
fi
if [ "$RECORD_STAGE" != "live" ]; then
  refuse "payload_stage_mismatch" "check run records stage='${RECORD_STAGE}', expected 'live'"
fi

# ── 4: GitHub-verified binding (aos#193 review finding #1, BLOCKER) ──────
# Never trust the record's own self-reported text -- see
# scripts/lib/check-run-binding.sh's header for the full story on why.
APP_SLUG="$(printf '%s' "$RESPONSE" | jq -r '.check_runs[0].app.slug // ""')"
EXTERNAL_ID="$(printf '%s' "$RESPONSE" | jq -r '.check_runs[0].external_id // ""')"
# check_run_binding_verify prints its own specifically-named ::error::
# reason directly to stderr on failure -- nothing further to add here.
check_run_binding_verify "$REPO" "$SHA" "$APP_SLUG" "$EXTERNAL_ID" || exit 1

# ── 5: directive signature verification (fails closed today -- see the
#    module docstring above) ──────────────────────────────────────────────
DIRECTIVE_PAYLOAD="$(printf '%s' "$OUTPUT_TEXT" | jq -r '.directive_payload // empty')"
DIRECTIVE_SIGNATURE="$(printf '%s' "$OUTPUT_TEXT" | jq -r '.directive_signature // empty')"
DIRECTIVE_BODY="$(printf '%s' "$OUTPUT_TEXT" | jq -r '.directive_body // empty')"

if [ -z "$DIRECTIVE_PAYLOAD" ] || [ -z "$DIRECTIVE_SIGNATURE" ] || [ -z "$DIRECTIVE_BODY" ]; then
  refuse "missing_directive_signature" \
    "'${CHECK_NAME}' carries no directive_payload/signature/body yet -- the aos#193 §1 CI-invocation signing bridge is not built (see aos#193's latest comment); require_live_approval_check cannot succeed until it is, by design"
fi

if ! command -v "$AOS_BIN" >/dev/null 2>&1; then
  refuse "aos_cli_unavailable" "'${AOS_BIN}' is not available (not on PATH, or not an executable file at that path) -- cannot verify a directive without it"
fi

# aos#193 review finding #4: AOS_MANIFEST is ALWAYS explicitly set here to
# exactly what --aos-manifest named (or explicitly UNSET via `env -u`, not
# merely "we never set it", when no --aos-manifest was given) -- never
# inherited from whatever the shared macmini runner's ambient environment
# happens to carry, which could otherwise let a directive signed by a
# manifest this workflow never chose verify successfully. AOS_ENVIRONMENT_ROOT
# is likewise unset unless the caller explicitly passed a job-scoped one via
# --aos-environment-root -- never left to inherit an ambient value either.
#
# aos directive verify refuses outright (no_durable_nonce_store) with no
# environment root known, before ever touching the payload -- see
# aos.cli._cmd_directive_verify. That refusal is itself a correct
# fail-closed outcome for this gate, so it is deliberately NOT worked
# around by pointing at some throwaway directory here -- deploy-app.yml's
# call site passes a real, job-scoped --aos-environment-root instead.
AOS_JSON=""
AOS_EXIT=0
ENV_ARGS=(-u AOS_ENVIRONMENT_ROOT)
if [ -n "$AOS_MANIFEST_PATH" ]; then
  ENV_ARGS+=("AOS_MANIFEST=${AOS_MANIFEST_PATH}")
else
  ENV_ARGS+=(-u AOS_MANIFEST)
fi
if [ -n "$AOS_ENV_ROOT" ]; then
  ENV_ARGS+=("AOS_ENVIRONMENT_ROOT=${AOS_ENV_ROOT}")
fi
AOS_JSON="$(env "${ENV_ARGS[@]}" "$AOS_BIN" directive verify \
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

echo "verify-stable-gate: PASS -- '${CHECK_NAME}' on ${REPO}@${SHA} is valid, single, successful, payload-matched, binding-verified, and directive-verified (signer=${REQUIRED_SIGNER}, target=${CHECKING_IDENTITY})" >&2
