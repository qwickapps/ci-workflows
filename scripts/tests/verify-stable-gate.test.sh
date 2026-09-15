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
# Must match verify-stable-gate.sh's own LIVE_APPROVED_CREATING_STEP_NAME
# constant exactly -- the step name the job/step binding check (aos#193
# review finding #1, BLOCKER, round 3) requires to have concluded success.
CREATING_STEP_NAME="Create live-e2e-approved check run (aos#193 Phase 1 §1)"
RESPONSE_FILE="$TMPDIR/gh-check-runs-response.json"
RUN_RESPONSE_FILE="$TMPDIR/gh-run-response.json"
JOBS_RESPONSE_FILE="$TMPDIR/gh-jobs-response.json"
JOBS_QUERY_SHOULD_FAIL="$TMPDIR/jobs-query-should-fail"
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
    event: "push",
    head_branch: "main",
    referenced_workflows: [{path: $wf, sha: "deadbeef", ref: "refs/heads/main"}]
  }' > "$RUN_RESPONSE_FILE"
}
write_valid_run_response

# A default, fully-legitimate "actions/runs/{id}/attempts/{n}/jobs"
# response -- a job named "<caller job> / deploy-caprover" (the
# GitHub-generated name for a job invoked FROM a reusable workflow;
# aos#193 review finding B1, round 4), itself concluded success, whose
# steps include the exact step that creates the live-e2e-approved record,
# also concluded success (aos#193 review finding #1, BLOCKER, round 3:
# binding to "the run referenced deploy-app.yml" alone was not enough --
# a uat run, or a live run whose e2e/approval step failed, also
# referenced it; round 4: "any job in the run" was still not enough -- an
# unrelated sibling job with a copied step name also satisfied it).
# Individual scenarios below overwrite $JOBS_RESPONSE_FILE to prove the
# job/step-binding check independently.
write_valid_jobs_response() {
  jq -nc --arg step "$CREATING_STEP_NAME" '{
    total_count: 1,
    jobs: [
      {
        name: "deploy / deploy-caprover",
        conclusion: "success",
        steps: [
          {name: "Checkout code", conclusion: "success"},
          {name: $step, conclusion: "success"}
        ]
      }
    ]
  }' > "$JOBS_RESPONSE_FILE"
}
write_valid_jobs_response
rm -f "$JOBS_QUERY_SHOULD_FAIL"

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
  *actions/runs/*/attempts/*/jobs*)
    if [ -f "$JOBS_QUERY_SHOULD_FAIL" ]; then
      echo "mock gh: simulated jobs API failure (rate limit / 404 / 5xx)" >&2
      exit 1
    fi
    cat "$JOBS_RESPONSE_FILE"
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
      else [range($count) | {id: (1000 + .), conclusion: "success", output: {}}]
      end
    )
  }' > "$RESPONSE_FILE"
}

set_response_one() {
  # $1 = conclusion, $2 = output.text (a JSON *string* value, already
  # serialized -- pass "" to omit output.text entirely), $3 = app.slug
  # (default "github-actions"), $4 = external_id (default $EXTERNAL_ID),
  # $5 = id (default 5000)
  local conclusion="$1" text="$2" app_slug="${3:-github-actions}" ext_id="${4:-$EXTERNAL_ID}" id="${5:-5000}"
  if [ -z "$text" ]; then
    jq -nc --arg c "$conclusion" --arg slug "$app_slug" --arg eid "$ext_id" --argjson id "$id" \
      '{total_count: 1, check_runs: [{id: $id, conclusion: $c, output: {}, app: {slug: $slug}, external_id: $eid}]}' > "$RESPONSE_FILE"
  else
    jq -nc --arg c "$conclusion" --arg t "$text" --arg slug "$app_slug" --arg eid "$ext_id" --argjson id "$id" \
      '{total_count: 1, check_runs: [{id: $id, conclusion: $c, output: {text: $t}, app: {slug: $slug}, external_id: $eid}]}' > "$RESPONSE_FILE"
  fi
}

