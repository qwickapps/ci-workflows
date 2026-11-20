#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WF="$ROOT/.github/workflows/deploy-app.yml"
ACTION="$ROOT/.github/actions/coolify-validation/action.yml"
RESOLVER="$ROOT/scripts/resolve-coolify-validation-credentials.sh"
CONFIG="$ROOT/config/coolify-secondary-validation.json"

pass=0; fail=0
check() { local d="$1"; shift; if "$@"; then echo "  PASS: $d"; pass=$((pass+1)); else echo "  FAIL: $d"; fail=$((fail+1)); fi; }

check "workflow has separate named build job" grep -q '^  deploy-coolify-build:' "$WF"
check "workflow has separate named UAT job" grep -q '^  deploy-coolify-uat:' "$WF"
check "build job is secondary-only" grep -q "deployment_lane == 'secondary'" "$WF"
check "explicit config defines only build and uat slots" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert set(d["slots"])=={"build","uat"}; assert d["server"]["name"]=="localhost"' "$CONFIG"
check "only scoped Momo deploy secret is selected" grep -q 'secrets.COOLIFY_MOMO_DEPLOY_TOKEN' "$WF"
check "resolver fallback uses exact scoped secret path" grep -q 'infrastructure/caprover/COOLIFY_MOMO_DEPLOY_TOKEN' "$RESOLVER"
check "exclusive token-name policy passes the deployment pipeline" python3 "$ROOT/scripts/validate-coolify-token-exclusivity.py" --root "$ROOT"
check "secondary action runs pre and post topology checks" test "$(grep -c 'coolify-validation-topology.py' "$ACTION")" -eq 2
check "secondary action has rollback" grep -q 'coolify-validation-deploy.py rollback' "$ACTION"
# Pipeline inside check: the old form piped check's own output into grep -q,
# which asserted nothing and aborted the suite under pipefail.
check "CapRover deployment is primary-only" bash -c "grep -A12 '^  deploy-caprover:' '$WF' | grep -q \"deployment_lane == 'primary'\""

# t_ba218534 / t_2740078a: one versioned per-slot lock for every secondary job,
# disjoint from caprover-deploy-*, never cancelling in progress.
LOCK='group: coolify-momo-secondary-v1-${{ inputs.app_name }}-${{ needs.resolve-stage.outputs.stage }}'
check "all three secondary jobs share the v1 per-slot lock" test "$(grep -cF "$LOCK" "$WF")" -eq 3
check "no legacy unversioned coolify-momo lock remains" bash -c "! grep -E 'group: coolify-momo-\\\$\\{\\{' '$WF'"
check "secondary lock namespace is disjoint from caprover-deploy" bash -c "! grep -F 'group: coolify-momo-secondary-v1' '$WF' | grep -q caprover"
check "secondary helpers are checked out at this workflow's commit" python3 - "$WF" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))['jobs']
for name in ('deploy-coolify-build', 'deploy-coolify-uat', 'stop-coolify-build-slot'):
    refs = [s['with']['ref'] for s in jobs[name]['steps'] if isinstance(s.get('with'), dict) and s['with'].get('repository') == 'qwickapps/ci-workflows']
    assert refs == ['${{ job.workflow_sha }}'], (name, refs)
PY
check "caller secret bundle reaches only the env render step" python3 - "$WF" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))['jobs']
for name in ('deploy-coolify-build', 'deploy-coolify-uat'):
    for s in jobs[name]['steps']:
        env = s.get('env') or {}
        if 'CALLER_SECRETS_JSON' in env or any(k.startswith('QWICKSECRETS_') for k in env):
            assert s.get('id') == 'env-file', (name, s.get('name'))
        if s.get('uses', '').endswith('coolify-validation'):
            assert not env, (name, 'composite action must get no env/secrets')
PY
check "deep health script absence fails closed with a clear error" grep -q 'deep-health-check.sh not found in caller repo; secondary lane cannot verify subsystem health, failing closed' "$ACTION"
check "prod-critical subsystems are promoted for uat, not dropped" grep -q 'prod-critical-subsystems: \${{ inputs.prod_critical_subsystems }}' "$WF"
check "final evidence records every gate outcome" grep -q 'coolify-validation-evidence.py' "$ACTION"

echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
