#!/usr/bin/env bash
# caprover_ensure_app (scripts/lib/caprover-api.sh) — brain#30 regression.
#
# CapRover fixes hasPersistentData at app-registration time and rejects any
# later attempt to attach volumes to an app registered non-persistent
# ("Cannot set volumes for a non-persistent container"). configure-caprover-app.sh
# used to hardcode hasPersistentData:false on every register call regardless
# of what the caller asked for, only applying the requested value in a later
# update -- too late for CapRover to accept it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

# shellcheck source=scripts/lib/caprover-api.sh
source "$ROOT/lib/caprover-api.sh"

# Mock curl: records the request body of every register call, and answers
# GET appDefinitions with a scripted app list controlled by env vars.
mock_curl() {
  local method="" url="" body=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -d) body="$2"; shift 2 ;;
      -s|-k) shift ;;
      -H) shift 2 ;;
      *) url="$1"; shift ;;
    esac
  done

  if [[ "$url" == *"/appDefinitions/register" ]]; then
    printf '%s\n' "$body" >> "$TMP/register-calls.log"
    if [[ "${MOCK_ALREADY_EXISTS:-0}" == "1" ]]; then
      printf '{"status":1901,"description":"App already exists"}\n'
    else
      printf '{"status":100,"description":"App created"}\n'
    fi
    return 0
  fi

  if [[ "$url" == *"/appDefinitions" && "$method" == "GET" ]]; then
    printf '{"data":{"appDefinitions":[{"appName":"%s","hasPersistentData":%s}]}}\n' \
      "${MOCK_APP_NAME:-testapp}" "${MOCK_EXISTING_PERSISTENT:-false}"
    return 0
  fi

  echo "mock_curl: unexpected call: $method $url" >&2
  return 1
}
curl() { mock_curl "$@"; }

# --- Test 1: fresh app, has_persistent_data=true is sent at register time ---
rm -f "$TMP/register-calls.log"
result="$(caprover_ensure_app "https://example.com" "tok" "testapp" "true" 2>/dev/null)"
if [[ "$result" == "created" ]]; then
  pass "fresh app register returns 'created'"
else
  fail "expected 'created', got: $result"
fi

if grep -q '"hasPersistentData":true' "$TMP/register-calls.log"; then
  pass "register call sends hasPersistentData:true (the actual brain#30 bug: this used to always send false)"
else
  fail "register call did not send hasPersistentData:true — got: $(cat "$TMP/register-calls.log")"
fi

# --- Test 2: default (no 4th arg) still registers non-persistent, preserving prior behavior ---
rm -f "$TMP/register-calls.log"
caprover_ensure_app "https://example.com" "tok" "testapp" >/dev/null 2>&1
if grep -q '"hasPersistentData":false' "$TMP/register-calls.log"; then
  pass "omitting the persistence arg still defaults to false (backward compatible)"
else
  fail "default register call did not send hasPersistentData:false — got: $(cat "$TMP/register-calls.log")"
fi

# --- Test 3: already-exists, requested persistence matches actual -> ok, no error ---
MOCK_ALREADY_EXISTS=1 MOCK_APP_NAME=testapp MOCK_EXISTING_PERSISTENT=true \
  result="$(MOCK_ALREADY_EXISTS=1 MOCK_APP_NAME=testapp MOCK_EXISTING_PERSISTENT=true \
    caprover_ensure_app "https://example.com" "tok" "testapp" "true" 2>/dev/null)"
if [[ "$result" == "existing" ]]; then
  pass "existing app with matching persistence returns 'existing'"
else
  fail "expected 'existing', got: $result"
fi

# --- Test 4: already-exists, requested true but actual is false -> loud, blocking error ---
err=""
if err="$(MOCK_ALREADY_EXISTS=1 MOCK_APP_NAME=testapp MOCK_EXISTING_PERSISTENT=false \
    caprover_ensure_app "https://example.com" "tok" "testapp" "true" 2>&1 >/dev/null)"; then
  fail "expected non-zero exit for hasPersistentData mismatch, got success"
else
  if [[ "$err" == *"already exists with hasPersistentData=false"* && "$err" == *"must be deleted"* ]]; then
    pass "hasPersistentData mismatch on an existing app fails loudly with a clear, actionable error"
  else
    fail "mismatch error message unclear or missing: $err"
  fi
fi

echo ""
echo "Tests passed: $PASS"
echo "Tests failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
