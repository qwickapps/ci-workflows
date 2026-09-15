#!/usr/bin/env bash
#
# Regression test for aos#193 (blue-green SOP epic): "Remove every
# force_*/skip bypass. No input can skip a stage."
#
# aos#193's own design doc, grounded in a fresh read of deploy-app.yml
# before writing anything: "I found no `force_*` inputs to remove. I'll
# add a regression test... asserting no such input is ever (re)introduced,
# rather than 'removing' nonexistent code." This is that test.
#
# Guards deploy-app.yml's on.workflow_call.inputs key set against ever
# gaining a bypass-shaped input: anything matching force_*, *_force,
# *skip*, or *bypass* (case-insensitive). This is deliberately broad --
# wider than just the literal `force_` prefix -- because the whole point
# of aos#193 Phase 1's checks (first-deploy proof, host enforcement,
# eventually the live-e2e-approved gate) is that they become structurally
# impossible to route around. A new input that lets a caller skip one of
# them, under any name, defeats that.

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

echo "== deploy-app.yml: no force_*/skip/bypass-style input ever (re)introduced =="

assert "workflow file exists" \
  test -f "$WORKFLOW"

BYPASS_LIKE_JSON="$(python3 -c "
import yaml, json, re
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
inputs = doc[True]['workflow_call']['inputs']
pattern = re.compile(r'force|bypass|skip', re.IGNORECASE)
matches = sorted(k for k in inputs if pattern.search(k))
print(json.dumps(matches))
")"

assert "no input key matches force|bypass|skip (case-insensitive): found $BYPASS_LIKE_JSON" \
  test "$BYPASS_LIKE_JSON" = "[]"

# Sanity check the test itself isn't vacuous -- prove the pattern actually
# catches something, against a throwaway fixture, so a future refactor of
# this test can't silently make the assertion above always pass.
FIXTURE_MATCH="$(python3 -c "
import re
pattern = re.compile(r'force|bypass|skip', re.IGNORECASE)
names = ['force_deploy', 'skip_health_check', 'bypass_approval', 'app_name', 'e2e_command']
print(sorted(n for n in names if pattern.search(n)))
")"
assert "sanity: the bypass pattern itself catches force_deploy/skip_health_check/bypass_approval, not app_name/e2e_command" \
  test "$FIXTURE_MATCH" = "['bypass_approval', 'force_deploy', 'skip_health_check']"

# Names historically discussed/rejected -- pinned explicitly so a future PR
# re-adding any of these under its exact old name fails loudly here, not
# just via the generic pattern above.
for rejected in force_deploy force_stage force_live force_stable skip_e2e skip_approval skip_health_check; do
  MATCH="$(python3 -c "
import yaml
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
inputs = doc[True]['workflow_call']['inputs']
print('present' if '$rejected' in inputs else 'absent')
")"
  assert "input '$rejected' is absent" \
    test "$MATCH" = "absent"
done

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
