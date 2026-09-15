#!/usr/bin/env bash
#
# Scenario tests for scripts/verify-stable-gate.sh (aos#193 Phase 1 §1/§5):
# deploy-stable's gate, active only when the caller passes
# require_live_approval_check: true. Invokes the real script as a
# subprocess with `gh` and `aos` replaced by mocks first on PATH, proving
# the fail-closed decision tree end to end:
#
#   0 or 2+ check runs                 -> refused
#   1 check run, conclusion != success -> refused
#   1 success check run, payload repo/sha/stage mismatch -> refused
#   1 success check run, no directive_payload/signature/body (today's
#     expected state -- the aos#193 §1 signing bridge isn't built)
#                                       -> refused, WITHOUT ever invoking aos
#   1 success check run, payload matches, aos directive verify says ok      -> PASS
#   1 success check run, payload matches, aos directive verify says refused -> refused
#
# The mock `gh`/`aos` binaries are fixed scripts written once; each
# scenario configures them via a JSON response file and an env var rather
# than regenerating shell-embedded heredocs per scenario, so no scenario
# payload ever has to survive double shell/JSON quoting.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SUT="$SCRIPTS_DIR/verify-stable-gate.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0
mkdir -p "$TMPDIR/bin"

REPO="qwickapps/demo"
SHA="0123456789abcdef0123456789abcdef01234567"
RESPONSE_FILE="$TMPDIR/gh-check-runs-response.json"
AOS_MODE_FILE="$TMPDIR/aos-mode"
AOS_CALLED_LOG="$TMPDIR/aos-called.log"

cat > "$TMPDIR/bin/gh" <<MOCK
#!/usr/bin/env bash
if [ "\${1:-}" != "api" ]; then
  echo "mock gh: unexpected command: \$*" >&2
  exit 1
fi
shift
url=""
for a in "\$@"; do
  case "\$a" in
    -*) ;;
    *) url="\$a" ;;
  esac