set_response_two() {
  # M2 (round 4): two check runs sharing the same name, as a real
  # "Re-run all jobs" produces. $1/$2 = each one's (id, payload_text,
  # app_slug, external_id) as a 4-field colon-free tuple passed via
  # separate positional groups: id1 text1 eid1 id2 text2 eid2.
  local id1="$1" text1="$2" eid1="$3" id2="$4" text2="$5" eid2="$6"
  jq -nc --argjson id1 "$id1" --arg t1 "$text1" --arg eid1 "$eid1" \
         --argjson id2 "$id2" --arg t2 "$text2" --arg eid2 "$eid2" '{
    total_count: 2,
    check_runs: [
      {id: $id1, conclusion: "success", output: {text: $t1}, app: {slug: "github-actions"}, external_id: $eid1},
      {id: $id2, conclusion: "success", output: {text: $t2}, app: {slug: "github-actions"}, external_id: $eid2}
    ]
  }' > "$RESPONSE_FILE"
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
assert_refused "zero check runs -> refused (never approved)" "no_check_run_found"

# aos#193 review finding M2 (round 4): two check runs with no usable
# payload/output at all (as set_response_count's minimal fixture
# produces) must still refuse -- multiplicity alone is no longer the
# refusal reason, but "none of them are valid" still is.
set_response_count 2
assert_refused "two check runs, neither carries a valid payload -> refused" "no_valid_approval_found"

set_response_one "failure" ""
assert_refused "one check run, conclusion=failure -> refused (never even becomes a success candidate)" "no_successful_check_run"

echo ""
echo "== verify-stable-gate.sh: payload cross-checks =="

MISMATCHED_PAYLOAD="$(jq -nc --arg sha "$SHA" '{repo: "qwickapps/OTHER", sha: $sha, stage: "live"}')"
set_response_one "success" "$MISMATCHED_PAYLOAD"
assert_refused "repo mismatch in embedded payload -> refused" "payload_mismatch"

WRONG_STAGE_PAYLOAD="$(jq -nc --arg repo "$REPO" --arg app "$APP_NAME" --arg sha "$SHA" '{repo: $repo, app_name: $app, sha: $sha, stage: "uat"}')"
set_response_one "success" "$WRONG_STAGE_PAYLOAD"
assert_refused "stage != 'live' in embedded payload -> refused" "payload_mismatch"

# aos#193 review mutation gap: removing the sha-payload check from
# verify-stable-gate.sh (i.e. no longer verifying that the directive's
# signed payload's sha matches the commit actually being deployed) must
# turn a test red -- this scenario, using a well-formed payload that
# matches on everything EXCEPT sha, is exactly that test.
WRONG_SHA_PAYLOAD="$(jq -nc --arg repo "$REPO" --arg app "$APP_NAME" '{repo: $repo, app_name: $app, sha: "ffffffffffffffffffffffffffffffffffffff", stage: "live"}')"
set_response_one "success" "$WRONG_SHA_PAYLOAD"
assert_refused "sha mismatch in embedded payload (record is for a DIFFERENT commit than the one actually being deployed) -> refused" "payload_mismatch"

WRONG_APP_PAYLOAD="$(jq -nc --arg repo "$REPO" --arg sha "$SHA" '{repo: $repo, app_name: "some-other-app", sha: $sha, stage: "live"}')"
set_response_one "success" "$WRONG_APP_PAYLOAD"
assert_refused "app_name mismatch in embedded payload (a DIFFERENT app's approval on the same commit) -> refused (aos#193 review finding #5)" "payload_mismatch"

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

