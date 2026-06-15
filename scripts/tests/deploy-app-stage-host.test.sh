#!/usr/bin/env bash
# Regression coverage for ci-workflows#64 / infra#71:
# deploy-app.yml must own stage-to-CapRover host resolution.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/deploy-app.yml"

pass=0
fail=0

assert_contains() {
  local name="$1" needle="$2"
  if grep -Fq "$needle" "$WORKFLOW"; then
    echo "ok - $name"
    pass=$((pass + 1))
  else
    echo "not ok - $name"
    echo "  missing: $needle"
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local name="$1" needle="$2"
  if grep -Fq "$needle" "$WORKFLOW"; then
    echo "not ok - $name"
    echo "  forbidden: $needle"
    fail=$((fail + 1))
  else
    echo "ok - $name"
    pass=$((pass + 1))
  fi
}

assert_caprover_host_not_required() {
  local block
  block="$(awk '
    /^      caprover_host:/ { in_block = 1; next }
    /^      caprover_url:/ { in_block = 0 }
    in_block { print }
  ' "$WORKFLOW")"

  if grep -Fq "required: true" <<<"$block"; then
    echo "not ok - caprover_host is not required from callers"
    echo "  forbidden in caprover_host input block: required: true"
    fail=$((fail + 1))
  else
    echo "ok - caprover_host is not required from callers"
    pass=$((pass + 1))
  fi
}

assert_contains "build resolves to dev CapRover URL secret" 'CAPROVER_HOST_NAME="$OCI_DEV_CAPROVER_URL"'
assert_contains "uat/live resolve to main CapRover URL secret" 'CAPROVER_HOST_NAME="$OCI_MAIN_CAPROVER_URL"'
assert_contains "dev URL secret is read by resolve-stage" 'OCI_DEV_CAPROVER_URL: ${{ secrets.OCI_DEV_CAPROVER_URL }}'
assert_contains "main URL secret is read by resolve-stage" 'OCI_MAIN_CAPROVER_URL: ${{ secrets.OCI_MAIN_CAPROVER_URL }}'
assert_contains "CapRover-required stages fail when URL secret is missing" 'ERROR: OCI_DEV_CAPROVER_URL or OCI_MAIN_CAPROVER_URL secret missing'
assert_contains "legacy caprover_host emits warning" '::warning::caprover_host is deprecated and ignored'
assert_contains "legacy caprover_url emits warning" '::warning::caprover_url is deprecated and ignored'

assert_caprover_host_not_required
assert_not_contains "stage host never comes from caller caprover_host" 'CAPROVER_HOST_NAME="${{ inputs.caprover_host }}"'
assert_not_contains "deployment URL never comes from caller caprover_url" 'CP_URL="${{ inputs.caprover_url }}"'

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
