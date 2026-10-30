#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADMIT=(python3 "$ROOT/scripts/topology-admission.py" --registry "$ROOT/config/service-identities.json")
pass=0; fail=0
expect_pass() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS $label"; pass=$((pass+1)); else echo "FAIL expected pass: $label"; fail=$((fail+1)); fi; }
expect_deny() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL expected deny: $label"; fail=$((fail+1)); else echo "PASS denied $label"; pass=$((pass+1)); fi; }
# Exact replay: stale issue requests a second MCP LB on oci-main. Must stop pre-mutation.
expect_deny "mcp wrong host" "${ADMIT[@]}" --host oci-main --platform caprover --app qwickapps-mcp-lb --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-sha 0123456789012345678901234567890123456789 --source-merged true
expect_deny "duplicate canonical claimant" "${ADMIT[@]}" --host oci-gateway --platform caprover --app qwickapps-mcp-lb --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-sha 0123456789012345678901234567890123456789 --source-merged true
expect_deny "unmerged source" "${ADMIT[@]}" --host oci-gateway --platform caprover --app srv-captain--qwickapps-mcp --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-sha 0123456789012345678901234567890123456789 --source-merged false
expect_deny "direct untraceable deploy" "${ADMIT[@]}" --host oci-gateway --platform caprover --app srv-captain--qwickapps-mcp --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-merged true
expect_deny "attempted canonical rename" "${ADMIT[@]}" --host oci-gateway --platform caprover --app qwickapps-mcp-gateway-retired --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-sha 0123456789012345678901234567890123456789 --source-merged true
expect_pass "canonical owner" "${ADMIT[@]}" --caprover-url https://route.qwickforge.com --platform caprover --app srv-captain--qwickapps-mcp --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-sha 0123456789012345678901234567890123456789 --source-merged true
expect_deny "lookalike CapRover hostname" "${ADMIT[@]}" --caprover-url https://route.qwickforge.com.attacker.example --platform caprover --app srv-captain--qwickapps-mcp --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-sha 0123456789012345678901234567890123456789 --source-merged true
expect_deny "CapRover userinfo trick" "${ADMIT[@]}" --caprover-url https://route.qwickforge.com@attacker.example --platform caprover --app srv-captain--qwickapps-mcp --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-sha 0123456789012345678901234567890123456789 --source-merged true
expect_deny "CapRover port trick" "${ADMIT[@]}" --caprover-url https://route.qwickforge.com:4443 --platform caprover --app srv-captain--qwickapps-mcp --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-sha 0123456789012345678901234567890123456789 --source-merged true
expect_deny "CapRover path trick" "${ADMIT[@]}" --caprover-url https://route.qwickforge.com/captain --platform caprover --app srv-captain--qwickapps-mcp --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-sha 0123456789012345678901234567890123456789 --source-merged true
# deploy-stable uses this same admission boundary.  A stable backend aimed at
# the gateway must be rejected before Configure target slot / deploy-from-ghcr
# are reached; its registry tuple requires oci-main.
expect_deny "stable tuple wrong host before mutation" "${ADMIT[@]}" --caprover-url https://route.qwickforge.com --platform caprover --app srv-captain--qwickapps-memories-stable --hostname qwickapps-memories-stable --image-ref ghcr.io/qwickapps/img-memories:stable --production --source-sha 0123456789012345678901234567890123456789 --source-merged true
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
"${ADMIT[@]}" --render-windmill-inventory "$TMP/inventory.json" >/dev/null
if cmp -s "$TMP/inventory.json" "$ROOT/config/generated/topology-windmill-inventory.json"; then
  echo "PASS generated Windmill inventory matches service registry"
  pass=$((pass+1))
else
  echo "FAIL generated Windmill inventory differs from config/service-identities.json; regenerate it with scripts/topology-admission.py --render-windmill-inventory config/generated/topology-windmill-inventory.json"
  fail=$((fail+1))
fi
python3 - "$TMP/inventory.json" <<'PY'
import json,sys
item=json.load(open(sys.argv[1]))["services"][0]
assert item["hostname"] == "qwickapps-mcp"
assert item["host"] == "oci-gateway"
PY
python3 - "$ROOT/.github/workflows/deploy-app.yml" <<'PY'
import sys
import yaml

workflow = yaml.safe_load(open(sys.argv[1]))
for job_name in ("deploy-caprover", "deploy-stable"):
    steps = workflow["jobs"][job_name]["steps"]
    names = [step.get("name") for step in steps]
    admission_index = names.index("Topology admission before mutation")
    configure_index = names.index("Configure target slot (atomic env + config)")
    deploy_index = names.index("Deploy image to target slot")
    assert admission_index < configure_index, (job_name, admission_index, configure_index)
    assert admission_index < deploy_index, (job_name, admission_index, deploy_index)
    admission = steps[admission_index]["run"]
    assert "--caprover-url \"$CP_TARGET\"" in admission, job_name
    assert "--platform caprover" in admission, job_name
    assert "--app \"${{ needs.resolve-stage.outputs.target_app }}\"" in admission, job_name
    assert "--hostname \"$TS_HOSTNAME\"" in admission, job_name
    assert "*route.qwickforge.com*" not in admission, job_name
    assert "*app.qwickforge.com*" not in admission, job_name
PY
echo "Tests: $pass passed, $fail failed"
test "$fail" -eq 0
