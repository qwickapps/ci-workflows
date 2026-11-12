#!/usr/bin/env bash
# Regression guard for deploy-app.yml post-deploy topology handling.
# A confirmed conflict (409) may roll back; verification loss (503) must not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/deploy-app.yml"
PASS=0
FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1" >&2; FAIL=$((FAIL + 1)); }
require() {
  local needle="$1" label="$2"
  if grep -Fq -- "$needle" "$WORKFLOW"; then pass "$label"; else fail "$label"; fi
}

require '--result-json-out "$RESULT_JSON"' 'preflight writes structured result'
require 'REGISTRY_APP="$(python3 -c' 'workflow resolves canonical registry app from hostname'
require '--app "$REGISTRY_APP"' 'static admission uses canonical registry app'
require '--registry-app "$REGISTRY_APP"' 'live preflight validates canonical registry app'
require '--app "${{ needs.resolve-stage.outputs.target_app }}"' 'live preflight excludes deployed target app'
require '--new-claimant-app "${{ needs.resolve-stage.outputs.target_app }}"' 'rollback neutralizes deployed target app'
require '"status_code"' 'workflow parses status_code'
require '"failure_type"' 'workflow parses failure_type'
require '[ "$STATUS_CODE" = "409" ] && [ "$FAILURE_TYPE" = "topology_conflict" ]' '409 conflict gate exists'
require '[ "$STATUS_CODE" = "503" ] && [ "$FAILURE_TYPE" = "verification_failure" ]' '503 verification-failure gate exists'
require 'verification failed closed (400)' 'verification failure is fail-closed as 400'

if python3 - "$WORKFLOW" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
start = text.index("      - name: Post-deploy topology conflict check + rollback")
end = text.index("      - name: Deep subsystem health check", start)
block = text[start:end]
conflict = block.index('if [ "$STATUS_CODE" = "409" ] && [ "$FAILURE_TYPE" = "topology_conflict" ]; then')
rollback = block.index("topology-rollback.py", conflict)
verification = block.index('if [ "$STATUS_CODE" = "503" ] && [ "$FAILURE_TYPE" = "verification_failure" ]; then')
verification_body = block[verification:]
if rollback > verification:
    raise SystemExit("rollback must be reached only from the 409 conflict branch")
if "topology-rollback.py" in verification_body:
    raise SystemExit("503 verification branch must not invoke rollback")
PY
then
  pass 'rollback is reachable only from confirmed 409 conflict'
else
  fail 'rollback is reachable only from confirmed 409 conflict'
fi

if python3 - "$ROOT" <<'PY'
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
workflow = (root / ".github/workflows/deploy-app.yml").read_text(encoding="utf-8")
stage_target_app = "qwickapps-mcp-live"
registry_app = "srv-captain--qwickapps-mcp"
assert stage_target_app != registry_app
assert workflow.count('--app "$REGISTRY_APP"') == 1
assert workflow.count('--registry-app "$REGISTRY_APP"') == 2
assert workflow.count('--app "${{ needs.resolve-stage.outputs.target_app }}"') == 2
assert '--new-claimant-app "${{ needs.resolve-stage.outputs.target_app }}"' in workflow
subprocess.run([
    "python3", str(root / "scripts/topology-admission.py"),
    "--registry", str(root / "config/service-identities.json"),
    "--host", "oci-gateway", "--platform", "caprover",
    "--app", registry_app, "--hostname", "qwickapps-mcp",
    "--image-ref", "ghcr.io/qwickapps/qwickway:latest",
], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
bad = subprocess.run([
    "python3", str(root / "scripts/topology-admission.py"),
    "--registry", str(root / "config/service-identities.json"),
    "--host", "oci-gateway", "--platform", "caprover",
    "--app", stage_target_app, "--hostname", "qwickapps-mcp",
    "--image-ref", "ghcr.io/qwickapps/qwickway:latest",
], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
assert bad.returncode == 2
PY
then
  pass 'stage-derived app is mapped to committed canonical registry identity'
else
  fail 'stage-derived app is mapped to committed canonical registry identity'
fi

echo "Tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
