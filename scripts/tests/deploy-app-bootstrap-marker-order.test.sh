#!/usr/bin/env bash
#
# Regression test for t_b14e0125 (meera review, 2026-11-05): the
# deploy-stable job's "Record first-stable bootstrap authorization" step
# (which creates the single-use blue-green/first-stable-bootstrap/<app>
# check run) used to run BEFORE the mandatory "Verify LB target resolves
# to the node just deployed (infra#101 guard)" post-deploy step. If that
# guard failed, the workflow run failed -- but the success marker had
# already been written, so a retry of the bootstrap then refused with
# "bootstrap already used" even though the required deployment
# verification never actually completed, and bootstrap never creates
# :stable on that path either.
#
# Fix: the marker step now runs AFTER every required post-deploy guard,
# including the LB-target guard (in fact it is now the last step in the
# job). This locks in both halves of that fix so a future edit can't
# silently reintroduce the ordering bug:
#   1. the marker step is positioned after the LB-target guard step, and
#   2. the marker step's `if:` does not add `always()`/`failure()`, so
#      GitHub Actions' default "skip steps after a failed step" behavior
#      still applies -- a failed LB-target guard (or any earlier required
#      step) means the marker step never runs, full stop.

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

STEP_INFO_HELPER="$(mktemp)"
trap 'rm -f "$STEP_INFO_HELPER"' EXIT
cat > "$STEP_INFO_HELPER" <<'PYEOF'
import sys, yaml
workflow, job = sys.argv[1], sys.argv[2]
with open(workflow) as f:
    doc = yaml.safe_load(f)
steps = doc['jobs'][job]['steps']
names = [s.get('name', '') for s in steps]
field = sys.argv[3] if len(sys.argv) > 3 else None
if field is None:
    for n in names:
        print(n)
else:
    needle = sys.argv[4]
    matches = [i for i, n in enumerate(names) if needle in n]
    if not matches:
        sys.exit(f"no step containing '{needle}' in job '{job}'")
    idx = matches[0]
    if field == 'index':
        print(idx)
    elif field == 'is_last':
        print('true' if idx == len(steps) - 1 else 'false')
    elif field == 'if':
        print(steps[idx].get('if', ''))
    else:
        sys.exit(f"unknown field '{field}'")
PYEOF

step_index() {
  local job="$1" needle="$2"
  python3 "$STEP_INFO_HELPER" "$WORKFLOW" "$job" index "$needle"
}

step_is_last() {
  local job="$1" needle="$2"
  python3 "$STEP_INFO_HELPER" "$WORKFLOW" "$job" is_last "$needle"
}

step_if() {
  local job="$1" needle="$2"
  python3 "$STEP_INFO_HELPER" "$WORKFLOW" "$job" if "$needle"
}

echo "== deploy-app.yml: deploy-stable bootstrap marker runs after required post-deploy guards =="

assert "workflow file exists" \
  test -f "$WORKFLOW"

LB_GUARD_IDX="$(step_index deploy-stable "Verify LB target resolves")"
MARKER_IDX="$(step_index deploy-stable "Record first-stable bootstrap authorization")"

assert "deploy-stable: 'Record first-stable bootstrap authorization' step exists after the LB-target guard step (infra#101)" \
  test "$MARKER_IDX" -gt "$LB_GUARD_IDX"

assert "deploy-stable: the bootstrap marker step is the LAST step in the job (runs after every required post-deploy guard, not just the LB-target one)" \
  test "$(step_is_last deploy-stable "Record first-stable bootstrap authorization")" = "true"

MARKER_IF="$(step_if deploy-stable "Record first-stable bootstrap authorization")"
assert "deploy-stable: the bootstrap marker step's if: does not force it to run after a prior step failure (no always()/failure())" \
  bash -c '! printf "%s" "$1" | grep -qE "always\(\)|failure\(\)"' _ "$MARKER_IF"

assert "deploy-stable: the bootstrap marker step still gates on bootstrap_first_stable" \
  bash -c 'printf "%s" "$1" | grep -qF "bootstrap_first_stable"' _ "$MARKER_IF"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