NO_REFERENCED_WORKFLOW_RUN="$(jq -nc --arg sha "$SHA" --arg repo "$REPO" '{head_sha: $sha, repository: {full_name: $repo}, status: "completed", event: "push", head_branch: "main", referenced_workflows: [{path: "qwickapps/some-other-repo/.github/workflows/totally-unrelated.yml@refs/heads/main"}]}')"
printf '%s' "$NO_REFERENCED_WORKFLOW_RUN" > "$RUN_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "the run named by external_id never referenced deploy-app.yml (forgery attempt -- a DIFFERENT workflow's run trying to claim this record) -> refused (aos#193 review finding #1)" "run_did_not_reference_deploy_app_workflow"

EMPTY_REFERENCED_WORKFLOWS_RUN="$(jq -nc --arg sha "$SHA" --arg repo "$REPO" '{head_sha: $sha, repository: {full_name: $repo}, status: "completed", event: "push", head_branch: "main", referenced_workflows: []}')"
printf '%s' "$EMPTY_REFERENCED_WORKFLOWS_RUN" > "$RUN_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "the run named by external_id references no reusable workflows at all -> refused" "run_did_not_reference_deploy_app_workflow"

write_valid_run_response
write_valid_jobs_response

echo ""
echo "== verify-stable-gate.sh: GitHub-Actions-API binding round 3 (aos#193 review finding #1, BLOCKER, round 3) =="
echo "   B1: 'the run referenced deploy-app.yml on this sha' was not enough -- a"
echo "   uat run, or a live run whose e2e/approval failed before the record-"
echo "   creating step, referenced it too. Also pin the ref, not just the path"
echo "   prefix."

# B1a: wrong ref. Path prefix matches, but the run used a DIFFERENT ref
# than production callers actually use ("@main" -> refs/heads/main) -- a
# branch, a fork, or an attacker-controlled ref. This scenario used to pass
# before the ref pin (round 2's `startswith($prefix)` alone was not
# enough).
WRONG_REF_RUN="$(jq -nc --arg sha "$SHA" --arg repo "$REPO" '{head_sha: $sha, repository: {full_name: $repo}, status: "completed", event: "push", head_branch: "main", referenced_workflows: [{path: "qwickapps/ci-workflows/.github/workflows/deploy-app.yml@refs/heads/evil", ref: "refs/heads/evil"}]}')"
printf '%s' "$WRONG_REF_RUN" > "$RUN_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "the run referenced deploy-app.yml, but from a DIFFERENT ref than production callers use -> refused (ref pinning)" "run_did_not_reference_deploy_app_workflow_at_expected_ref"
write_valid_run_response

# B1b: forged external_id pointing at a genuine, same-sha, same-ref run
# that simply never reached the record-creating step -- for example a uat
# stage run (deploy-app.yml only creates this check run on the LIVE
# stage). The run/ref checks above all pass; only the job/step binding
# below can catch this.
JOBS_NO_MATCHING_STEP="$(jq -nc '{jobs: [{name: "deploy-caprover", steps: [{name: "Checkout code", conclusion: "success"}, {name: "Resolve CapRover credentials", conclusion: "success"}]}]}')"
printf '%s' "$JOBS_NO_MATCHING_STEP" > "$JOBS_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "the referenced run never actually ran the record-creating step (e.g. a uat run on the same sha) -> refused (job/step binding)" "run_did_not_execute_expected_step"
write_valid_jobs_response

# B1c: the record-creating step DID run, in the referenced run, but it
# FAILED -- for example a live run whose e2e passed but the check-run
# creation step itself errored on a transient GitHub issue, and a
# different, forged check run for the SAME run_id/attempt is being
# presented as if it were legitimate. The step existing is not enough; it
# must have concluded success.
JOBS_STEP_FAILED="$(jq -nc --arg step "$CREATING_STEP_NAME" '{jobs: [{name: "deploy-caprover", steps: [{name: "Checkout code", conclusion: "success"}, {name: $step, conclusion: "failure"}]}]}')"
printf '%s' "$JOBS_STEP_FAILED" > "$JOBS_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "the record-creating step ran in the referenced run but did not conclude success -> refused" "run_did_not_execute_expected_step"
write_valid_jobs_response

# B2 (fail-CLOSED on an unverifiable binding, mirrored here for the single-
# record case): a rate-limited/failed jobs-API query must refuse, exactly
# like a failed runs-API query already does -- never be silently treated
# as "the step didn't run".
printf '%s' "1" > "$JOBS_QUERY_SHOULD_FAIL"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "jobs-API query itself fails (rate limit / 404 / 5xx) -> refused closed, never treated as 'step absent'" "jobs_query_failed"
rm -f "$JOBS_QUERY_SHOULD_FAIL"

# Mutation-coverage proof: loosening the path-prefix match to a bare
# `contains("deploy-app")` (round 3's exact reviewer-cited bypass) must
# stay caught by the ref pin even if the prefix check were somehow
# loosened -- this scenario's path already starts with the real prefix,
# so it isolates the ref check specifically.
CORRECT_PREFIX_WRONG_REF_RUN="$(jq -nc --arg sha "$SHA" --arg repo "$REPO" '{head_sha: $sha, repository: {full_name: $repo}, status: "completed", event: "push", head_branch: "main", referenced_workflows: [{path: "qwickapps/ci-workflows/.github/workflows/deploy-app.yml@refs/heads/attacker-controlled", ref: "refs/heads/attacker-controlled"}]}')"
printf '%s' "$CORRECT_PREFIX_WRONG_REF_RUN" > "$RUN_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "path prefix matches exactly but ref does not -> refused (proves the ref check is independent of the prefix check)" "run_did_not_reference_deploy_app_workflow_at_expected_ref"

write_valid_run_response
write_valid_jobs_response

echo ""
echo "== verify-stable-gate.sh: GitHub-Actions-API binding round 4 (aos#193 review finding B1, BLOCKER, round 4) =="
echo "   'a job in the run has the expected step, succeeded' was STILL not"
echo "   enough -- a sibling job, or a run triggered any way other than"
echo "   push/workflow_dispatch on the default branch, also satisfied it."

# B1 round 4a: the referenced run's event is pull_request (an
# attacker-controlled PR branch), not push/workflow_dispatch. Everything
# else about the run is otherwise valid.
PR_EVENT_RUN="$(jq -nc --arg sha "$SHA" --arg repo "$REPO" --arg wf "$WORKFLOW_PATH" '{head_sha: $sha, repository: {full_name: $repo}, status: "completed", event: "pull_request", head_branch: "attacker", referenced_workflows: [{path: $wf, ref: "refs/heads/main"}]}')"
printf '%s' "$PR_EVENT_RUN" > "$RUN_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "the referenced run's event is pull_request (attacker-controlled branch), not push/workflow_dispatch -> refused" "run_event_not_allowed"
write_valid_run_response

# B1 round 4b: the referenced run's event IS push, but its head_branch is
# NOT the default branch -- a forging workflow pushed to a scratch branch
# rather than merged to main.
NON_DEFAULT_BRANCH_RUN="$(jq -nc --arg sha "$SHA" --arg repo "$REPO" --arg wf "$WORKFLOW_PATH" '{head_sha: $sha, repository: {full_name: $repo}, status: "completed", event: "push", head_branch: "scratch-branch", referenced_workflows: [{path: $wf, ref: "refs/heads/main"}]}')"
printf '%s' "$NON_DEFAULT_BRANCH_RUN" > "$RUN_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "the referenced run is push, but NOT on the default branch (main) -> refused" "run_head_branch_not_default"
write_valid_run_response

# B1 round 4c: the exact failure scenario the reviewer demonstrated --
# the record-creating step's name is copied into an UNRELATED SIBLING
# job (e.g. "forge"), which succeeds, while deploy-app.yml's own
# deploy-caprover job in the SAME run fails. Everything about the run
# itself (event, branch, ref, sha) is legitimate.
JOBS_STEP_IN_SIBLING_JOB="$(jq -nc --arg step "$CREATING_STEP_NAME" '{
  total_count: 2,
  jobs: [
    {name: "deploy / resolve-stage", conclusion: "failure", steps: [{name: "Resolve stage", conclusion: "failure"}]},
    {name: "forge", conclusion: "success", steps: [{name: "Checkout code", conclusion: "success"}, {name: $step, conclusion: "success"}]}
  ]
}')"
printf '%s' "$JOBS_STEP_IN_SIBLING_JOB" > "$JOBS_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "the record-creating step succeeded, but in an UNRELATED SIBLING job, not deploy-app.yml's own deploy-caprover job -> refused (this is the reviewer's exact round-4 forgery scenario)" "run_did_not_execute_expected_step"
write_valid_jobs_response

