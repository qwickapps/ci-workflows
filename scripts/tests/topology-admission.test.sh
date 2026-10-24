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
expect_pass "canonical owner" "${ADMIT[@]}" --host oci-gateway --platform caprover --app srv-captain--qwickapps-mcp --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-sha 0123456789012345678901234567890123456789 --source-merged true
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
"${ADMIT[@]}" --render-windmill-inventory "$TMP/inventory.json" >/dev/null
python3 - "$TMP/inventory.json" <<'PY'
import json,sys
item=json.load(open(sys.argv[1]))["services"][0]
assert item["hostname"] == "qwickapps-mcp"
assert item["host"] == "oci-gateway"
PY
echo "Tests: $pass passed, $fail failed"
test "$fail" -eq 0