done
case "\$url" in
  *commits/*/check-runs*)
    cat "$RESPONSE_FILE"
    ;;
  *)
    echo "mock gh: unexpected api url: \$url" >&2
    exit 1
    ;;
esac
MOCK
chmod +x "$TMPDIR/bin/gh"

cat > "$TMPDIR/bin/aos" <<MOCK
#!/usr/bin/env bash
echo "called" >> "$AOS_CALLED_LOG"
mode="\$(cat "$AOS_MODE_FILE" 2>/dev/null || echo ok)"
if [ "\$mode" = "ok" ]; then
  echo '{"ok": true, "from": "prime", "scope": "test", "target": "ci-workflows-stable-gate"}'
  exit 0
else
  echo '{"ok": false, "check": "bad_signature", "reason": "signature did not verify"}'
  exit 3
fi
MOCK
chmod +x "$TMPDIR/bin/aos"

# --- response builders (real jq -- available on the ambient PATH; the
#     mock bin dir is prepended but doesn't shadow jq) ---------------------

set_response_count() {
  # $1 = total_count (0 or 2, no meaningful conclusion/output needed)
  jq -nc --argjson count "$1" '{
    total_count: $count,
    check_runs: (
      if $count == 0 then []
      else [range($count) | {conclusion: "success", output: {}}]
      end
    )
  }' > "$RESPONSE_FILE"
}

set_response_one() {
  # $1 = conclusion, $2 = output.text (a JSON *string* value, already
  # serialized -- pass "" to omit output.text entirely)
  local conclusion="$1" text="$2"
  if [ -z "$text" ]; then
    jq -nc --arg c "$conclusion" '{total_count: 1, check_runs: [{conclusion: $c, output: {}}]}' > "$RESPONSE_FILE"
  else
    jq -nc --arg c "$conclusion" --arg t "$text" '{total_count: 1, check_runs: [{conclusion: $c, output: {text: $t}}]}' > "$RESPONSE_FILE"
  fi
}

matching_payload_text() {
  jq -nc --arg repo "$REPO" --arg sha "$SHA" '{
    repo: $repo, sha: $sha, stage: "live", e2e_digest: "sha256:deadbeef",
    directive_payload: "{\"from\":\"prime\"}", directive_signature: "armored-sig", directive_body: "body text"
  }'
}

set_aos_mode() { printf '%s' "$1" > "$AOS_MODE_FILE"; }

run_sut() {
  local out_file="$1"
  rm -f "$AOS_CALLED_LOG"
  (
    export PATH="$TMPDIR/bin:$PATH"
    bash "$SUT" --github-token irrelevant --repo "$REPO" --sha "$SHA"
  ) > "$out_file" 2>&1
}

assert_refused() {
  local desc="$1" needle="$2"
  local out="$TMPDIR/out-$RANDOM"
  set +e
  run_sut "$out"
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ] && grep -qF "$needle" "$out"; then
    echo "  PASS (refused): $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL (refused): $desc -- expected exit!=0 containing: $needle"
    echo "    actual exit=$rc:"
    sed 's/^/      /' "$out"
    fail=$((fail + 1))
  fi
}

assert_passes() {
  local desc="$1"
  local out="$TMPDIR/out-$RANDOM"
  set +e
  run_sut "$out"
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "  PASS (allowed): $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL (allowed): $desc -- expected exit=0, got $rc"
    sed 's/^/      /' "$out"
    fail=$((fail + 1))
  fi
}

echo "== verify-stable-gate.sh: check-run count and conclusion =="

set_response_count 0
assert_refused "zero check runs -> refused (never approved)" "wrong_check_run_count"

set_response_count 2
assert_refused "two check runs -> refused (ambiguous)" "wrong_check_run_count"

set_response_one "failure" ""
assert_refused "one check run, conclusion=failure -> refused" "check_run_not_successful"

echo ""
echo "== verify-stable-gate.sh: payload cross-checks =="

MISMATCHED_PAYLOAD="$(jq -nc --arg sha "$SHA" '{repo: "qwickapps/OTHER", sha: $sha, stage: "live"}')"
set_response_one "success" "$MISMATCHED_PAYLOAD"
assert_refused "repo mismatch in embedded payload -> refused" "payload_repo_mismatch"

WRONG_STAGE_PAYLOAD="$(jq -nc --arg repo "$REPO" --arg sha "$SHA" '{repo: $repo, sha: $sha, stage: "uat"}')"
set_response_one "success" "$WRONG_STAGE_PAYLOAD"
assert_refused "stage != 'live' in embedded payload -> refused" "payload_stage_mismatch"

echo ""
echo "== verify-stable-gate.sh: missing directive signature (today's expected state) =="

NO_SIG_PAYLOAD="$(jq -nc --arg repo "$REPO" --arg sha "$SHA" '{
  repo: $repo, sha: $sha, stage: "live", e2e_digest: "sha256:x",
  directive_payload: null, directive_signature: null, directive_body: null
}')"
set_response_one "success" "$NO_SIG_PAYLOAD"
set_aos_mode "ok"
assert_refused "null directive_payload/signature/body -> refused closed, WITHOUT invoking aos (aos#193 §1 bridge not built)" "missing_directive_signature"
if [ -f "$AOS_CALLED_LOG" ]; then
  echo "  FAIL: aos CLI was invoked even though the signature was null -- must never happen"
  fail=$((fail + 1))
else
  echo "  PASS: aos CLI was never invoked when the signature was null"
  pass=$((pass + 1))
fi

echo ""
echo "== verify-stable-gate.sh: real aos directive verify contract, mocked result =="

MATCHING_PAYLOAD="$(matching_payload_text)"

set_response_one "success" "$MATCHING_PAYLOAD"
set_aos_mode "ok"
assert_passes "matching payload + aos directive verify ok -> PASS"

set_response_one "success" "$MATCHING_PAYLOAD"
set_aos_mode "refused"
assert_refused "matching payload + aos directive verify refused -> refused" "directive_verify_failed"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
