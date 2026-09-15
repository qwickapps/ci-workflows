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
# aos#193 Phase 1 gave both jobs a permissions block anyway, for a
# different reason: deploy-caprover's first-deploy proof (§2) needs
# packages: read to query GHCR release/stable tag history via the GH
# Packages API, and checks: write to create/query
# blue-green/first-deploy-used and blue-green/live-e2e-approved check
# runs; deploy-stable's gate (§1/§5, only active when the caller passes
# require_live_approval_check: true) needs checks: read to query the
# live-e2e-approved check run it verifies against. Both are additive
# grants scoped to exactly what aos#193 Phase 1 needs, nothing broader.
#
# A permissions: block on a job REPLACES the job's entire default
# permission set, not adds to it -- this also checks that no OTHER job in
# the file (which doesn't have a GHCR-login step) was accidentally given a
# permissions block, which would silently strip that job's actual defaults.

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

assert "deploy-caprover job: permissions = {contents: read, packages: read, checks: write} (aos#193 Phase 1)" \
  test "$(job_permissions_json deploy-caprover)" = '{"contents": "read", "packages": "read", "checks": "write"}'

assert "deploy-stable job: permissions = {contents: read, checks: read} (aos#193 Phase 1)" \
  test "$(job_permissions_json deploy-stable)" = '{"contents": "read", "checks": "read"}'

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
