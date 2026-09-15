#!/usr/bin/env bash
#
# Regression test for the ci-workflows#182 review finding on
# main-push-guard-multiarch.yml (introduced in #181): the
# "Validate package_manager input" step originally interpolated
# `${{ inputs.package_manager }}` directly into the shell via
# `case "${{ inputs.package_manager }}" in`. A value like
# `$(echo INJECTED >&2)npm` ran the injected command, evaluated to
# `npm`, passed validation, and then every install/build/test step
# (each individually gated on `inputs.package_manager == 'npm'|'pnpm'`)
# silently skipped, since the *raw, unexpanded* input string never
# equalled the literal `npm`/`pnpm` those `if:` conditions compare
# against — the Test job went green having run nothing.
#
# This test asserts both halves of the fix stay in place:
#   1. Structural: the validation step passes the input through `env:`
#      (not `${{ }}` interpolated into `run:`), so a future edit can't
#      silently reintroduce the injection.
#   2. Behavioral: the step's own script, given each of a set of valid
#      and invalid PACKAGE_MANAGER values, actually accepts/rejects
#      correctly — including the exact injection PoC from the review.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/main-push-guard-multiarch.yml"

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

echo "== main-push-guard-multiarch.yml: package_manager validation is injection-safe (ci-workflows#182) =="

assert "workflow file exists" \
  test -f "$WORKFLOW"

# --- Structural check: extract the validation step's run: body via PyYAML,
# assert it exists, is the first step of jobs.test, takes no `${{ }}`
# expression directly in its script, and reads PACKAGE_MANAGER from env. ---

RUN_BODY_FILE="$(mktemp)"
trap 'rm -f "$RUN_BODY_FILE"' EXIT

if python3 - "$WORKFLOW" "$RUN_BODY_FILE" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.stderr.write(
        "::error::PyYAML is required for this test; install with `pip install PyYAML`\n"
    )
    sys.exit(2)

path, run_body_out = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)

jobs = doc.get("jobs") or {}
test_job = jobs.get("test") or {}
steps = test_job.get("steps") or []

errors = []

if not steps:
    errors.append("jobs.test has no steps")
    step = {}
else:
    step = steps[0]
    if step.get("name") != "Validate package_manager input":
        errors.append(
            f"jobs.test.steps[0].name is {step.get('name')!r}, "
            "expected 'Validate package_manager input' (must run first, "
            "before any checkout/install step)"
        )

run = step.get("run") or ""
if "${{" in run:
    errors.append(
        "the validation step's run: script still contains a raw '${{' "
        "expression -- inputs must be passed through env:, never "
        "interpolated directly into the shell"
    )

env = step.get("env") or {}
if "PACKAGE_MANAGER" not in env:
    errors.append("the validation step has no env.PACKAGE_MANAGER")
elif env["PACKAGE_MANAGER"] != "${{ inputs.package_manager }}":
    errors.append(
        f"env.PACKAGE_MANAGER is {env['PACKAGE_MANAGER']!r}, "
        "expected '${{ inputs.package_manager }}'"
    )

# A step whose `if:` no longer matches exactly, or that gained
# `continue-on-error: true`, lets Test go green without the validation
# ever actually running or ever actually failing the job (round-2 LOW).
expected_if = "inputs.language == 'ts' || inputs.language == 'js'"
if str(step.get("if", "")) != expected_if:
    errors.append(
        f"the validation step's if: is {step.get('if')!r}, expected "
        f"{expected_if!r} exactly -- a narrower condition would let it "
        "silently not run for some ts/js callers"
    )
if step.get("continue-on-error"):
    errors.append(
        "the validation step has continue-on-error: true -- a failed "
        "validation would no longer fail the job"
    )

# The platforms validation step (validate-platforms job) is the other half
# of the same fix; hold it to the same no-interpolation standard.
platforms_job = jobs.get("validate-platforms") or {}
platforms_steps = platforms_job.get("steps") or []
platforms_step = platforms_steps[0] if platforms_steps else {}
platforms_run = platforms_step.get("run") or ""
platforms_env = platforms_step.get("env") or {}
if "${{" in platforms_run:
    errors.append(
        "validate-platforms's run: script still contains a raw '${{' "
        "expression -- PLATFORMS must be passed through env:, never "
        "interpolated directly into the shell"
    )
if "PLATFORMS" not in platforms_env:
    errors.append("validate-platforms's step has no env.PLATFORMS")

if errors:
    for e in errors:
        sys.stderr.write(f"FAIL: {e}\n")
    sys.exit(1)

with open(run_body_out, "w", encoding="utf-8") as fh:
    fh.write(run)
sys.exit(0)
PY
then
  echo "  PASS: validation step is jobs.test's first step (exact if:, no continue-on-error), no raw \${{ }} in either validation step's script, both read from env"
  pass=$((pass + 1))
else
  echo "  FAIL: validation step structure regressed (see errors above)"
  fail=$((fail + 1))
  RUN_BODY_FILE=""
fi

# --- Behavioral check: actually execute the extracted script against a set
# of valid and invalid (including the review's injection PoC) values. ---

run_case() {
  local value="$1"
  PACKAGE_MANAGER="$value" bash "$RUN_BODY_FILE" >/tmp/mpg-mp-test-out.$$ 2>&1
}

if [ -n "${RUN_BODY_FILE:-}" ] && [ -s "$RUN_BODY_FILE" ]; then
  for good in npm pnpm; do
    assert "PACKAGE_MANAGER='$good' is accepted (exit 0)" \
      run_case "$good"
  done

  for bad in '' 'NPM' 'yarn' '$(echo INJECTED-VIA-CMDSUB >&2)npm'; do
    assert "PACKAGE_MANAGER='$bad' is rejected (non-zero exit, no code execution)" \
      bash -c '! PACKAGE_MANAGER="$1" bash "$2" >/tmp/mpg-mp-test-out.$$ 2>&1' _ "$bad" "$RUN_BODY_FILE"

    assert "PACKAGE_MANAGER='$bad' never printed INJECTED-VIA-CMDSUB (injection did not run)" \
      bash -c '! grep -q INJECTED-VIA-CMDSUB /tmp/mpg-mp-test-out.$$ 2>/dev/null'
  done
  rm -f /tmp/mpg-mp-test-out.$$
else
  echo "  SKIP: behavioral checks skipped, structural check already failed"
fi

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
