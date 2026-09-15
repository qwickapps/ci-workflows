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

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
