#!/usr/bin/env bash
#
# check-run-binding.sh -- shared "who actually created this check run"
# binding verification for aos#193 Phase 1 blue-green records
# (scripts/verify-stable-gate.sh's live-e2e-approved read, and
# scripts/check-first-deploy-proof.sh's first-deploy-used read).
#
# aos#193 review finding #1 (BLOCKER, round 2): both readers used to accept
# a check-run record as legitimate if its own SELF-REPORTED
# `output.text.workflow_ref` field started with
# "qwickapps/ci-workflows/.github/workflows/deploy-app.yml@". That was
# broken two ways, both with real repros from the review:
#
#   - The writer (create-blue-green-check-run.sh's callers in
#     deploy-app.yml) recorded `${{ github.workflow_ref }}` -- but INSIDE a
#     reusable workflow, the `github` context belongs to the CALLER, never
#     to deploy-app.yml itself. A real record's workflow_ref therefore
#     looks like "qwickapps/mcp/.github/workflows/deploy.yml@refs/heads/
#     main", which never matches the expected ci-workflows/deploy-app.yml
#     prefix -- so a real, legitimate record was ALWAYS rejected.
#   - `workflow_ref` is just a string inside `output.text`, which the
#     creating step fully controls. Any workflow in the caller repo with
#     `checks: write` could simply type the exact expected prefix and pass
#     the binding check trivially, regardless of what it actually ran.
#
# aos#193 review finding #1 (BLOCKER B1, round 3): binding to
# "some run referenced deploy-app.yml@<any ref> on this sha" was STILL not
# enough. `external_id` is chosen entirely by the record's CREATOR (it is
# just an argument create-blue-green-check-run.sh's caller passes), so any
# same-repo workflow with `checks: write` could create a record and point
# `external_id` at a legitimate, unrelated deploy-app run on the same sha
# (a uat run, or a failed live run) and the binding passed. Two more facts
# now have to hold, both independently verified via the API:
#
#   - The referenced run must have used the EXACT ref deploy-app.yml is
#     actually called from in production ("@main" -> refs/heads/main), not
#     merely a path prefix ending at "deploy-app.yml@" -- a run against
#     "deploy-app.yml@refs/heads/evil" used to pass.
#   - The run must have a JOB that actually executed the SPECIFIC STEP
#     which creates this record (see expected_step_name below), and that
#     step must have concluded "success" -- not just "the run touched
#     deploy-app.yml somewhere, for any reason, with any outcome". A
#     legitimate uat run, or a live run whose e2e failed before ever
#     reaching the check-run-creating step, used to pass.
#
# The fix binds to data GITHUB ITSELF controls, independently verified via
# the API, never to any text embedded in the record:
#
#   1. The check run must have been created by the standard Actions token
#      (`check_run.app.slug == "github-actions"`), not some other
#      installed GitHub App.
#   2. `check_run.external_id` (recorded verbatim by
#      create-blue-green-check-run.sh's callers as
#      "${{ github.run_id }}-${{ github.run_attempt }}") must parse as
#      "<run_id>-<run_attempt>".
#   3. `GET /repos/{repo}/actions/runs/{run_id}` must succeed, and that
#      run's:
#        - head_sha              == the sha being deployed
#        - repository.full_name  == the expected caller repo
#        - status                == "completed" (the run that created this
#          record must have actually finished -- a still-in-progress run
#          is not yet a settled fact to bind to)
#        - referenced_workflows[] must contain an entry whose `path`
#          starts with "qwickapps/ci-workflows/.github/workflows/
#          deploy-app.yml@" AND whose `ref` equals exactly
#          CHECK_RUN_BINDING_WORKFLOW_REF -- this is the actual,
#          GitHub-verified proof that the run which created this record
#          executed THIS reusable workflow FROM THE EXPECTED REF, not
#          merely claimed to in a text field it fully controls, and not
#          some other branch of ci-workflows a compromised or malicious
#          caller-repo workflow could point at.
#   4. `GET /repos/{repo}/actions/runs/{run_id}/attempts/{run_attempt}/jobs`
#      must succeed, and at least one job in that attempt must have a step
#      whose `name` equals `expected_step_name` (the exact step that
#      actually creates this record -- callers pass a different value for
#      the live-e2e-approved record than for the first-deploy-used record,
#      since they're created by different steps) with `conclusion ==
#      "success"`. A run that merely referenced deploy-app.yml (e.g. a uat
#      stage run, or a live run whose e2e/approval failed before reaching
#      the record-creating step) does not have this, and is refused.
#
# `check_run.conclusion` is intentionally NOT re-checked against a fixed
# "success" here: the specific check-run being verified already carries
# its own conclusion (checked by the caller before this function ever
# runs), and other, unrelated steps later in the SAME caller job could
# fail for reasons that have nothing to do with the record's own
# legitimacy -- requiring the whole run's or whole job's conclusion to be
# "success" would make this stricter than the thing it's actually trying
# to prove. Binding to the SPECIFIC step's own conclusion (point 4 above)
# is the precise, not-too-strict, not-too-loose version of that same idea.
#
# aos#193 review finding B1 (BLOCKER, round 4): round 3's fix -- "a job in
# the referenced run has the expected step, succeeded" -- was STILL not
# enough. Demonstrated: a workflow on sha X with one job that calls
# deploy-app.yml@main (and may let that job fail) plus a SECOND, unrelated
# job containing a step with the exact same name, succeeding, satisfied
# the binding -- with no real e2e/approval anywhere. Nothing tied the step
# to deploy-app.yml's OWN job, and the run's trigger (event/branch) was
# never checked, so a pull_request run on an attacker-controlled branch
# could also qualify. Three more facts now have to hold:
#
#   - The run's `event` must be "push" or "workflow_dispatch" -- a
#     pull_request (or any other event) run is never eligible, closing the
#     "attacker-controlled PR branch" angle.
#   - The run's `head_branch` must be the repo's default branch
#     (CHECK_RUN_BINDING_DEFAULT_BRANCH) -- a forging workflow must
#     therefore already be MERGED to main to have any chance of binding,
#     not just opened as a PR or pushed to a scratch branch.
#   - The expected step must be found inside a job whose `name` ends with
#     " / deploy-caprover" (the GitHub-generated name for a job called
#     FROM a reusable workflow: "<calling job id> / <called job id>") --
#     never just "any job, anywhere in the run" -- AND that job's own
#     `conclusion` must be "success", not just the individual step's.
#
# aos#193 review finding M1 (MEDIUM, round 4): the jobs-API call had no
# `per_page`, so the default page size (30) silently truncated the
# response for any run with more jobs than that -- a real run whose
# record-creating step existed but sat on a later page returned 1
# (refused) instead of 2 (could not verify), which callers then read as
# "not a marker" rather than failing closed. Fixed by requesting
# per_page=100 and independently checking `total_count` against the
# actual number of jobs returned; a truncated response returns 2, never a
# guessed 1.
#
# aos#193 review finding L1 (LOW, round 4): a 2xx response body that is
# valid JSON but NOT an object (for example a bare JSON string) made the
# `.head_sha`/etc. jq reads silently resolve to "", which then hit the
# ordinary mismatch path and returned 1 (refused) instead of 2 (could not
# verify) -- "every API error path returns 2" did not actually hold.
# Fixed by explicitly requiring `type == "object"` on both the run
# response and the jobs response before reading any field out of them.
#
# aos#193 review finding #2 (BLOCKER B2, round 3): callers used to treat
# EVERY failure reason from this function identically -- "not a valid
# marker, keep looking / conclude absent" -- including failures that mean
# "the API could not be reached / the run has not settled yet", which is
# NOT the same claim as "this candidate is definitively not a match".
# Treating a rate-limited or still-in-progress lookup as "absent" let an
# attacker (or, just as easily, a routine GitHub outage) silently make a
# real single-use marker disappear exactly when GitHub was degraded.
#
# This function now signals the difference via its exit status:
#   0 - binding holds: this check run really was created by the step
#       named, in a completed run, on the expected ref, on this sha.
#   1 - binding DEFINITIVELY does not hold (a structural mismatch: wrong
#       app, malformed external_id, wrong sha/repo/ref/path, or the run
#       completed but never ran the expected step successfully). Safe for
#       a caller to treat as "this candidate is not a valid marker" and
#       keep looking, or conclude "no marker exists" once all candidates
#       are exhausted.
#   2 - COULD NOT VERIFY (the runs/jobs API call itself failed -- rate
#       limit, 5xx, a deleted run returning 404, non-JSON -- or the
#       creating run has not finished yet). This is NOT evidence of
#       absence. A caller MUST treat this as a hard failure (refuse to
#       proceed / exit non-zero), never silently as "marker not found".
#
# Usage (after `export GH_TOKEN=...`, same convention as the callers):
#   source scripts/lib/check-run-binding.sh
#   check_run_binding_verify "<owner>/<repo>" "<sha>" "<app-slug>" "<external-id>" "<expected-step-name>"
#   case $? in
#     0) ... ;;                          # binding holds
#     1) ... # definitively not a match, keep looking / absent
#     2) ... # could not verify -- fail closed, do not treat as absent
#   esac
# Never exits the calling shell; only returns 0/1/2.

