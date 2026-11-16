#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/caprover-api.sh
source "$SCRIPT_DIR/lib/caprover-api.sh"

failures=0
assert() {
  local label="$1"
  shift
  if "$@"; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s\n' "$label" >&2
    failures=$((failures + 1))
  fi
}

active_gateway_defs='{"status":100,"data":{"appDefinitions":[
  {"appName":"customer-api","instanceCount":1,"customDomain":["api.example.test"],"envVars":[{"key":"TARGET_APP","value":"https://orders-live.app.qwickforge.com"}]},
  {"appName":"offline-gateway","instanceCount":0,"customDomain":["offline.example.test"],"envVars":[{"key":"TARGET_APP","value":"https://orders-live.app.qwickforge.com"}]}
]}}'
no_target_defs='{"status":100,"data":{"appDefinitions":[
  {"appName":"customer-api","instanceCount":1,"customDomain":["api.example.test"],"envVars":[{"key":"TARGET_APP","value":"https://orders-stable.app.qwickforge.com"}]}
]}}'

caprover_get_app_definitions() {
  case "$1" in
    https://gateway-active.test) printf '%s\n' "$active_gateway_defs" ;;
    https://gateway-safe.test) printf '%s\n' "$no_target_defs" ;;
    *) return 1 ;;
  esac
}

assert "URL target matches only its exact app" caprover_target_matches_app "https://orders-live.app.qwickforge.com" "orders-live"
target_does_not_match_prefix() {
  ! caprover_target_matches_app "https://orders-live.app.qwickforge.com" "orders"
}
refusal_names_gateway() { [[ "$refusal" == *"customer-api"* ]]; }
refusal_names_domain() { [[ "$refusal" == *"api.example.test"* ]]; }
refusal_gives_remedy() { [[ "$refusal" == *"Move traffic off this app first"* ]]; }
assert "URL target does not match prefix app" target_does_not_match_prefix
assert "direct service target matches app" caprover_target_matches_app "srv-captain--orders-live" "orders-live"

refusal="$(caprover_assert_not_active_gateway_target https://gateway-active.test test-token orders-live 2>&1)" && refusal_rc=0 || refusal_rc=$?
printf '%s\n' "$refusal"
assert "active target is refused" test "$refusal_rc" -ne 0
assert "refusal names gateway" refusal_names_gateway
assert "refusal names domain" refusal_names_domain
assert "refusal gives traffic-move remedy" refusal_gives_remedy

safe="$(caprover_assert_not_active_gateway_target https://gateway-safe.test test-token orders-live 2>&1)" && safe_rc=0 || safe_rc=$?
printf '%s\n' "$safe"
assert "unreferenced app is allowed" test "$safe_rc" -eq 0

if (( failures > 0 )); then
  exit 1
fi
