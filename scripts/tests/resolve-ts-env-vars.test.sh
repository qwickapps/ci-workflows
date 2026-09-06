#!/usr/bin/env bash
#
# Regression test for scripts/lib/resolve-ts-env-vars.sh — the
# EXISTING_*/EFFECTIVE_*/append-conditional Tailscale env-var preserve-on-
# partial-write logic shared by scripts/setup-qwickway-route.sh.
#
# Two separate incidents were caused by exactly one class of bug: a TS_* var
# added later ("this one doesn't have the same protection as its siblings"):
#   - qwickapps/ci-workflows#22 (original): TS_AUTHKEY/TS_EPHEMERAL_AUTHKEY/
#     TS_HOSTNAME/TS_TAGS getting wiped
#   - qwickapps/ci-workflows#131/#132: TS_API_KEY getting wiped the same way,
#     because it wasn't included when the pattern was extended for the first
#     four vars
#
# This covers all five current vars with the three cases the resolution order
# defines: explicit flag wins, falls back to the existing app-definition
# value, omitted entirely when neither is present (qwickapps/ci-workflows#133).
#
# TS_EPHEMERAL_AUTHKEY gained a CLI flag in brain#34 (setup-qwickway-route.sh's
# --ts-ephemeral-authkey) so a caller can opt an app INTO an ephemeral
# Tailscale identity, not just preserve whatever it already had -- needed for
# qwickway LB apps, whose container restarts on every provisioning run and
# which otherwise accumulate duplicate non-ephemeral devices under the same
# hostname run over run. It now has all three cases like its siblings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/resolve-ts-env-vars.sh
source "$SCRIPTS_DIR/lib/resolve-ts-env-vars.sh"

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

# Build a CapRover app-definition envVars JSON with one existing TS_* entry.
current_def_with() {
  local key="$1" value="$2"
  jq -n --arg k "$key" --arg v "$value" '{envVars: [{key: $k, value: $v}]}'
}

EMPTY_DEF='{"envVars": []}'
BASE_ENV_VARS='[]'

value_for_key() {
  local env_vars_json="$1" key="$2"
  echo "$env_vars_json" | jq -r --arg k "$key" '.[] | select(.key == $k) | .value // empty'
}

has_key() {
  local env_vars_json="$1" key="$2"
  local count
  count=$(echo "$env_vars_json" | jq --arg k "$key" '[.[] | select(.key == $k)] | length')
  [[ "$count" -gt 0 ]]
}

lacks_key() {
  ! has_key "$@"
}

echo "== TS_AUTHKEY =="
result=$(resolve_ts_env_vars "$(current_def_with TS_AUTHKEY existing-authkey)" "$BASE_ENV_VARS" "explicit-authkey" "" "" "" 2>/dev/null)
assert "explicit flag wins over existing" \
  test "$(value_for_key "$result" TS_AUTHKEY)" = "explicit-authkey"

result=$(resolve_ts_env_vars "$(current_def_with TS_AUTHKEY existing-authkey)" "$BASE_ENV_VARS" "" "" "" "" 2>/dev/null)
assert "falls back to existing app-definition value when no flag given" \
  test "$(value_for_key "$result" TS_AUTHKEY)" = "existing-authkey"

result=$(resolve_ts_env_vars "$EMPTY_DEF" "$BASE_ENV_VARS" "" "" "" "" 2>/dev/null)
assert "omitted entirely when neither flag nor existing value is present" \
  lacks_key "$result" TS_AUTHKEY

echo "== TS_EPHEMERAL_AUTHKEY (brain#34) =="
result=$(resolve_ts_env_vars "$(current_def_with TS_EPHEMERAL_AUTHKEY existing-eph)" "$BASE_ENV_VARS" "" "" "" "" "explicit-eph" 2>/dev/null)
assert "explicit flag wins over existing" \
  test "$(value_for_key "$result" TS_EPHEMERAL_AUTHKEY)" = "explicit-eph"

result=$(resolve_ts_env_vars "$(current_def_with TS_EPHEMERAL_AUTHKEY existing-eph)" "$BASE_ENV_VARS" "" "" "" "" 2>/dev/null)
assert "falls back to existing app-definition value when no flag given" \
  test "$(value_for_key "$result" TS_EPHEMERAL_AUTHKEY)" = "existing-eph"

result=$(resolve_ts_env_vars "$EMPTY_DEF" "$BASE_ENV_VARS" "" "" "" "" 2>/dev/null)
assert "omitted entirely when neither flag nor existing value is present" \
  lacks_key "$result" TS_EPHEMERAL_AUTHKEY

echo "== TS_HOSTNAME =="
result=$(resolve_ts_env_vars "$(current_def_with TS_HOSTNAME existing-host)" "$BASE_ENV_VARS" "" "explicit-host" "" "" 2>/dev/null)
assert "explicit flag wins over existing" \
  test "$(value_for_key "$result" TS_HOSTNAME)" = "explicit-host"

