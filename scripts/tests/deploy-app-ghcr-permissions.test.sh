#!/usr/bin/env bash
#
# Regression test for ci-workflows#137: deploy-app.yml's GHCR-login steps
# fall back to secrets.GITHUB_TOKEN when GHCR_PULL_TOKEN/GHCR_PUSH_TOKEN are
# unset or stale, but the file had no `permissions:` block at all -- so
# GITHUB_TOKEN got the org/repo default, which does not include package
# access. The fallback was silent dead code whenever the dedicated secret
# was itself valid, and gave no real safety net when it died -- exactly the
# gap that blocked qwickapps/forge#251/#253/#250 from deploying for 8+
# hours despite merging clean (confirmed live: forge's Deploy Forge run
# 33375610744, `docker login ghcr.io` denied even with the #136 fallback).
#
# Verifies the jobs with a GHCR-login step each declare an explicit,
# correctly-scoped `permissions:` block: build (contents: read + packages:
# write -- it checks out the repo AND pushes), verify-provenance (packages:
# read only -- no checkout, pull-only), retag (packages: write -- no
# checkout, writes a new manifest tag).
#
# deploy-stable and deploy-caprover do NOT need GHCR package access
# locally (mcp#392): they deploy via deploy-from-ghcr.sh, which hands
# CapRover a GHCR token as a plain script argument, not a local `docker
# buildx imagetools inspect` + Docker-config login.
#
# aos#193 Phase 1's FIRST round gave both jobs a permissions block anyway
# (deploy-caprover: contents/packages/checks; deploy-stable: contents/
# checks), for a different reason: the first-deploy-proof and
# live-e2e-approved-gate features. The SECOND round of review reverted
# both blocks entirely (not just the checks: * lines) after finding a
# real, empirically-confirmed break: a reusable workflow job's requested
# permissions must be a SUBSET of what the calling workflow itself grants,
# and GitHub validates this for the WHOLE workflow_call at dispatch time --
# not lazily per job, and not skipped for a job whose `if:` would evaluate
# false. None of the 14 org callers of deploy-app.yml grant `checks` (and
# only some already grant `packages`, via the earlier, separate #137/#138
# fix), so giving deploy-caprover/deploy-stable ANY new permissions block
# here would break every one of them at dispatch time the moment this
# merged -- see those two jobs' own header comments in deploy-app.yml for
# the empirical repro. Landing the needed grants in the 14 callers' own
# top-level permissions is a required Phase 1b follow-up BEFORE either job
# can safely carry its own permissions block again.
#
# A permissions: block on a job REPLACES the job's entire default
# permission set, not adds to it -- this also checks that no OTHER job in
# the file (which doesn't have a GHCR-login step, including
# deploy-caprover/deploy-stable) was accidentally given a permissions
# block, which would silently strip that job's actual defaults.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/deploy-app.yml"

pass=0
fail=0
assert() {
  local desc="$1"; shift
  if "$@"; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc"
    fail=$((fail + 1))
  fi
}

job_permissions_json() {
  local job="$1"
  python3 -c "
import yaml, json, sys
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
job = doc['jobs'].get('$job')
print(json.dumps(job.get('permissions') if job else None))
"
}

# step_run JOB NAME_SUBSTRING -- prints the run: script of the first step
# in JOB whose name contains NAME_SUBSTRING. A shared python helper file
# (rather than inline python-inside-bash-c) avoids the quote-escaping mess
# of nesting python source inside a double-quoted bash -c string.
STEP_RUN_HELPER="$(mktemp)"
trap 'rm -f "$STEP_RUN_HELPER"' EXIT
cat > "$STEP_RUN_HELPER" <<'PYEOF'
import sys, yaml
workflow, job, needle, field = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(workflow) as f:
    doc = yaml.safe_load(f)
steps = doc['jobs'][job]['steps']
matches = [s for s in steps if needle in s.get('name', '')]
if not matches:
    sys.exit(f"no step containing '{needle}' in job '{job}'")
step = matches[0]
if field == 'run':
    print(step['run'])
elif field.startswith('env:'):
    print(step.get('env', {}).get(field.split(':', 1)[1], ''))
else:
    sys.exit(f"unknown field '{field}'")
PYEOF

step_run() {
  local job="$1" needle="$2"
  python3 "$STEP_RUN_HELPER" "$WORKFLOW" "$job" "$needle" run
}

step_env() {
  local job="$1" needle="$2" var="$3"
  python3 "$STEP_RUN_HELPER" "$WORKFLOW" "$job" "$needle" "env:$var"
}

echo "== deploy-app.yml: GHCR-consuming jobs have explicit, correctly-scoped permissions =="

assert "workflow file exists" \
  test -f "$WORKFLOW"

assert "build job: permissions = {contents: read, packages: write}" \
  test "$(job_permissions_json build)" = '{"contents": "read", "packages": "write"}'

assert "verify-provenance job: permissions = {packages: read}" \
  test "$(job_permissions_json verify-provenance)" = '{"packages": "read"}'

assert "retag job: permissions = {packages: write}" \
  test "$(job_permissions_json retag)" = '{"packages": "write"}'

