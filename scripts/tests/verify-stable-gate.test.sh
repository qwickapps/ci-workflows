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
#   1 success check run, payload repo/app_name/sha/stage mismatch
#                                       -> refused
#   1 success check run, payload matches, but the GitHub-Actions-run
#     binding fails (wrong creating app, malformed external_id, run
#     head_sha/repo mismatch, run not completed, run never referenced
#     deploy-app.yml)                  -> refused (aos#193 review finding
#                                          #1, BLOCKER, round 2)
#   1 success check run, payload matches, binding verified, no
#     directive_payload/signature/body (today's expected state -- the
#     aos#193 §1 signing bridge isn't built)
#                                       -> refused, WITHOUT ever invoking aos
#   1 success check run, payload matches, binding verified, aos directive
#     verify says ok                   -> PASS
#   1 success check run, payload matches, binding verified, aos directive
#     verify says refused              -> refused
#
# The mock `gh`/`aos` binaries are fixed scripts written once; each
# scenario configures them via a JSON response file and an env var rather
# than regenerating shell-embedded heredocs per scenario, so no scenario
# payload ever has to survive double shell/JSON quoting.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
SUT="$SCRIPTS_DIR/verify-stable-gate.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0
mkdir -p "$TMPDIR/bin"

REPO="qwickapps/demo"
APP_NAME="demo"
SHA="0123456789abcdef0123456789abcdef01234567"
RUN_ID="99887766"
RUN_ATTEMPT="1"
EXTERNAL_ID="${RUN_ID}-${RUN_ATTEMPT}"
WORKFLOW_PATH="qwickapps/ci-workflows/.github/workflows/deploy-app.yml@refs/heads/main"
RESPONSE_FILE="$TMPDIR/gh-check-runs-response.json"
RUN_RESPONSE_FILE="$TMPDIR/gh-run-response.json"
AOS_MODE_FILE="$TMPDIR/aos-mode"
AOS_CALLED_LOG="$TMPDIR/aos-called.log"
AOS_ARGS_LOG="$TMPDIR/aos-args.log"

