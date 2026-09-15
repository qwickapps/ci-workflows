#!/usr/bin/env bash
#
# Regression test for the ci-workflows#182 review findings on
# main-push-guard-multiarch.yml (introduced in #181): the
# "Validate package_manager input" step originally interpolated
# `${{ inputs.package_manager }}` directly into the shell via
# `case "${{ inputs.package_manager }}" in`. A value like
# `$(echo INJECTED >&2)npm` ran the injected command, evaluated to
# `npm`, passed validation, and then every install/build/test step
# (each individually gated on `inputs.package_manager == 'npm'|'pnpm'`)
# silently skipped, since the *raw, unexpanded* input string never
# equalled the literal `npm`/`pnpm` those `if:` conditions compare
# against — the Test job went green having run nothing. Round 3 found
# the same class of bug one step later: `image_name` was fixed at its
# own interpolation site, but its value still flowed unvalidated into
# `steps.meta.outputs.image_ref`, which the build step then
# re-interpolated with `${{ steps.meta.outputs.image_ref }}`.
#
# This test asserts:
#   1. Structural: the package_manager and platforms validation steps
#      pass their inputs through `env:` (not `${{ }}` interpolated into
#      `run:`), have the expected `if:`/no continue-on-error, and —
#      whole-file — no `run:` block anywhere in this workflow contains a
#      raw `${{ inputs.` or `${{ steps.` expression (round-3 LOW: a fix
#      at one interpolation site doesn't prove there isn't another).
#   2. Behavioral: both validation steps' own scripts, given a set of
#      valid and invalid values, actually accept/reject correctly —
#      including the exact injection PoCs from rounds 1-3.

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

echo "== main-push-guard-multiarch.yml: no input/output interpolated into a shell (ci-workflows#182) =="

assert "workflow file exists" \
  test -f "$WORKFLOW"

# --- Structural check: extract both validation steps' run: bodies via
# PyYAML, assert their shape, and scan every job's every run: block for a
# raw ${{ inputs. or ${{ steps. expression anywhere in the file. ---

PM_RUN_FILE="$(mktemp)"
PLATFORMS_RUN_FILE="$(mktemp)"
trap 'rm -f "$PM_RUN_FILE" "$PLATFORMS_RUN_FILE"' EXIT

if python3 - "$WORKFLOW" "$PM_RUN_FILE" "$PLATFORMS_RUN_FILE" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.stderr.write(
        "::error::PyYAML is required for this test; install with `pip install PyYAML`\n"
    )
    sys.exit(2)

path, pm_run_out, platforms_run_out = sys.argv[1], sys.argv[2], sys.argv[3]
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
# of the same fix; hold it to the same standard, and extract its script
# for the behavioral check below.
platforms_job = jobs.get("validate-platforms") or {}
platforms_steps = platforms_job.get("steps") or []
platforms_step = platforms_steps[0] if platforms_steps else {}
platforms_run = platforms_step.get("run") or ""
platforms_env = platforms_step.get("env") or {}
if "PLATFORMS" not in platforms_env:
    errors.append("validate-platforms's step has no env.PLATFORMS")
if platforms_step.get("continue-on-error"):
    errors.append("validate-platforms's step has continue-on-error: true")

# Whole-file scan (round-3 LOW): a fix at one interpolation site doesn't
# prove there isn't another -- e.g. round 3's image_name fix left
# steps.meta.outputs.image_ref (itself derived from inputs.image_name)
# interpolated one step later. No run: block anywhere in this file should
# contain a raw ${{ inputs. or ${{ steps. expression.
for job_name, job in jobs.items():
    if not isinstance(job, dict):
        continue
    for i, s in enumerate(job.get("steps") or []):
        if not isinstance(s, dict):
            continue
        run_text = s.get("run") or ""
        for bad in ("${{ inputs.", "${{ steps."):
            if bad in run_text:
                errors.append(
                    f"jobs.{job_name}.steps[{i}] ({s.get('name')!r}) run: still "
                    f"contains a raw {bad!r} expression -- pass it through env: instead"
                )

if errors:
    for e in errors:
        sys.stderr.write(f"FAIL: {e}\n")
    sys.exit(1)

with open(pm_run_out, "w", encoding="utf-8") as fh:
    fh.write(run)
with open(platforms_run_out, "w", encoding="utf-8") as fh:
    fh.write(platforms_run)
sys.exit(0)
PY
then
  echo "  PASS: both validation steps correctly shaped (exact if:, no continue-on-error, env-only), and no run: block anywhere in the file has a raw \${{ inputs. or \${{ steps. expression"
  pass=$((pass + 1))
else
  echo "  FAIL: validation step structure regressed, or a raw input/output expression reappeared in a run: block (see errors above)"
  fail=$((fail + 1))
  PM_RUN_FILE=""
  PLATFORMS_RUN_FILE=""
fi

# --- Behavioral check: actually execute both extracted scripts against a
# set of valid and invalid (including the reviews' injection PoCs) values. ---

run_pm_case() {
  local value="$1"
  PACKAGE_MANAGER="$value" bash "$PM_RUN_FILE" >/tmp/mpg-mp-test-out.$$ 2>&1
}

run_platforms_case() {
  local value="$1"
  PLATFORMS="$value" bash "$PLATFORMS_RUN_FILE" >/tmp/mpg-mp-test-out.$$ 2>&1
}

if [ -n "${PM_RUN_FILE:-}" ] && [ -s "$PM_RUN_FILE" ]; then
  for good in npm pnpm; do
    assert "PACKAGE_MANAGER='$good' is accepted (exit 0)" \
      run_pm_case "$good"
  done

  for bad in '' 'NPM' 'yarn' '$(echo INJECTED-VIA-CMDSUB >&2)npm'; do
    assert "PACKAGE_MANAGER='$bad' is rejected (non-zero exit, no code execution)" \
      bash -c '! PACKAGE_MANAGER="$1" bash "$2" >/tmp/mpg-mp-test-out.$$ 2>&1' _ "$bad" "$PM_RUN_FILE"

    assert "PACKAGE_MANAGER='$bad' never printed INJECTED-VIA-CMDSUB (injection did not run)" \
      bash -c '! grep -q INJECTED-VIA-CMDSUB /tmp/mpg-mp-test-out.$$ 2>/dev/null'
  done
else
  echo "  SKIP: package_manager behavioral checks skipped, structural check already failed"
fi

if [ -n "${PLATFORMS_RUN_FILE:-}" ] && [ -s "$PLATFORMS_RUN_FILE" ]; then
  for good in linux/amd64 linux/amd64,linux/arm64 linux/arm64/v7; do
    assert "PLATFORMS='$good' is accepted (exit 0)" \
      run_platforms_case "$good"
  done

  for bad in '' 'linux/amd64;id' '$(echo INJECTED-VIA-PLATFORMS >&2)linux/amd64' 'amd64'; do
    assert "PLATFORMS='$bad' is rejected (non-zero exit, no code execution)" \
      bash -c '! PLATFORMS="$1" bash "$2" >/tmp/mpg-mp-test-out.$$ 2>&1' _ "$bad" "$PLATFORMS_RUN_FILE"

    assert "PLATFORMS='$bad' never printed INJECTED-VIA-PLATFORMS (injection did not run)" \
      bash -c '! grep -q INJECTED-VIA-PLATFORMS /tmp/mpg-mp-test-out.$$ 2>/dev/null'
  done
else
  echo "  SKIP: platforms behavioral checks skipped, structural check already failed"
fi

rm -f /tmp/mpg-mp-test-out.$$

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