assert "deploy-caprover job: NO permissions block (aos#193 Phase 1 review round 2 -- see this test's header comment)" \
  test "$(job_permissions_json deploy-caprover)" = "null"

assert "deploy-stable job: NO permissions block (aos#193 Phase 1 review round 2 -- see this test's header comment)" \
  test "$(job_permissions_json deploy-stable)" = "null"

echo "== No workflow-level permissions block (per-job scoping only) =="
TOPLEVEL=$(python3 -c "
import yaml, json
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
print(json.dumps(doc.get('permissions')))
")
assert "no workflow-level permissions: key (would broaden every other job too)" \
  test "$TOPLEVEL" = "null"

echo "== Jobs with neither a GHCR-login step nor an aos#193 check-run need were not accidentally scoped =="
for job in resolve-stage validate-env scale-build-slot; do
  assert "$job job: no permissions block added (keeps its actual defaults)" \
    test "$(job_permissions_json "$job")" = "null"
done

echo "== ci-workflows#204: the stale-PAT-beats-github.token expression is gone =="
# The bug: `secrets.GHCR_PULL_TOKEN || secrets.GITHUB_TOKEN` (and the PUSH
# equivalent) only falls back when the secret is UNSET, never when it's
# merely stale -- a SET but stale PAT still won. #204 replaces every one of
# these with an actual ghcr.io probe (scripts/lib/ghcr-token-select.sh).
# This asserts the old expression shape is gone from the file entirely, so
# a future edit can't quietly reintroduce it.
assert "no lingering 'secrets.GHCR_PULL_TOKEN || secrets.GITHUB_TOKEN' expression" \
  bash -c "! grep -qE 'secrets\.GHCR_PULL_TOKEN[[:space:]]*\|\|[[:space:]]*secrets\.GITHUB_TOKEN' '$WORKFLOW'"

assert "no lingering 'secrets.GHCR_PUSH_TOKEN || secrets.GITHUB_TOKEN' expression" \
  bash -c "! grep -qE 'secrets\.GHCR_PUSH_TOKEN[[:space:]]*\|\|[[:space:]]*secrets\.GITHUB_TOKEN' '$WORKFLOW'"

assert "no lingering bare '|| secrets.GITHUB_TOKEN' fallback anywhere (any secret name)" \
  bash -c "! grep -qE '\|\|[[:space:]]*secrets\.GITHUB_TOKEN' '$WORKFLOW'"

echo "== ci-workflows#204: runner-side GHCR ops (build/verify-provenance/retag) prefer github.token =="
# build uses github.token UNCONDITIONALLY (no PAT consulted at all, see
# that job's own header comment for why that's safe there specifically).
# verify-provenance/retag each call ghcr_select_token with "github.token"
# listed as the FIRST label/token pair -- ghcr_select_token tries
# candidates strictly in the order given, so "first" here is the actual
# preference, not just presence.

# first_ghcr_select_token_label SCRIPT -- the first quoted label argument
# following the first "ghcr_select_token" call in a run: script.
first_ghcr_select_token_label() {
  awk '/ghcr_select_token/{f=1} f && /"[A-Za-z._]+"/{match($0, /"[A-Za-z._]+"/); print substr($0, RSTART+1, RLENGTH-2); exit}'
}

BUILD_LOGIN_1_TOKEN="$(step_env build "Login to GHCR" GHCR_TOKEN)"
BUILD_LOGIN_2_TOKEN="$(step_env build "Login to GHCR for base image pull" GHCR_TOKEN)"
assert "build job: 'Login to GHCR' step uses github.token unconditionally" \
  test "$BUILD_LOGIN_1_TOKEN" = '${{ github.token }}'

assert "build job: 'Login to GHCR for base image pull' step uses github.token unconditionally" \
  test "$BUILD_LOGIN_2_TOKEN" = '${{ github.token }}'

assert "build job: neither GHCR-login step references a legacy PAT secret at all" \
  bash -c '! printf "%s\n%s\n" "$1" "$2" | grep -qF "secrets.GHCR_"' _ "$BUILD_LOGIN_1_TOKEN" "$BUILD_LOGIN_2_TOKEN"

assert "verify-provenance: ghcr_select_token is called with github.token as the FIRST candidate" \
  bash -c 'test "$1" = "github.token"' _ \
    "$(step_run verify-provenance "Write GHCR credentials" | first_ghcr_select_token_label)"

assert "retag: ghcr_select_token is called with github.token as the FIRST candidate" \
  bash -c 'test "$1" = "github.token"' _ \
    "$(step_run retag "Authenticate to GHCR for retag" | first_ghcr_select_token_label)"

echo "== ci-workflows#204: CapRover-side selection prefers the PAT, falls back to github.token =="
# deploy-caprover/deploy-stable export a token that overwrites a SHARED
# CapRover registry entry -- the long-lived PAT is preferred there
# (opposite order from the runner-side jobs above) precisely because it
# outlives this one job, per this job's own header comment.
for job in deploy-caprover deploy-stable; do
  assert "$job: ghcr_select_token is called with GHCR_PULL_TOKEN as the FIRST candidate" \
    bash -c 'test "$1" = "GHCR_PULL_TOKEN"' _ \
      "$(step_run "$job" "Select GHCR pull token" | first_ghcr_select_token_label)"
done

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
