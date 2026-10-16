#!/usr/bin/env bash
# Contract test for ci-workflows#203: shared helper scripts used by the
# reusable promote workflow must be read from the workflow's immutable SHA,
# while caller-owned deployment files remain in the caller checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
WORKFLOW="$ROOT/.github/workflows/promote-to-stable.yml"

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

assert_contains "helper checkout targets shared repo" "repository: qwickapps/ci-workflows"
# shellcheck disable=SC2016 # GitHub expression is intentionally literal.
assert_contains "helper checkout is pinned to reusable workflow SHA" 'ref: ${{ github.job_workflow_sha }}'
assert_contains "helper checkout has an isolated path" "path: .qwickapps/ci-workflows"
assert_contains "multiarch helper comes from pinned checkout" ".qwickapps/ci-workflows/scripts/verify-multiarch-manifest.sh"
assert_contains "hostname helper comes from pinned checkout" ".qwickapps/ci-workflows/scripts/rescope-ts-hostname.sh"
assert_contains "caller deployment script remains caller-owned" ".github/scripts/deploy-from-ghcr.sh"
assert_contains "caller runtime manifest remains caller-owned" "--manifest-path .qwickapps/runtime.env.manifest.yml"

echo
echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]