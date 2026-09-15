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
#        - referenced_workflows[].path must contain an entry starting with
#          "qwickapps/ci-workflows/.github/workflows/deploy-app.yml@" --
#          this is the actual, GitHub-verified proof that the run which
#          created this record EXECUTED this reusable workflow, not merely
#          claimed to in a text field it fully controls.
#
# `check_run.conclusion` is intentionally NOT re-checked against a fixed
# "success" here: the specific check-run being verified already carries
# its own conclusion (checked by the caller before this function ever
# runs), and other, unrelated steps later in the SAME caller job could
# fail for reasons that have nothing to do with the record's own
# legitimacy -- requiring the whole run's conclusion to be "success" would
# make this stricter than the thing it's actually trying to prove.
#
# Usage (after `export GH_TOKEN=...`, same convention as the callers):
#   source scripts/lib/check-run-binding.sh
#   if check_run_binding_verify "<owner>/<repo>" "<sha>" "<app-slug>" "<external-id>"; then
#     ...
#   fi
# Returns 0 if the binding holds. Returns 1, with a specifically-named
# `::error::` reason on stderr, otherwise. Never exits the calling shell.

set -euo pipefail

CHECK_RUN_BINDING_WORKFLOW_PATH_PREFIX="qwickapps/ci-workflows/.github/workflows/deploy-app.yml@"

check_run_binding_verify() {
  local repo="$1" sha="$2" app_slug="$3" external_id="$4"

  if [ "$app_slug" != "github-actions" ]; then
    echo "::error::check-run binding REFUSED (check_run_app_mismatch): creating app.slug='${app_slug}', expected 'github-actions' -- a check run created by any other GitHub App is never a legitimate blue-green record, no matter what its output.text claims" >&2
    return 1
  fi

  if [[ ! "$external_id" =~ ^([0-9]+)-[0-9]+$ ]]; then
    echo "::error::check-run binding REFUSED (missing_or_malformed_external_id): external_id='${external_id}', expected '<run_id>-<run_attempt>' -- cannot look up the creating run without it" >&2
    return 1
  fi
  local run_id="${BASH_REMATCH[1]}"

  local run_response
  if ! run_response="$(gh api "repos/${repo}/actions/runs/${run_id}" 2>&1)"; then
    echo "::error::check-run binding REFUSED (run_query_failed): could not query repos/${repo}/actions/runs/${run_id}: ${run_response:-<no output>}" >&2
    return 1
  fi
  if ! printf '%s' "$run_response" | jq -e . >/dev/null 2>&1; then
    echo "::error::check-run binding REFUSED (run_query_failed): non-JSON response from repos/${repo}/actions/runs/${run_id}" >&2
    return 1
  fi

  local run_head_sha run_repo run_status
  run_head_sha="$(printf '%s' "$run_response" | jq -r '.head_sha // ""')"
  run_repo="$(printf '%s' "$run_response" | jq -r '.repository.full_name // ""')"
  run_status="$(printf '%s' "$run_response" | jq -r '.status // ""')"

  if [ "$run_head_sha" != "$sha" ]; then
    echo "::error::check-run binding REFUSED (run_head_sha_mismatch): run ${run_id}'s head_sha='${run_head_sha}', expected '${sha}' -- this record was created by a run against a DIFFERENT commit" >&2
    return 1
  fi
  if [ "$run_repo" != "$repo" ]; then
    echo "::error::check-run binding REFUSED (run_repository_mismatch): run ${run_id}'s repository.full_name='${run_repo}', expected '${repo}'" >&2
    return 1
  fi
  if [ "$run_status" != "completed" ]; then
    echo "::error::check-run binding REFUSED (run_not_completed): run ${run_id} has status='${run_status}', expected 'completed' -- the run that created this record has not finished" >&2
    return 1
  fi

  if ! printf '%s' "$run_response" | jq -e --arg prefix "$CHECK_RUN_BINDING_WORKFLOW_PATH_PREFIX" '
      (.referenced_workflows // [])[]?
      | select(.path != null)
      | select(.path | startswith($prefix))
    ' >/dev/null 2>&1; then
    echo "::error::check-run binding REFUSED (run_did_not_reference_deploy_app_workflow): run ${run_id}'s referenced_workflows[] contains no entry whose path starts with '${CHECK_RUN_BINDING_WORKFLOW_PATH_PREFIX}' -- this run never actually executed deploy-app.yml, regardless of what the record's own output.text claims" >&2
    return 1
  fi

  return 0
}
