#!/usr/bin/env bash
# Regression checks for qwickapps/ci-workflows#146: qwickway route setup
# must avoid restart cascades and must proactively reap stale/suffixed
# ephemeral Tailscale registrations before the one intentional restart.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/setup-qwickway-route.sh"

pass=0
fail=0

assert() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok - $name"
    pass=$((pass + 1))
  else
    echo "not ok - $name"
    fail=$((fail + 1))
  fi
}

assert_not_grep_fixed() {
  local name="$1" needle="$2" file="$3"
  if grep -Fq "$needle" "$file"; then
    echo "not ok - $name"
    fail=$((fail + 1))
  else
    echo "ok - $name"
    pass=$((pass + 1))
  fi
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $name"
    pass=$((pass + 1))
  else
    echo "not ok - $name"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    fail=$((fail + 1))
  fi
}

assert "defines a Tailscale hostname-family reaper" \
  grep -q 'tailscale_reap_hostname_family()' "$SCRIPT"

assert "uses the real TS API key variable, not a masked literal header" \
  grep -Fq 'Authorization: Bearer ${api_key}' "$SCRIPT"

MASKED_NEEDLE='Authorization: Bearer ***'
assert_not_grep_fixed "does not contain literal masked Tailscale API auth in the reaper" \
  "$MASKED_NEEDLE" "$SCRIPT"

assert "matches exact hostnames" \
  grep -Fq 'ascii_downcase) == $h' "$SCRIPT"

assert "matches numeric suffix hostnames" \
  grep -Fq 'test("^" + $h + "-[0-9]+$")' "$SCRIPT"

assert "also matches FQDN/name variants" \
  grep -Fq 'test("^" + $h + "(-[0-9]+)?\\.")' "$SCRIPT"

UPDATE_COUNT=$(grep -c '/api/v2/user/apps/appDefinitions/update' "$SCRIPT")
assert_eq "setup performs only one restart-inducing appDefinitions/update" "1" "$UPDATE_COUNT"

assert "skips app-definition update when desired state already matches" \
  grep -q 'skipping restart-inducing update' "$SCRIPT"

REAP_LINE=$(grep -n 'tailscale_reap_hostname_family' "$SCRIPT" | tail -1 | cut -d: -f1)
UPDATE_LINE=$(grep -n '/api/v2/user/apps/appDefinitions/update' "$SCRIPT" | tail -1 | cut -d: -f1)
assert "reaps Tailscale hostname family before the app-definition update" \
  test "$REAP_LINE" -lt "$UPDATE_LINE"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