result=$(resolve_ts_env_vars "$(current_def_with TS_HOSTNAME existing-host)" "$BASE_ENV_VARS" "" "" "" "" 2>/dev/null)
assert "falls back to existing app-definition value when no flag given" \
  test "$(value_for_key "$result" TS_HOSTNAME)" = "existing-host"

result=$(resolve_ts_env_vars "$EMPTY_DEF" "$BASE_ENV_VARS" "" "" "" "" 2>/dev/null)
assert "omitted entirely when neither flag nor existing value is present" \
  lacks_key "$result" TS_HOSTNAME

echo "== TS_TAGS =="
result=$(resolve_ts_env_vars "$(current_def_with TS_TAGS existing-tags)" "$BASE_ENV_VARS" "" "" "explicit-tags" "" 2>/dev/null)
assert "explicit flag wins over existing" \
  test "$(value_for_key "$result" TS_TAGS)" = "explicit-tags"

result=$(resolve_ts_env_vars "$(current_def_with TS_TAGS existing-tags)" "$BASE_ENV_VARS" "" "" "" "" 2>/dev/null)
assert "falls back to existing app-definition value when no flag given" \
  test "$(value_for_key "$result" TS_TAGS)" = "existing-tags"

result=$(resolve_ts_env_vars "$EMPTY_DEF" "$BASE_ENV_VARS" "" "" "" "" 2>/dev/null)
assert "omitted entirely when neither flag nor existing value is present" \
  lacks_key "$result" TS_TAGS

echo "== TS_API_KEY (ci-workflows#131/#132) =="
result=$(resolve_ts_env_vars "$(current_def_with TS_API_KEY existing-key)" "$BASE_ENV_VARS" "" "" "" "explicit-key" 2>/dev/null)
assert "explicit flag wins over existing" \
  test "$(value_for_key "$result" TS_API_KEY)" = "explicit-key"

result=$(resolve_ts_env_vars "$(current_def_with TS_API_KEY existing-key)" "$BASE_ENV_VARS" "" "" "" "" 2>/dev/null)
assert "falls back to existing app-definition value when no flag given" \
  test "$(value_for_key "$result" TS_API_KEY)" = "existing-key"

result=$(resolve_ts_env_vars "$EMPTY_DEF" "$BASE_ENV_VARS" "" "" "" "" 2>/dev/null)
assert "omitted entirely when neither flag nor existing value is present" \
  lacks_key "$result" TS_API_KEY

echo "== Cross-cutting =="
FULL_DEF=$(jq -n '{envVars: [
  {key: "TS_AUTHKEY", value: "e-authkey"},
  {key: "TS_EPHEMERAL_AUTHKEY", value: "e-eph"},
  {key: "TS_HOSTNAME", value: "e-host"},
  {key: "TS_TAGS", value: "e-tags"},
  {key: "TS_API_KEY", value: "e-key"}
]}')
result=$(resolve_ts_env_vars "$FULL_DEF" "$BASE_ENV_VARS" "" "" "" "" 2>/dev/null)
assert "all five vars preserved together when no flags are passed" \
  test "$(echo "$result" | jq 'length')" -eq 5

result=$(resolve_ts_env_vars "$FULL_DEF" "$BASE_ENV_VARS" "override-authkey" "" "" "override-key" 2>/dev/null)
assert "mixed: overridden vars use the flag, untouched vars still preserve existing" \
  test "$(value_for_key "$result" TS_AUTHKEY)" = "override-authkey" \
  -a "$(value_for_key "$result" TS_HOSTNAME)" = "e-host" \
  -a "$(value_for_key "$result" TS_API_KEY)" = "override-key" \
  -a "$(value_for_key "$result" TS_EPHEMERAL_AUTHKEY)" = "e-eph"

result=$(resolve_ts_env_vars "$FULL_DEF" "$BASE_ENV_VARS" "override-authkey" "" "" "override-key" "override-eph" 2>/dev/null)
assert "mixed: TS_EPHEMERAL_AUTHKEY's own override also wins alongside the others" \
  test "$(value_for_key "$result" TS_EPHEMERAL_AUTHKEY)" = "override-eph" \
  -a "$(value_for_key "$result" TS_AUTHKEY)" = "override-authkey" \
  -a "$(value_for_key "$result" TS_HOSTNAME)" = "e-host"

result=$(resolve_ts_env_vars "$EMPTY_DEF" '[{"key":"TARGET_APP","value":"https://example.com"}]' "flag" "" "" "" 2>/dev/null)
assert "does not mutate an unrelated pre-existing env_vars entry" \
  test "$(value_for_key "$result" TARGET_APP)" = "https://example.com"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
