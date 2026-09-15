#!/usr/bin/env bash
#
# Regression test for ci-workflows#189: deploy-caprover's live-stage LB
# guard call (checking the STABLE slot's device, not the node this live
# run deployed) must use --skip-freshness-check, not --deploy-start-epoch.
# deploy-stable's own LB guard call (checking its own node against its own
# run) must keep using --deploy-start-epoch -- this test guards both
# directions so a future edit can't silently flip either one.

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

echo "== deploy-app.yml: LB guard call sites use the correct freshness mode =="

RESULT_JSON="$(python3 -c "
import yaml, json

with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)

def guard_step_run(job_id):
    steps = doc['jobs'][job_id]['steps']
    matches = [s for s in steps if s.get('name') == 'Verify LB target resolves to the node just deployed (infra#101 guard)']
    if len(matches) != 1:
        raise SystemExit(f'expected exactly one guard step in {job_id}, found {len(matches)}')
    return matches[0]['run']

deploy_caprover_run = guard_step_run('deploy-caprover')
deploy_stable_run = guard_step_run('deploy-stable')

print(json.dumps({
    'deploy_caprover_has_skip_flag': '--skip-freshness-check' in deploy_caprover_run,
    'deploy_caprover_has_epoch_flag': '--deploy-start-epoch' in deploy_caprover_run,
    'deploy_stable_has_skip_flag': '--skip-freshness-check' in deploy_stable_run,
    'deploy_stable_has_epoch_flag': '--deploy-start-epoch' in deploy_stable_run,
}))
")"

get() {
  python3 -c "import json,sys; print(json.loads(sys.argv[1])['$1'])" "$RESULT_JSON"
}

assert "deploy-caprover's LB guard (checks the STABLE node) uses --skip-freshness-check" \
  test "$(get deploy_caprover_has_skip_flag)" = "True"

assert "deploy-caprover's LB guard does NOT pass --deploy-start-epoch (this run's epoch is irrelevant to stable's node)" \
  test "$(get deploy_caprover_has_epoch_flag)" = "False"

assert "deploy-stable's LB guard (checks its OWN node) still uses --deploy-start-epoch" \
  test "$(get deploy_stable_has_epoch_flag)" = "True"

assert "deploy-stable's LB guard does NOT use --skip-freshness-check (its own freshness check is valid and should stay on)" \
  test "$(get deploy_stable_has_skip_flag)" = "False"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
