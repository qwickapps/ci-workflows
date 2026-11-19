#!/usr/bin/env bash
# Runs every regression suite that covers the Momo Coolify secondary lane and
# the primary-lane invariants it must not disturb. Exits nonzero on any failure.
set -uo pipefail
cd "$(dirname "$0")/../.."
FAILED=()
for t in scripts/tests/deploy-app-stage-host-gate.test.sh \
         scripts/tests/deploy-app-coolify-secondary.test.sh \
         scripts/tests/deploy-app-ts-api-key-fallback.test.sh \
         scripts/tests/deploy-app-no-artifact-env-handoff.test.sh \
         scripts/tests/deploy-stable-caprover.test.sh \
         scripts/tests/topology-*.test.sh; do
  echo "== $t"
  if bash "$t" > "${TMPDIR:-/tmp}/suite.out" 2>&1; then tail -2 "${TMPDIR:-/tmp}/suite.out"; else tail -25 "${TMPDIR:-/tmp}/suite.out"; FAILED+=("$t"); fi
done
for t in scripts/tests/coolify-validation-safety.test.py \
         scripts/tests/validate-coolify-token-exclusivity.test.py \
         scripts/tests/coolify-validation-evidence.test.py \
         scripts/tests/lane-regression.test.py; do
  [ -f "$t" ] || continue
  echo "== $t"
  if python3 "$t" > "${TMPDIR:-/tmp}/suite.out" 2>&1; then tail -2 "${TMPDIR:-/tmp}/suite.out"; else tail -25 "${TMPDIR:-/tmp}/suite.out"; FAILED+=("$t"); fi
done
echo "== token exclusivity policy"
python3 scripts/validate-coolify-token-exclusivity.py --root . || FAILED+=(token-policy)
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "FAILED: ${FAILED[*]}"
  exit 1
fi
echo "ALL SUITES PASSED"
