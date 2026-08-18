#!/usr/bin/env bash
# Unit test for scripts/verify-ts-lb-target.sh's select_live_target() filter
# (qwickapps/infrastructure#101 deploy guard). Pure jq-level test against
# fixture device-list JSON — no real Tailscale API calls, no real hostnames.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT

# Source only the function definitions — main() is guarded and never runs
# because BASH_SOURCE != $0 when sourced.
# shellcheck source=/dev/null
source "$ROOT/scripts/verify-ts-lb-target.sh"

pass=0
fail=0

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

# ── Fixture 1: exactly one live device holding the canonical name ─────────
# (the healthy, structurally-correct case)
FIXTURE_OK='{
  "devices": [
    {"hostname": "qwickapps-mcp-build", "id": "111", "created": "2026-08-18T14:00:00Z", "authorized": true, "connectedToControl": true},
    {"hostname": "qwickapps-mcp-build-1", "id": "222", "created": "2026-08-14T09:06:53Z", "authorized": true, "connectedToControl": false},
    {"hostname": "unrelated-service", "id": "333", "created": "2026-08-01T00:00:00Z", "authorized": true, "connectedToControl": true}
  ]
}'
RESULT_OK=$(select_live_target "$FIXTURE_OK" "qwickapps-mcp-build")
assert_eq "one live canonical-named device -> OK" "OK qwickapps-mcp-build 111 2026-08-18T14:00:00Z" "$RESULT_OK"

# ── Fixture 2: zero live devices (all offline corpses) ─────────────────────
FIXTURE_NONE_LIVE='{
  "devices": [
    {"hostname": "qwickapps-mcp-build", "id": "111", "created": "2026-08-14T09:06:49Z", "authorized": true, "connectedToControl": false},
    {"hostname": "qwickapps-mcp-build-1", "id": "222", "created": "2026-08-14T09:06:53Z", "authorized": true, "connectedToControl": false}
  ]
}'
RESULT_NONE=$(select_live_target "$FIXTURE_NONE_LIVE" "qwickapps-mcp-build")
assert_eq "all offline -> FAIL_NONE_LIVE" "FAIL_NONE_LIVE" "$RESULT_NONE"

# ── Fixture 3: two devices simultaneously connected (ambiguous LB target) ──
FIXTURE_AMBIGUOUS='{
  "devices": [
    {"hostname": "qwickapps-projects", "id": "111", "created": "2026-08-18T05:56:00Z", "authorized": true, "connectedToControl": true},
    {"hostname": "qwickapps-projects-5", "id": "222", "created": "2026-08-18T05:59:00Z", "authorized": true, "connectedToControl": true}
  ]
}'
RESULT_AMBIG=$(select_live_target "$FIXTURE_AMBIGUOUS" "qwickapps-projects")
assert_eq "two connected at once -> FAIL_AMBIGUOUS 2" "FAIL_AMBIGUOUS 2" "$RESULT_AMBIG"

# ── Fixture 4: the only live device has a suffixed hostname (canonical name
# not reclaimed — the exact infra#101 failure mode) ─────────────────────────
FIXTURE_SUFFIXED='{
  "devices": [
    {"hostname": "qwickapps-projects", "id": "111", "created": "2026-08-11T15:39:00Z", "authorized": true, "connectedToControl": false},
    {"hostname": "qwickapps-projects-5", "id": "222", "created": "2026-08-18T05:59:00Z", "authorized": true, "connectedToControl": true}
  ]
}'
RESULT_SUFFIXED=$(select_live_target "$FIXTURE_SUFFIXED" "qwickapps-projects")
assert_eq "only live device is suffixed -> FAIL_SUFFIXED" "FAIL_SUFFIXED qwickapps-projects-5 222 2026-08-18T05:59:00Z" "$RESULT_SUFFIXED"

# ── Fixture 5: unauthorized device must not count as live ──────────────────
FIXTURE_UNAUTHORIZED='{
  "devices": [
    {"hostname": "qwickapps-mcp-build", "id": "111", "created": "2026-08-18T14:00:00Z", "authorized": false, "connectedToControl": true}
  ]
}'
RESULT_UNAUTH=$(select_live_target "$FIXTURE_UNAUTHORIZED" "qwickapps-mcp-build")
assert_eq "unauthorized device excluded -> FAIL_NONE_LIVE" "FAIL_NONE_LIVE" "$RESULT_UNAUTH"

# ── Fixture 6: case-insensitive hostname match (real device found live —
# Tailscale's `hostname` display field is not guaranteed lowercase, e.g.
# "MacMini-DevServer") ───────────────────────────────────────────────────
FIXTURE_MIXED_CASE='{
  "devices": [
    {"hostname": "MacMini-DevServer", "id": "444", "created": "2025-12-20T04:38:07Z", "authorized": true, "connectedToControl": true}
  ]
}'
RESULT_CASE=$(select_live_target "$FIXTURE_MIXED_CASE" "macmini-devserver")
assert_eq "case-insensitive hostname match -> OK" "OK MacMini-DevServer 444 2025-12-20T04:38:07Z" "$RESULT_CASE"

# ── Fixture 7: parse_created_epoch() must be UTC regardless of host TZ ─────
# (infra#101 live bug: on macOS/BSD `date`, the `-j -f` fallback silently
# parsed "Z"-suffixed timestamps as LOCAL time, inflating the epoch by the
# host's UTC offset on the org's America/New_York runners. This defeated the
# freshness check -- a deliberately-future --deploy-start-epoch, which must
# always fail, instead passed. Force TZ to a non-UTC zone here so this test
# fails the same way the live bug did if the `-u` fix regresses.)
KNOWN_UTC_TS="2026-08-18T14:00:00Z"
KNOWN_UTC_EPOCH="1787061600"   # date -u -d "2026-08-18T14:00:00Z" +%s
PARSED_EPOCH_NY=$(TZ="America/New_York" parse_created_epoch "$KNOWN_UTC_TS")
assert_eq "parse_created_epoch is UTC under TZ=America/New_York" "$KNOWN_UTC_EPOCH" "$PARSED_EPOCH_NY"

PARSED_EPOCH_TOKYO=$(TZ="Asia/Tokyo" parse_created_epoch "$KNOWN_UTC_TS")
assert_eq "parse_created_epoch is UTC under TZ=Asia/Tokyo" "$KNOWN_UTC_EPOCH" "$PARSED_EPOCH_TOKYO"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
