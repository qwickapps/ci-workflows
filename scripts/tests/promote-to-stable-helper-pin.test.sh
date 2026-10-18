#!/usr/bin/env bash
# Contract test for ci-workflows#203: shared helper scripts used by the
# reusable promote workflow must be read from the workflow's immutable SHA,
# while caller-owned deployment files remain in the caller checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
WORKFLOW="${WORKFLOW:-$ROOT/.github/workflows/promote-to-stable.yml}"

pass=0
fail=0

assert_contains() {
  local name="$1" needle="$2"
  if grep -Fq -- "$needle" "$WORKFLOW"; then
    echo "ok - $name"
    pass=$((pass + 1))
  else
    echo "not ok - $name"
    fail=$((fail + 1))
  fi
}

assert_count() {
  local name="$1" needle="$2" expected="$3"
  local actual
  actual=$(grep -Foc -- "$needle" "$WORKFLOW" || true)
  if [ "$actual" -eq "$expected" ]; then
    echo "ok - $name"
    pass=$((pass + 1))
  else
    echo "not ok - $name (expected $expected, got $actual)"
    fail=$((fail + 1))
  fi
}

assert_only_expected_path() {
  local name="$1" basename="$2" expected_path="$3"
  local unexpected
  unexpected=$(grep -F -- "$basename" "$WORKFLOW" | grep -Ev '^[[:space:]]*#' | grep -Fv -- "$expected_path" || true)
  if [ -z "$unexpected" ]; then
    echo "ok - $name"
    pass=$((pass + 1))
  else
    echo "not ok - $name"
    printf '%s\n' "$unexpected"
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local name="$1" needle="$2"
  if grep -Fq -- "$needle" "$WORKFLOW"; then
    echo "not ok - $name"
    fail=$((fail + 1))
  else
    echo "ok - $name"
    pass=$((pass + 1))
  fi
}

assert_contains "helper checkout targets shared repo" "repository: qwickapps/ci-workflows"
# shellcheck disable=SC2016 # GitHub expression is intentionally literal.
assert_contains "helper checkout is pinned to reusable workflow SHA" 'ref: ${{ github.job_workflow_sha }}'
assert_count "both helper checkouts target the shared repo" "repository: qwickapps/ci-workflows" 2
# shellcheck disable=SC2016 # GitHub expression is intentionally literal.
assert_count "both helper checkouts are pinned to reusable workflow SHA" 'ref: ${{ github.job_workflow_sha }}' 2
assert_count "both helper checkouts have an isolated path" "path: .ci-workflows" 2
assert_count "both helper checkouts sparse-check scripts" "sparse-checkout: |" 2
assert_count "both helper checkouts include scripts" "            scripts" 2
assert_count "every multiarch helper use comes from pinned checkout" ".ci-workflows/scripts/verify-multiarch-manifest.sh" 3
assert_only_expected_path "no multiarch helper use comes from caller checkout" "verify-multiarch-manifest.sh" ".ci-workflows/scripts/verify-multiarch-manifest.sh"
assert_count "every hostname helper use comes from pinned checkout" ".ci-workflows/scripts/rescope-ts-hostname.sh" 2
assert_only_expected_path "no hostname helper use comes from caller checkout" "rescope-ts-hostname.sh" ".ci-workflows/scripts/rescope-ts-hostname.sh"
assert_contains "caller deployment script remains caller-owned" ".github/scripts/deploy-from-ghcr.sh"
assert_not_contains "helper checkout never supplies caller deployment script" ".ci-workflows/.github/scripts/deploy-from-ghcr.sh"
assert_contains "caller runtime manifest input defaults to caller path" "default: '.qwickapps/runtime.env.manifest.yml'"
# shellcheck disable=SC2016 # Literal workflow fragments contain shell variables.
assert_contains "caller runtime manifest is checked before drift check" 'if [[ ! -f "$MANIFEST_PATH" ]]; then'
# shellcheck disable=SC2016 # Literal workflow fragments contain shell variables.
assert_contains "missing caller runtime manifest reports its path" '::error::Caller runtime manifest not found: $MANIFEST_PATH'
# shellcheck disable=SC2016 # Literal workflow fragments contain shell variables.
assert_contains "caller runtime manifest remains caller-owned" '--manifest-path "$MANIFEST_PATH"'
assert_not_contains "helper checkout never supplies caller runtime manifest" ".ci-workflows/.qwickapps/runtime.env.manifest.yml"
assert_contains "runner-owned drift helper is explicitly verified" "Verify protocols runtime available"
# shellcheck disable=SC2088 # Literal workflow path intentionally begins with a tilde.
assert_contains "runner-owned drift helper remains explicit" "~/.qwickapps/protocols/scripts/check-runtime-drift.sh"

echo
echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
