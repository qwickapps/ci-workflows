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
check "CapRover deployment is primary-only" grep -A12 '^  deploy-caprover:' "$WF" | grep -q "deployment_lane == 'primary'"

echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
