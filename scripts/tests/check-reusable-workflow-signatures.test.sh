#!/usr/bin/env bash
#
# Regression + false-positive tests for
# scripts/check-reusable-workflow-signatures.sh (ci-workflows#175 guard).
#
# ci-workflows#175: commit 90e0adf9226dcc426750a7785feba7301285d515 rewrote
# main-push-guard.yml from a reusable workflow (on.workflow_call, inputs
# like `image_name`, secrets like `GHCR_PUSH_TOKEN`) into a plain `on.push`
# thin wrapper -- silently dropping its entire callable interface -- while
# 6 dependent repos were still calling it as a reusable workflow with the
# old inputs/secrets. Nothing compared the interface before vs after, so
# the break wasn't noticed for hours. Last-known-good commit was
# 28e9f941223e5ec54bfacd159bf3be0b86506376.
#
# Tests:
#   1. The real historical incident: comparing 28e9f941 (base) against
#      90e0adf9 (breaking commit) must FAIL, and must name
#      main-push-guard.yml and the removed workflow_call interface.
#   2. False positive check: comparing the merge-base with origin/main
#      against the current working tree (this branch, including this very
#      guard's own new files) must PASS -- adding unrelated new files, or a
#      brand-new reusable workflow, must never trip the guard.
#   3. Synthetic unit test: a reusable workflow file that keeps
#      on.workflow_call but renames one input key (add + remove within the
#      same section, net key count unchanged) must FAIL -- proving this
#      isn't just a removal-count check.
#   4. Synthetic unit test: a reusable workflow file whose signature is
#      byte-for-byte re-formatted (key order / quoting changed) but whose
#      key SETS are identical must PASS -- proving the guard compares sets,
#      not YAML formatting or text.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
GUARD="$SCRIPTS_DIR/check-reusable-workflow-signatures.sh"

INCIDENT_BASE_SHA="28e9f941223e5ec54bfacd159bf3be0b86506376"
INCIDENT_BREAKING_SHA="90e0adf9226dcc426750a7785feba7301285d515"

indent() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    printf '    %s\n' "$line"
  done
}

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

echo "== check-reusable-workflow-signatures.sh regression tests (ci-workflows#175) =="

assert "guard script exists" \
  test -f "$GUARD"

# --- Test 1: the real historical incident must be caught -------------------
echo ""
echo "-- Test 1: real incident ($INCIDENT_BASE_SHA -> $INCIDENT_BREAKING_SHA) --"

cd "$ROOT_DIR"
if git rev-parse --verify --quiet "${INCIDENT_BASE_SHA}^{commit}" >/dev/null \
  && git rev-parse --verify --quiet "${INCIDENT_BREAKING_SHA}^{commit}" >/dev/null; then

  incident_out="$(BASE_REF="$INCIDENT_BASE_SHA" HEAD_REF="$INCIDENT_BREAKING_SHA" bash "$GUARD" 2>&1)" && incident_rc=0 || incident_rc=$?
  printf '%s\n' "$incident_out" | indent

  assert "incident: guard exits non-zero (FAILs)" \
    test "$incident_rc" -ne 0
  assert "incident: names main-push-guard.yml" \
    grep -q "main-push-guard.yml" <<<"$incident_out"
  assert "incident: reports the interface as removed" \
    grep -qi "removed" <<<"$incident_out"
  assert "incident: shows the lost inputs (image_name)" \
    grep -q "image_name" <<<"$incident_out"
  assert "incident: shows the lost secret (GHCR_PUSH_TOKEN)" \
    grep -q "GHCR_PUSH_TOKEN" <<<"$incident_out"
else
  echo "  SKIP: historical fixture commits not present in this checkout (need full history)"
fi

# --- Test 2: false positive check on the current repo state ----------------
echo ""
echo "-- Test 2: false-positive check (current branch vs origin/main) --"

cd "$ROOT_DIR"
if git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
  merge_base="$(git merge-base origin/main HEAD 2>/dev/null || echo origin/main)"
  clean_out="$(BASE_REF="$merge_base" bash "$GUARD" 2>&1)" && clean_rc=0 || clean_rc=$?
  printf '%s\n' "$clean_out" | indent

  assert "current repo state: guard exits zero (PASSes)" \
    test "$clean_rc" -eq 0
else
  echo "  SKIP: origin/main not available in this checkout"
fi

# --- Test 3 & 4: synthetic fixtures in a scratch git repo -------------------
echo ""
echo "-- Test 3 & 4: synthetic fixtures (scratch repo) --"

SCRATCH_DIR="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH_DIR"; }
trap cleanup EXIT

(
  cd "$SCRATCH_DIR"
  git init -q
  git config user.email "test@example.com"
  git config user.name "test"
  mkdir -p .github/workflows

  cat > .github/workflows/fixture.yml <<'YAML'
name: Fixture
on:
  workflow_call:
    inputs:
      image_name:
        required: true
        type: string
    secrets:
      TOKEN:
        required: true
YAML
  git add -A
  git commit -q -m "base"
  git tag fixture-base

  # Test 3: rename image_name -> image_ref (same count, different keys)
  cat > .github/workflows/fixture.yml <<'YAML'
name: Fixture
on:
  workflow_call:
    inputs:
      image_ref:
        required: true
        type: string
    secrets:
      TOKEN:
        required: true
YAML
  git add -A
  git commit -q -m "rename input key"
  git tag fixture-renamed
)

rename_out="$(cd "$SCRATCH_DIR" && BASE_REF=fixture-base HEAD_REF=fixture-renamed bash "$GUARD" 2>&1)" && rename_rc=0 || rename_rc=$?
printf '%s\n' "$rename_out" | indent
assert "synthetic rename: guard exits non-zero (FAILs)" \
  test "$rename_rc" -ne 0
assert "synthetic rename: reports the old key (image_name)" \
  grep -q "image_name" <<<"$rename_out"
assert "synthetic rename: reports the new key (image_ref)" \
  grep -q "image_ref" <<<"$rename_out"

(
  cd "$SCRATCH_DIR"
  # Test 4: same keys, reformatted YAML (quoting + key order) -> must PASS
  cat > .github/workflows/fixture.yml <<'YAML'
name: Fixture
on:
  workflow_call:
    secrets:
      TOKEN:
        required: true
    inputs:
      "image_ref":
        type: string
        required: true
YAML
  git add -A
  git commit -q -m "reformat only"
  git tag fixture-reformatted
)

reformat_out="$(cd "$SCRATCH_DIR" && BASE_REF=fixture-renamed HEAD_REF=fixture-reformatted bash "$GUARD" 2>&1)" && reformat_rc=0 || reformat_rc=$?
printf '%s\n' "$reformat_out" | indent
assert "synthetic reformat-only: guard exits zero (PASSes)" \
  test "$reformat_rc" -eq 0

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
