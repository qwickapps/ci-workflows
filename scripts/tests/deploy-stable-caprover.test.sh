#!/usr/bin/env bash
#
# Regression test for the deploy-stable / CapRover fix (qwickapps/mcp#392).
#
# Read-only investigation on 2026-09-15 (mcp#392) found that deploy-stable's
# Coolify deployment target (deploy-to-coolify.sh, secrets.COOLIFY_URL /
# secrets.COOLIFY_TOKEN, an app named "${app_name}-stable" on Coolify) was
# orphaned tooling -- no app by that name exists on either Coolify instance
# (macmini or momo). The real, live stable slot has always been a CapRover
# app on the same oci-main cluster as live. deploy-stable was rewritten to
# mirror deploy-caprover's pattern instead.
#
# This test guards against the orphaned Coolify path silently coming back
# (e.g. a future merge conflict or a revert that resurrects it), and
# confirms deploy-stable now uses the same CapRover toolset deploy-caprover
# does.

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

echo "== deploy-app.yml: deploy-stable deploys via CapRover, not the orphaned Coolify path =="

RESULT_JSON="$(python3 -c "
import yaml, json

with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)

job = doc['jobs']['deploy-stable']
steps = job.get('steps', [])

def step_texts():
    for s in steps:
        yield ' '.join(filter(None, [s.get('name', ''), s.get('run', '') or '']))

all_text = '\n'.join(step_texts()).lower()

result = {
    'no_coolify_script': 'deploy-to-coolify.sh' not in all_text,
    'no_coolify_url_secret': 'secrets.coolify_url' not in all_text,
    'no_coolify_token_secret': 'secrets.coolify_token' not in all_text,
    'no_coolify_word': 'coolify' not in all_text,
    'has_configure_caprover': 'configure-caprover-app.sh' in all_text,
    'has_deploy_from_ghcr': 'deploy-from-ghcr.sh' in all_text,
    'has_validate_deployment_health': 'validate-deployment-health.sh' in all_text,
    'has_caprover_credentials_step': any('caprover credentials' in (s.get('name','') or '').lower() for s in steps),
    'uses_resolved_target_app': 'needs.resolve-stage.outputs.target_app' in all_text,
    'no_hardcoded_app_stable_suffix': (\"inputs.app_name }}-stable\" not in all_text) and (\"inputs.app_name}}-stable\" not in all_text),
    # aos#193 Phase 1 review (round 2): deploy-stable carries NO explicit
    # permissions block at all -- a job's requested permissions are
    # validated against the CALLER's grant for the whole reusable workflow
    # at dispatch time, not lazily per job/step, so adding checks: read
    # here would break every one of the 14 current callers (none of which
    # grant checks) even though the gate step below only runs when a
    # caller opts into require_live_approval_check. See this job's own
    # header comment for the empirical confirmation. Landing checks: read
    # here (and in the 14 callers) is a tracked Phase 1b follow-up.
    'permissions_block': job.get('permissions'),
    # The gate step's if-condition must be EXACTLY this expression -- not
    # hardcoded to false, not weakened to some always-true condition. A
    # mutation that flips this to a literal false (disabling the gate
    # entirely while require_live_approval_check: true) must fail this
    # assertion (aos#193 review mutation gap).
    'gate_step_if': next(
        (s.get('if') for s in steps if (s.get('name') or '').startswith('Verify live-e2e-approved')),
        None,
    ),
    # The job itself must have no if-condition that could make it silently
    # succeed/skip without the gate step ever running -- deploy-stable's
    # job-level if-condition already requires resolve-stage/validate-env/
    # verify-provenance to have succeeded and stage == 'stable'; it must
    # not ALSO reference require_live_approval_check (that gating belongs
    # solely to the step, so the step can never be structurally bypassed
    # by a job-level short-circuit that looks unrelated).
    'job_if': job.get('if', ''),
}

# Confirm no OTHER job in the file references Coolify either -- the
# orphaned path must be fully removed, not just unreferenced by
# deploy-stable while dead code lingers elsewhere.
other_jobs_coolify = []
for job_id, j in doc.get('jobs', {}).items():
    if job_id == 'deploy-stable' or not isinstance(j, dict):
        continue
    texts = []
    for s in j.get('steps', []) or []:
        if isinstance(s, dict):
            texts.append(' '.join(filter(None, [s.get('name',''), s.get('run','') or ''])))
    if 'coolify' in ' '.join(texts).lower():
        other_jobs_coolify.append(job_id)
result['other_jobs_coolify'] = other_jobs_coolify

print(json.dumps(result))
")"

get() {
  python3 -c "import json,sys; print(json.loads(sys.argv[1])['$1'])" "$RESULT_JSON"
}

assert "deploy-stable: no reference to deploy-to-coolify.sh" \
  test "$(get no_coolify_script)" = "True"

assert "deploy-stable: no reference to secrets.COOLIFY_URL" \
  test "$(get no_coolify_url_secret)" = "True"

assert "deploy-stable: no reference to secrets.COOLIFY_TOKEN" \
  test "$(get no_coolify_token_secret)" = "True"

assert "deploy-stable: no mention of 'coolify' anywhere in its steps" \
  test "$(get no_coolify_word)" = "True"

assert "deploy-stable: uses configure-caprover-app.sh (same as deploy-caprover)" \
  test "$(get has_configure_caprover)" = "True"

assert "deploy-stable: uses deploy-from-ghcr.sh (same as deploy-caprover)" \
  test "$(get has_deploy_from_ghcr)" = "True"

assert "deploy-stable: uses validate-deployment-health.sh (same as deploy-caprover)" \
  test "$(get has_validate_deployment_health)" = "True"

assert "deploy-stable: has a 'Resolve CapRover credentials'-style step" \
  test "$(get has_caprover_credentials_step)" = "True"

assert "deploy-stable: resolves its target app name via resolve-stage's target_app output" \
  test "$(get uses_resolved_target_app)" = "True"

assert "deploy-stable: no duplicated/hardcoded '\${{ inputs.app_name }}-stable' app-name construction" \
  test "$(get no_hardcoded_app_stable_suffix)" = "True"

assert "deploy-stable: no permissions block at all (aos#193 Phase 1 review round 2 -- see this job's header comment: a job-level permissions block is validated against the caller's grant for the WHOLE reusable workflow regardless of any if:, so adding checks: read here today would break all 14 current callers)" \
  test "$(get permissions_block)" = "None"

assert "deploy-stable: the live-e2e-approved gate step's if: is exactly 'inputs.require_live_approval_check == true' -- never hardcoded false, never weakened (aos#193 review mutation gap: a step this important must not be silently disabled)" \
  test "$(get gate_step_if)" = "inputs.require_live_approval_check == true"

JOB_IF="$(get job_if)"
if echo "$JOB_IF" | grep -qi require_live_approval_check; then
  echo "  FAIL: deploy-stable: the job-level if: must not reference require_live_approval_check itself"
  fail=$((fail + 1))
else
  echo "  PASS: deploy-stable: the job-level if: does not itself reference require_live_approval_check (the gate step is the ONLY place that input is allowed to skip anything in this job)"
  pass=$((pass + 1))
fi

OTHER_COOLIFY_JOBS="$(get other_jobs_coolify)"
assert "no other job in deploy-app.yml still mentions coolify" \
  test "$OTHER_COOLIFY_JOBS" = "[]"
if [ "$OTHER_COOLIFY_JOBS" != "[]" ]; then
  echo "    jobs still mentioning coolify: $OTHER_COOLIFY_JOBS" >&2
fi

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