set -euo pipefail
# NOTE: this file is `source`d into verify-stable-gate.sh and
# check-first-deploy-proof.sh, both of which already set these same flags
# before sourcing it -- keep this line as `-euo pipefail` (never relax
# it to just `-uo`), since `set` in a sourced file changes the CALLING
# shell's options for the rest of its execution, not just this file's.
# Every external command call below is already the direct condition of an
# `if`/`if !`, which bash exempts from `errexit` regardless of this flag;
# `return 1`/`return 2` statements are not themselves subject to errexit
# either. So `-e` staying on here is both safe internally and required to
# avoid silently disabling the callers' own fail-fast behavior.

CHECK_RUN_BINDING_WORKFLOW_PATH_PREFIX="qwickapps/ci-workflows/.github/workflows/deploy-app.yml@"
# All production callers invoke deploy-app.yml as
# "qwickapps/ci-workflows/.github/workflows/deploy-app.yml@main" (verified
# against every current caller, e.g. qwickapps/mcp's deploy.yml:565). The
# GitHub Actions API's own `referenced_workflows[].ref` field reports this
# as the resolved git ref "refs/heads/main", not the bare "@main" the
# `uses:` line spells. Pin to that exact resolved value -- a run that
# referenced deploy-app.yml from any OTHER ref (a branch, a fork, a
# malicious or stale ref) must never bind, even though its `path` prefix
# would otherwise match.
CHECK_RUN_BINDING_WORKFLOW_REF="refs/heads/main"
# aos#193 review finding B1 (round 4): the binding also requires the
# creating run's `head_branch` to be exactly this -- the repo's default
# branch -- so a forging workflow must already be merged to main.
CHECK_RUN_BINDING_DEFAULT_BRANCH="main"
# aos#193 review finding B1 (round 4): the record-creating step must sit
# inside a job whose GitHub-generated name has this suffix -- the
# "<calling job id> / <called job id>" shape GitHub assigns to a job
# invoked FROM a reusable workflow. deploy-app.yml's own job that creates
# both blue-green check runs is "deploy-caprover".
CHECK_RUN_BINDING_JOB_NAME_SUFFIX=" / deploy-caprover"

