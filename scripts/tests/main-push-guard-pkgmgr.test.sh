#!/usr/bin/env bash
#
# Regression tests for ci-workflows#139: main-push-guard.yml hardcoded pnpm
# for every `language: ts | js` caller (npm install -g pnpm; pnpm install
# --frozen-lockfile unconditionally). The org is genuinely mixed — protocols/
# mcp/ide carry both pnpm-lock.yaml and package-lock.json, forge is pnpm-only,
# projects/agents are npm-only with no pnpm-lock.yaml anywhere in the tree —
# so the hardcoded assumption made every npm-only repo's build-once/Test job
# fail closed with ERR_PNPM_NO_LOCKFILE on every push to main. Two
# security-motivated dependency bumps on qwickapps/agents had to be merged
# manually around a red guard because of this.
#
# Fix: detect the package manager from the checked-out lockfile
# (pnpm-lock.yaml -> pnpm, package-lock.json -> npm, neither -> fail loudly)
# instead of assuming pnpm.
#
# This extracts the "Detect package manager" step's actual `run:` script from
# the YAML (same technique main-push-guard-outputs.test.sh uses for the
# `outputs` block) and executes it against synthetic fixture directories, so
# a future edit that breaks the detection logic itself — not just its
# presence in the file — fails this test.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/main-push-guard.yml"

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

echo "== main-push-guard.yml: package-manager detection (ci-workflows#139) =="

assert "workflow file exists" \
  test -f "$WORKFLOW"

# Extract the "Detect package manager" step's `run:` block via PyYAML so this
# test runs the ACTUAL script in the workflow, not a hand-copied reimplementation.
DETECT_SCRIPT="$(mktemp)"
trap 'rm -f "$DETECT_SCRIPT"' EXIT

python3 - "$WORKFLOW" "$DETECT_SCRIPT" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.stderr.write("::error::PyYAML is required for this test; install with `pip install PyYAML`\n")
    sys.exit(2)

workflow_path, out_path = sys.argv[1], sys.argv[2]
with open(workflow_path, "r", encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)

steps = ((doc.get("jobs") or {}).get("test") or {}).get("steps") or []
detect_steps = [s for s in steps if s.get("name") == "Detect package manager"]

if len(detect_steps) != 1:
    sys.stderr.write(f"FAIL: expected exactly one 'Detect package manager' step in jobs.test.steps, found {len(detect_steps)}\n")
    sys.exit(1)

step = detect_steps[0]
run = step.get("run")
if not run:
    sys.stderr.write("FAIL: 'Detect package manager' step has no 'run' script\n")
    sys.exit(1)

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(run)

sys.exit(0)
PY

assert "'Detect package manager' step exists with a run script" \
  test -s "$DETECT_SCRIPT"

run_detect() {
  # Mirrors what the real step does: run in a fixture dir, capture what it
  # would have appended to $GITHUB_OUTPUT.
  local fixture_dir="$1"
  local out_file
  out_file="$(mktemp)"
  ( cd "$fixture_dir" && GITHUB_OUTPUT="$out_file" bash "$DETECT_SCRIPT" )
  local rc=$?
  cat "$out_file"
  rm -f "$out_file"
  return $rc
}

FIXTURE_PNPM="$(mktemp -d)"
FIXTURE_NPM="$(mktemp -d)"
FIXTURE_BOTH="$(mktemp -d)"
FIXTURE_NEITHER="$(mktemp -d)"
trap 'rm -f "$DETECT_SCRIPT"; rm -rf "$FIXTURE_PNPM" "$FIXTURE_NPM" "$FIXTURE_BOTH" "$FIXTURE_NEITHER"' EXIT

: > "$FIXTURE_PNPM/pnpm-lock.yaml"
: > "$FIXTURE_NPM/package-lock.json"
: > "$FIXTURE_BOTH/pnpm-lock.yaml"
: > "$FIXTURE_BOTH/package-lock.json"

pnpm_output="$(run_detect "$FIXTURE_PNPM" 2>/dev/null || true)"
assert "pnpm-lock.yaml only -> manager=pnpm" \
  test "$pnpm_output" = "manager=pnpm"

npm_output="$(run_detect "$FIXTURE_NPM" 2>/dev/null || true)"
assert "package-lock.json only (real qwickapps/agents shape) -> manager=npm" \
  test "$npm_output" = "manager=npm"

both_output="$(run_detect "$FIXTURE_BOTH" 2>/dev/null || true)"
assert "both lockfiles present (real qwickapps/protocols shape) -> manager=pnpm (pnpm checked first)" \
  test "$both_output" = "manager=pnpm"

if run_detect "$FIXTURE_NEITHER" >/dev/null 2>&1; then
  fail=$((fail + 1))
  echo "  FAIL: neither lockfile present -> should exit nonzero (fail loud), exited 0"
else
  pass=$((pass + 1))
  echo "  PASS: neither lockfile present -> exits nonzero (fail loud), does not default to either manager"
fi

# Step-conditional wiring: the pnpm-only install/build/test steps must be
# gated on steps.pkgmgr.outputs.manager == 'pnpm' (not just language), and an
# npm equivalent must exist -- otherwise an npm-only repo would still hit a
# missing `pnpm` binary or ERR_PNPM_NO_LOCKFILE downstream of a correct
# detection.
assert "'Install dependencies (pnpm)' step is gated on manager == pnpm" \
  grep -q "Install dependencies (pnpm)" "$WORKFLOW"
assert "'Install dependencies (npm)' step exists (npm ci)" \
  grep -q "Install dependencies (npm)" "$WORKFLOW"
assert "npm install path uses 'npm ci' (respects the committed lockfile, like --frozen-lockfile)" \
  grep -q "run: npm ci" "$WORKFLOW"
assert "'Install pnpm' step is gated on manager == pnpm (not installed for npm-only repos)" \
  grep -q "steps.pkgmgr.outputs.manager == 'pnpm'" "$WORKFLOW"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
