#!/usr/bin/env bash
# Sandbox test for bluegreen-residuals-300 Item 1:
#   configure-caprover-app.sh force-overrides TS_HOSTNAME for build slots.
# This is a jq-level dry-run — it tests the logic without a CapRover API call.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $name"
  else
    echo "not ok - $name"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    exit 1
  fi
}

get_ts_hostname() {
  echo "$1" | jq -r '.envVars[] | select(.key == "TS_HOSTNAME") | .value // ""'
}

# ── Test 1: orphan TS_HOSTNAME on build slot is corrected ──────────

cat > "$TMPDIR/def1.json" <<'JSON'
{
  "appName": "qwickapps-documents-build",
  "envVars": [
    {"key": "PORT", "value": "3300"},
    {"key": "TS_HOSTNAME", "value": "qwickapps-documents-prod"},
    {"key": "TS_AUTHKEY", "value": "tskey-xxx"}
  ]
}
JSON

RESULT1=$(jq --arg name "qwickapps-documents-build" '
  .envVars = (((.envVars // []) | map(select(.key != "TS_HOSTNAME"))) + [{key: "TS_HOSTNAME", value: $name}])
' "$TMPDIR/def1.json")

TS1=$(get_ts_hostname "$RESULT1")
assert_eq "orphan TS_HOSTNAME corrected to app name" "qwickapps-documents-build" "$TS1"

# ── Test 2: missing TS_HOSTNAME on build slot is added ────────────

cat > "$TMPDIR/def2.json" <<'JSON'
{
  "appName": "qwickapps-mcp-build",
  "envVars": [
    {"key": "PORT", "value": "8080"},
    {"key": "TS_AUTHKEY", "value": "tskey-yyy"}
  ]
}
JSON

RESULT2=$(jq --arg name "qwickapps-mcp-build" '
  .envVars = (((.envVars // []) | map(select(.key != "TS_HOSTNAME"))) + [{key: "TS_HOSTNAME", value: $name}])
' "$TMPDIR/def2.json")

TS2=$(get_ts_hostname "$RESULT2")
assert_eq "missing TS_HOSTNAME added as app name" "qwickapps-mcp-build" "$TS2"

# ── Test 3: correct TS_HOSTNAME on build slot is preserved ────────

cat > "$TMPDIR/def3.json" <<'JSON'
{
  "appName": "qwickapps-forge-build",
  "envVars": [
    {"key": "PORT", "value": "3300"},
    {"key": "TS_HOSTNAME", "value": "qwickapps-forge-build"},
    {"key": "TZ", "value": "UTC"}
  ]
}
JSON

RESULT3=$(jq --arg name "qwickapps-forge-build" '
  .envVars = (((.envVars // []) | map(select(.key != "TS_HOSTNAME"))) + [{key: "TS_HOSTNAME", value: $name}])
' "$TMPDIR/def3.json")

TS3=$(get_ts_hostname "$RESULT3")
assert_eq "correct TS_HOSTNAME kept as app name" "qwickapps-forge-build" "$TS3"

# ── Test 4: non-build slot is not affected ─────────────────────────

cat > "$TMPDIR/def4.json" <<'JSON'
{
  "appName": "qwickapps-documents-live",
  "envVars": [
    {"key": "TS_HOSTNAME", "value": "qwickapps-documents-live"}
  ]
}
JSON

# Simulate the guard: only apply when appName ends with -build
RESULT4=$(echo "$(cat "$TMPDIR/def4.json")" | jq --arg name "qwickapps-documents-live" '
  if ($name | endswith("-build")) then
    .envVars = (((.envVars // []) | map(select(.key != "TS_HOSTNAME"))) + [{key: "TS_HOSTNAME", value: $name}])
  else
    .
  end
')

TS4=$(get_ts_hostname "$RESULT4")
assert_eq "non-build slot unchanged" "qwickapps-documents-live" "$TS4"

echo ""
echo "All TS_HOSTNAME build-slot tests passed."