# B1 round 4d: the step is inside a job correctly named "*/ deploy-caprover",
# and the STEP itself succeeded, but the JOB's own overall conclusion is
# "failure" (some other step in the same job broke). The step's own
# success is not enough; the review specifically also requires the job's
# conclusion.
JOBS_MATCHING_JOB_BUT_JOB_FAILED="$(jq -nc --arg step "$CREATING_STEP_NAME" '{
  total_count: 1,
  jobs: [
    {name: "deploy / deploy-caprover", conclusion: "failure", steps: [{name: "Checkout code", conclusion: "success"}, {name: $step, conclusion: "success"}, {name: "Some later step", conclusion: "failure"}]}
  ]
}')"
printf '%s' "$JOBS_MATCHING_JOB_BUT_JOB_FAILED" > "$JOBS_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "the record-creating step succeeded inside the right job, but that job's OWN overall conclusion is failure -> refused" "run_did_not_execute_expected_step"
write_valid_jobs_response

echo ""
echo "== verify-stable-gate.sh: jobs-API pagination (aos#193 review finding M1, MEDIUM, round 4) =="

# M1: total_count says more jobs exist than were actually returned on this
# page -- the record-creating job/step could be on an unfetched page.
# Must be treated as could-not-verify (hard failure), never as "the step
# is absent".
JOBS_TRUNCATED_PAGE="$(jq -nc '{
  total_count: 35,
  jobs: [range(30) | {name: ("job-" + (. | tostring)), conclusion: "success", steps: [{name: "Checkout code", conclusion: "success"}]}]
}')"
printf '%s' "$JOBS_TRUNCATED_PAGE" > "$JOBS_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "jobs response is truncated (total_count=35, only 30 returned) -> refused closed, never guessed as 'step absent'" "jobs_pagination_incomplete"
write_valid_jobs_response