# A default, fully-legitimate "actions/runs/{id}" response -- the run that
# (per external_id) created the check run being verified. Individual
# scenarios below overwrite $RUN_RESPONSE_FILE to break one field at a
# time.
write_valid_run_response() {
  jq -nc --arg sha "$SHA" --arg repo "$REPO" --arg wf "$WORKFLOW_PATH" '{
    head_sha: $sha,
    repository: {full_name: $repo},
    status: "completed",
    conclusion: "success",
    referenced_workflows: [{path: $wf, sha: "deadbeef", ref: "refs/heads/main"}]
  }' > "$RUN_RESPONSE_FILE"
}
write_valid_run_response

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
  *actions/runs/*)
    cat "$RUN_RESPONSE_FILE"
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
printf '%s\n' "\$*" >> "$AOS_ARGS_LOG"
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
  # serialized -- pass "" to omit output.text entirely), $3 = app.slug
  # (default "github-actions"), $4 = external_id (default $EXTERNAL_ID)
  local conclusion="$1" text="$2" app_slug="${3:-github-actions}" ext_id="${4:-$EXTERNAL_ID}"
  if [ -z "$text" ]; then
    jq -nc --arg c "$conclusion" --arg slug "$app_slug" --arg eid "$ext_id" \
      '{total_count: 1, check_runs: [{conclusion: $c, output: {}, app: {slug: $slug}, external_id: $eid}]}' > "$RESPONSE_FILE"
  else
    jq -nc --arg c "$conclusion" --arg t "$text" --arg slug "$app_slug" --arg eid "$ext_id" \
      '{total_count: 1, check_runs: [{conclusion: $c, output: {text: $t}, app: {slug: $slug}, external_id: $eid}]}' > "$RESPONSE_FILE"
  fi
}

matching_payload_text() {
  jq -nc --arg repo "$REPO" --arg app "$APP_NAME" --arg sha "$SHA" '{
    repo: $repo, app_name: $app, sha: $sha, stage: "live", e2e_digest: "sha256:deadbeef",
    directive_payload: "{\"from\":\"prime\"}", directive_signature: "armored-sig", directive_body: "body text"
  }'
}

set_aos_mode() { printf '%s' "$1" > "$AOS_MODE_FILE"; }

run_sut() {
  local out_file="$1"
  rm -f "$AOS_CALLED_LOG" "$AOS_ARGS_LOG"
  (
    export PATH="$TMPDIR/bin:$PATH"
    bash "$SUT" --github-token irrelevant --repo "$REPO" --app-name "$APP_NAME" --sha "$SHA"
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

WRONG_STAGE_PAYLOAD="$(jq -nc --arg repo "$REPO" --arg app "$APP_NAME" --arg sha "$SHA" '{repo: $repo, app_name: $app, sha: $sha, stage: "uat"}')"
set_response_one "success" "$WRONG_STAGE_PAYLOAD"
assert_refused "stage != 'live' in embedded payload -> refused" "payload_stage_mismatch"

# aos#193 review mutation gap: removing the sha-payload check from
# verify-stable-gate.sh (i.e. no longer verifying that the directive's
# signed payload's sha matches the commit actually being deployed) must
# turn a test red -- this scenario, using a well-formed payload that
# matches on everything EXCEPT sha, is exactly that test.
WRONG_SHA_PAYLOAD="$(jq -nc --arg repo "$REPO" --arg app "$APP_NAME" '{repo: $repo, app_name: $app, sha: "ffffffffffffffffffffffffffffffffffffff", stage: "live"}')"
set_response_one "success" "$WRONG_SHA_PAYLOAD"
assert_refused "sha mismatch in embedded payload (record is for a DIFFERENT commit than the one actually being deployed) -> refused" "payload_sha_mismatch"

WRONG_APP_PAYLOAD="$(jq -nc --arg repo "$REPO" --arg sha "$SHA" '{repo: $repo, app_name: "some-other-app", sha: $sha, stage: "live"}')"
set_response_one "success" "$WRONG_APP_PAYLOAD"
assert_refused "app_name mismatch in embedded payload (a DIFFERENT app's approval on the same commit) -> refused (aos#193 review finding #5)" "payload_app_name_mismatch"

echo ""
echo "== verify-stable-gate.sh: GitHub-Actions-API binding (aos#193 review finding #1, BLOCKER, round 2) =="

MATCHING_PAYLOAD="$(matching_payload_text)"

write_valid_run_response
set_response_one "success" "$MATCHING_PAYLOAD" "some-other-app" "$EXTERNAL_ID"
assert_refused "check run created by an app other than github-actions -> refused (self-reported text is never trusted)" "check_run_app_mismatch"

write_valid_run_response
set_response_one "success" "$MATCHING_PAYLOAD" "github-actions" "not-a-run-id"
assert_refused "malformed external_id (cannot be parsed as <run_id>-<run_attempt>) -> refused" "missing_or_malformed_external_id"

BAD_SHA_RUN="$(jq -nc --arg sha "ffffffffffffffffffffffffffffffffffffff" --arg repo "$REPO" --arg wf "$WORKFLOW_PATH" '{head_sha: $sha, repository: {full_name: $repo}, status: "completed", referenced_workflows: [{path: $wf}]}')"
printf '%s' "$BAD_SHA_RUN" > "$RUN_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "the run named by external_id has a DIFFERENT head_sha than the commit being deployed -> refused" "run_head_sha_mismatch"

BAD_REPO_RUN="$(jq -nc --arg sha "$SHA" --arg repo "qwickapps/some-other-repo" --arg wf "$WORKFLOW_PATH" '{head_sha: $sha, repository: {full_name: $repo}, status: "completed", referenced_workflows: [{path: $wf}]}')"
printf '%s' "$BAD_REPO_RUN" > "$RUN_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "the run named by external_id belongs to a DIFFERENT repo -> refused" "run_repository_mismatch"

IN_PROGRESS_RUN="$(jq -nc --arg sha "$SHA" --arg repo "$REPO" --arg wf "$WORKFLOW_PATH" '{head_sha: $sha, repository: {full_name: $repo}, status: "in_progress", referenced_workflows: [{path: $wf}]}')"
printf '%s' "$IN_PROGRESS_RUN" > "$RUN_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "the run named by external_id has not completed yet -> refused" "run_not_completed"

NO_REFERENCED_WORKFLOW_RUN="$(jq -nc --arg sha "$SHA" --arg repo "$REPO" '{head_sha: $sha, repository: {full_name: $repo}, status: "completed", referenced_workflows: [{path: "qwickapps/some-other-repo/.github/workflows/totally-unrelated.yml@refs/heads/main"}]}')"
printf '%s' "$NO_REFERENCED_WORKFLOW_RUN" > "$RUN_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "the run named by external_id never referenced deploy-app.yml (forgery attempt -- a DIFFERENT workflow's run trying to claim this record) -> refused (aos#193 review finding #1)" "run_did_not_reference_deploy_app_workflow"

EMPTY_REFERENCED_WORKFLOWS_RUN="$(jq -nc --arg sha "$SHA" --arg repo "$REPO" '{head_sha: $sha, repository: {full_name: $repo}, status: "completed", referenced_workflows: []}')"
printf '%s' "$EMPTY_REFERENCED_WORKFLOWS_RUN" > "$RUN_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "the run named by external_id references no reusable workflows at all -> refused" "run_did_not_reference_deploy_app_workflow"

write_valid_run_response

echo ""
echo "== verify-stable-gate.sh: missing directive signature (today's expected state) =="

NO_SIG_PAYLOAD="$(jq -nc --arg repo "$REPO" --arg app "$APP_NAME" --arg sha "$SHA" '{
  repo: $repo, app_name: $app, sha: $sha, stage: "live", e2e_digest: "sha256:x",
  directive_payload: null, directive_signature: null, directive_body: null
}')"
set_response_one "success" "$NO_SIG_PAYLOAD"
set_aos_mode "ok"
assert_refused "null directive_payload/signature/body -> refused closed, WITHOUT invoking aos (aos#193 §1 bridge not built) -- only reached once the run binding above already passed" "missing_directive_signature"
if [ -f "$AOS_CALLED_LOG" ]; then
  echo "  FAIL: aos CLI was invoked even though the signature was null -- must never happen"
  fail=$((fail + 1))
else
  echo "  PASS: aos CLI was never invoked when the signature was null"
  pass=$((pass + 1))
fi

echo ""
echo "== verify-stable-gate.sh: real aos directive verify contract, mocked result =="

set_response_one "success" "$MATCHING_PAYLOAD"
set_aos_mode "ok"
assert_passes "matching payload + verified binding + aos directive verify ok -> PASS"

set_response_one "success" "$MATCHING_PAYLOAD"
set_aos_mode "refused"
assert_refused "matching payload + verified binding + aos directive verify refused -> refused" "directive_verify_failed"

echo ""
echo "== verify-stable-gate.sh: --require-signer is always hardcoded at the call site, never droppable (aos#193 review finding #5 mutation gap) =="

set_response_one "success" "$MATCHING_PAYLOAD"
set_aos_mode "ok"
OUT="$TMPDIR/out-require-signer"
run_sut "$OUT"
if [ -f "$AOS_ARGS_LOG" ] && grep -qE -- "--require-signer prime" "$AOS_ARGS_LOG" && grep -qE -- "--as ci-workflows-stable-gate" "$AOS_ARGS_LOG"; then
  echo "  PASS: the real aos invocation included --require-signer prime --as ci-workflows-stable-gate"
  pass=$((pass + 1))
else
  echo "  FAIL: --require-signer prime / --as ci-workflows-stable-gate missing from the actual aos invocation"
  echo "    logged args: $(cat "$AOS_ARGS_LOG" 2>/dev/null || echo '<no log>')"
  fail=$((fail + 1))
fi

echo ""
echo "== verify-stable-gate.sh: AOS_MANIFEST/AOS_ENVIRONMENT_ROOT isolation (aos#193 review finding #4) =="

# A stand-in "aos" that only proves whether ambient AOS_MANIFEST /
# AOS_ENVIRONMENT_ROOT leaked into its environment, rather than actually
# verifying anything -- proves the isolation independent of the
# ok/refused mock above.
cat > "$TMPDIR/bin/aos" <<'MOCK'
#!/usr/bin/env bash
if [ -n "${AOS_MANIFEST:-}" ]; then
  echo '{"ok": false, "check": "manifest_leaked", "reason": "AOS_MANIFEST was inherited from the ambient environment"}'
  exit 3
fi
echo '{"ok": true, "from": "prime", "scope": "test", "target": "ci-workflows-stable-gate"}'
MOCK
chmod +x "$TMPDIR/bin/aos"

set_response_one "success" "$MATCHING_PAYLOAD"
OUT="$TMPDIR/out-manifest-isolation"
set +e
(
  export PATH="$TMPDIR/bin:$PATH"
  export AOS_MANIFEST="/tmp/some-ambient-runner-manifest.yaml"
  bash "$SUT" --github-token irrelevant --repo "$REPO" --app-name "$APP_NAME" --sha "$SHA"
) > "$OUT" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
  echo "  PASS: an ambient \$AOS_MANIFEST set before invoking the script (with no --aos-manifest passed) never reaches the aos call (explicitly unset via env -u)"
  pass=$((pass + 1))
else
  echo "  FAIL: ambient \$AOS_MANIFEST leaked through to the aos invocation"
  sed 's/^/      /' "$OUT"
  fail=$((fail + 1))
fi

echo ""
echo "== verify-stable-gate.sh: --aos-manifest, when passed, IS forwarded as \$AOS_MANIFEST (aos#193 review finding #4) =="

AOS_MANIFEST_SEEN_LOG="$TMPDIR/aos-manifest-seen.log"
cat > "$TMPDIR/bin/aos" <<MOCK
#!/usr/bin/env bash
echo "AOS_MANIFEST=\${AOS_MANIFEST:-<unset>}" >> "$AOS_MANIFEST_SEEN_LOG"
echo '{"ok": true, "from": "prime", "scope": "test", "target": "ci-workflows-stable-gate"}'
MOCK
chmod +x "$TMPDIR/bin/aos"
rm -f "$TMPDIR/aos-manifest-seen.log"

set_response_one "success" "$MATCHING_PAYLOAD"
OUT="$TMPDIR/out-manifest-passthrough"
(
  export PATH="$TMPDIR/bin:$PATH"
  bash "$SUT" --github-token irrelevant --repo "$REPO" --app-name "$APP_NAME" --sha "$SHA" \
    --aos-manifest "/tmp/pinned-prime-manifest.yaml"
) > "$OUT" 2>&1
if grep -qF "AOS_MANIFEST=/tmp/pinned-prime-manifest.yaml" "$TMPDIR/aos-manifest-seen.log" 2>/dev/null; then
  echo "  PASS: --aos-manifest's value was forwarded to the aos call as \$AOS_MANIFEST"
  pass=$((pass + 1))
else
  echo "  FAIL: --aos-manifest's value was not forwarded to the aos call"
  sed 's/^/      /' "$OUT"
  cat "$TMPDIR/aos-manifest-seen.log" 2>/dev/null | sed 's/^/      /'
  fail=$((fail + 1))
fi

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