check_run_binding_verify() {
  local repo="$1" sha="$2" app_slug="$3" external_id="$4" expected_step_name="$5"

  if [ "$app_slug" != "github-actions" ]; then
    echo "::error::check-run binding REFUSED (check_run_app_mismatch): creating app.slug='${app_slug}', expected 'github-actions' -- a check run created by any other GitHub App is never a legitimate blue-green record, no matter what its output.text claims" >&2
    return 1
  fi

  if [[ ! "$external_id" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    echo "::error::check-run binding REFUSED (missing_or_malformed_external_id): external_id='${external_id}', expected '<run_id>-<run_attempt>' -- cannot look up the creating run without it" >&2
    return 1
  fi
  local run_id="${BASH_REMATCH[1]}"
  local run_attempt="${BASH_REMATCH[2]}"

  local run_response
  if ! run_response="$(gh api "repos/${repo}/actions/runs/${run_id}" 2>&1)"; then
    echo "::error::check-run binding COULD NOT VERIFY (run_query_failed): could not query repos/${repo}/actions/runs/${run_id}: ${run_response:-<no output>} -- this is NOT evidence the record is illegitimate; callers must fail closed, not treat this as absence" >&2
    return 2
  fi
  if ! printf '%s' "$run_response" | jq -e . >/dev/null 2>&1; then
    echo "::error::check-run binding COULD NOT VERIFY (run_query_failed): non-JSON response from repos/${repo}/actions/runs/${run_id} -- this is NOT evidence the record is illegitimate; callers must fail closed, not treat this as absence" >&2
    return 2
  fi
  # aos#193 review finding L1 (round 4): valid JSON that is not an OBJECT
  # (a bare string, number, array...) would otherwise let every field read
  # below silently resolve to "", hitting the ordinary mismatch path
  # (return 1) instead of signalling "could not verify" (return 2).
  if ! printf '%s' "$run_response" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "::error::check-run binding COULD NOT VERIFY (run_query_failed): response from repos/${repo}/actions/runs/${run_id} is valid JSON but not an object -- this is NOT evidence the record is illegitimate; callers must fail closed, not treat this as absence" >&2
    return 2
  fi

  local run_head_sha run_repo run_status run_event run_head_branch
  run_head_sha="$(printf '%s' "$run_response" | jq -r '.head_sha // ""')"
  run_repo="$(printf '%s' "$run_response" | jq -r '.repository.full_name // ""')"
  run_status="$(printf '%s' "$run_response" | jq -r '.status // ""')"
  run_event="$(printf '%s' "$run_response" | jq -r '.event // ""')"
  run_head_branch="$(printf '%s' "$run_response" | jq -r '.head_branch // ""')"

  if [ "$run_head_sha" != "$sha" ]; then
    echo "::error::check-run binding REFUSED (run_head_sha_mismatch): run ${run_id}'s head_sha='${run_head_sha}', expected '${sha}' -- this record was created by a run against a DIFFERENT commit" >&2
    return 1
  fi
  if [ "$run_repo" != "$repo" ]; then
    echo "::error::check-run binding REFUSED (run_repository_mismatch): run ${run_id}'s repository.full_name='${run_repo}', expected '${repo}'" >&2
    return 1
  fi
  if [ "$run_status" != "completed" ]; then
    echo "::error::check-run binding COULD NOT VERIFY (run_not_completed): run ${run_id} has status='${run_status}', expected 'completed' -- the run that created this record has not finished yet; this is NOT evidence the record is illegitimate, callers must fail closed, not treat this as absence" >&2
    return 2
  fi
  # aos#193 review finding B1 (round 4): a run triggered any other way
  # (pull_request, schedule, ...) is never eligible to create a legitimate
  # blue-green record, even if every other check passes -- production
  # deploy-app.yml runs are always push or workflow_dispatch.
  if [ "$run_event" != "push" ] && [ "$run_event" != "workflow_dispatch" ]; then
    echo "::error::check-run binding REFUSED (run_event_not_allowed): run ${run_id}'s event='${run_event}', expected 'push' or 'workflow_dispatch' -- a run triggered any other way is never eligible to create a legitimate blue-green record" >&2
    return 1
  fi
  # aos#193 review finding B1 (round 4): the creating run must be on the
  # repo's default branch -- a forging workflow on a scratch or PR-head
  # branch must not bind, even if it happens to reference deploy-app.yml.
  if [ "$run_head_branch" != "$CHECK_RUN_BINDING_DEFAULT_BRANCH" ]; then
    echo "::error::check-run binding REFUSED (run_head_branch_not_default): run ${run_id}'s head_branch='${run_head_branch}', expected '${CHECK_RUN_BINDING_DEFAULT_BRANCH}' -- a forging workflow must be merged to the default branch to have any chance of binding" >&2
    return 1
  fi

  if ! printf '%s' "$run_response" | jq -e --arg prefix "$CHECK_RUN_BINDING_WORKFLOW_PATH_PREFIX" --arg ref "$CHECK_RUN_BINDING_WORKFLOW_REF" '
      (.referenced_workflows // [])[]?
      | select(.path != null and .ref != null)
      | select((.path | startswith($prefix)) and (.ref == $ref))
    ' >/dev/null 2>&1; then
    echo "::error::check-run binding REFUSED (run_did_not_reference_deploy_app_workflow_at_expected_ref): run ${run_id}'s referenced_workflows[] contains no entry whose path starts with '${CHECK_RUN_BINDING_WORKFLOW_PATH_PREFIX}' AND whose ref is exactly '${CHECK_RUN_BINDING_WORKFLOW_REF}' -- this run never actually executed deploy-app.yml from the expected ref, regardless of what the record's own output.text claims" >&2
    return 1
  fi

  local jobs_response
  # aos#193 review finding M1 (round 4): per_page=100 -- comfortably above
  # this repo's real per-run job counts, but explicitly bounded rather
  # than relying on gh's default page size (30), which silently truncated
  # the response for any run with more jobs than that.
  if ! jobs_response="$(gh api "repos/${repo}/actions/runs/${run_id}/attempts/${run_attempt}/jobs?per_page=100" 2>&1)"; then
    echo "::error::check-run binding COULD NOT VERIFY (jobs_query_failed): could not query repos/${repo}/actions/runs/${run_id}/attempts/${run_attempt}/jobs: ${jobs_response:-<no output>} -- this is NOT evidence the record is illegitimate; callers must fail closed, not treat this as absence" >&2
    return 2
  fi
  if ! printf '%s' "$jobs_response" | jq -e . >/dev/null 2>&1; then
    echo "::error::check-run binding COULD NOT VERIFY (jobs_query_failed): non-JSON response from repos/${repo}/actions/runs/${run_id}/attempts/${run_attempt}/jobs -- this is NOT evidence the record is illegitimate; callers must fail closed, not treat this as absence" >&2
    return 2
  fi
  # aos#193 review finding L1 (round 4): same object-type guard as the run
  # response above.
  if ! printf '%s' "$jobs_response" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "::error::check-run binding COULD NOT VERIFY (jobs_query_failed): response from repos/${repo}/actions/runs/${run_id}/attempts/${run_attempt}/jobs is valid JSON but not an object -- this is NOT evidence the record is illegitimate; callers must fail closed, not treat this as absence" >&2
    return 2
  fi

  # aos#193 review finding M1 (round 4): independently verify the page we
  # got back is actually complete -- total_count > (jobs actually
  # returned) means the record-creating step could be sitting on a page
  # we never fetched. That is "could not verify", never "the step is
  # absent".
  local jobs_total_count jobs_returned_count
  jobs_total_count="$(printf '%s' "$jobs_response" | jq -r '.total_count // 0')"
  jobs_returned_count="$(printf '%s' "$jobs_response" | jq -r '(.jobs // []) | length')"
  if [ "$jobs_returned_count" -lt "$jobs_total_count" ]; then
    echo "::error::check-run binding COULD NOT VERIFY (jobs_pagination_incomplete): run ${run_id} (attempt ${run_attempt}) reports total_count=${jobs_total_count} jobs but only ${jobs_returned_count} were returned -- refusing to guess whether the record-creating step is on an unfetched page" >&2
    return 2
  fi

  # aos#193 review finding B1 (round 4): the expected step must sit inside
  # a job whose GitHub-generated name has the "<caller job> / <called
  # job>" shape ending in " / deploy-caprover" -- not just ANY job in the
  # run -- and that job's OWN conclusion must be "success" too, not just
  # the step's. A sibling job in the same run (e.g. an unrelated workflow
  # step with a copied name) must never satisfy this.
  if ! printf '%s' "$jobs_response" | jq -e --arg step "$expected_step_name" --arg suffix "$CHECK_RUN_BINDING_JOB_NAME_SUFFIX" '
      (.jobs // [])[]?
      | select(.name != null and (.name | endswith($suffix)))
      | select(.conclusion == "success")
      | (.steps // [])[]?
      | select(.name == $step and .conclusion == "success")
    ' >/dev/null 2>&1; then
    echo "::error::check-run binding REFUSED (run_did_not_execute_expected_step): run ${run_id} (attempt ${run_attempt}) has no job named '*${CHECK_RUN_BINDING_JOB_NAME_SUFFIX}' with conclusion 'success' containing a step named '${expected_step_name}' with conclusion 'success' -- this run referenced deploy-app.yml on the right sha/ref/event/branch, but never actually completed the specific deploy-app.yml job and step that creates this record (for example: a uat-stage run, a live run whose e2e/approval failed before reaching it, or a copied step name in an unrelated sibling job)" >&2
    return 1
  fi

  return 0
}