echo ""
echo "== verify-stable-gate.sh: non-object JSON responses (aos#193 review finding L1, LOW, round 4) =="

# L1: a 2xx body that is valid JSON but not an OBJECT (a bare string, for
# example) would otherwise make every field read below silently resolve
# to "", hitting the ordinary mismatch path (refused) instead of
# could-not-verify.
printf '%s' '"just a string, not an object"' > "$RUN_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "run-lookup response is valid JSON but not an object -> could-not-verify, not a guessed mismatch" "run_query_failed"
write_valid_run_response

printf '%s' '"also just a string"' > "$JOBS_RESPONSE_FILE"
set_response_one "success" "$MATCHING_PAYLOAD"
assert_refused "jobs-lookup response is valid JSON but not an object -> could-not-verify, not a guessed mismatch" "jobs_query_failed"
write_valid_jobs_response

echo ""
echo "== verify-stable-gate.sh: reruns create a second, equally legitimate record (aos#193 review finding M2, MEDIUM, round 4) =="
echo "   Requiring uniqueness used to make a routine 'Re-run all jobs' on an"
echo "   already-approved live run permanently refuse stable for that sha."

# M2a: two check runs on the same sha, both fully legitimate (as a real
# rerun produces) -- must PASS, deterministically selecting the newest
# (highest id).
OLDER_ID=6000
NEWER_ID=7000
set_response_two "$OLDER_ID" "$MATCHING_PAYLOAD" "$EXTERNAL_ID" "$NEWER_ID" "$MATCHING_PAYLOAD" "$EXTERNAL_ID"
assert_passes "two check runs from a rerun, BOTH fully legitimate -> PASS (does not refuse merely for existing twice)"

# M2b: two check runs -- the OLDER one is legitimate, the NEWER one has a
# mismatched payload (e.g. a stray/irrelevant check run created later for
# a different purpose). Must still find and use the older, valid one, not
# just look at the newest and give up.
STALE_MISMATCHED_PAYLOAD="$(jq -nc --arg sha "$SHA" '{repo: "qwickapps/OTHER", sha: $sha, stage: "live"}')"
set_response_two "$OLDER_ID" "$MATCHING_PAYLOAD" "$EXTERNAL_ID" "$NEWER_ID" "$STALE_MISMATCHED_PAYLOAD" "not-a-run-id"
assert_passes "newest candidate is invalid, but an older one is fully legitimate -> PASS (falls through to the older valid one)"

# M2c mutation-coverage proof: if the newest candidate had a legitimate
# PAYLOAD but its binding genuinely fails (not a could-not-verify), the
# gate must still try the older one rather than stopping at the first
# payload match regardless of binding.
BAD_BINDING_EXTERNAL_ID="not-a-run-id"
set_response_two "$OLDER_ID" "$MATCHING_PAYLOAD" "$EXTERNAL_ID" "$NEWER_ID" "$MATCHING_PAYLOAD" "$BAD_BINDING_EXTERNAL_ID"
assert_passes "newest candidate's payload matches but its own binding is malformed -> PASS (falls through to the older, properly-bound one)"

write_valid_run_response
write_valid_jobs_response

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
