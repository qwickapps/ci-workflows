#!/usr/bin/env bash
# caprover_api_call / caprover_ensure_app / caprover_login -- t_d093182d
# regression for the qwickapps-secrets-dev CapRover build-lock wedge
# (2026-10-01, 01:56-02:04 UTC on oci-main).
#
# Root cause: CapRover's register/login/atomic-update endpoints can hang
# for minutes when CapRover is wedged holding its single process-wide
# build lock under host resource contention (observed: a register call
# that produced zero docker-level log output for ~10 minutes while the
# host was CPU/IO-saturated by a concurrent backup pg_dump sweep). Only
# the atomic-update path had a bounded retry; register and login were
# bare curls with no --max-time and no retry, so a hang either blocked
# forever or surfaced a confusing "Invalid JSON" / non-JSON error instead
# of CapRover's own "busy, please wait" signal.
#
# This also regression-tests a bug in caprover_api_call itself: the
# retry loop never checked curl's own exit code, so a --max-time timeout
# (empty stdout, non-zero exit) fell through the busy-text grep and was
# silently treated as a successful empty response.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

# shellcheck source=scripts/lib/caprover-api.sh
source "$ROOT/lib/caprover-api.sh"

# Keep retries fast in tests.
export CAPROVER_API_MAX_RETRIES=3
export CAPROVER_API_INITIAL_RETRY_DELAY=0

# --- Test 1: caprover_api_call retries a curl that times out (non-zero
#     exit, no stdout -- what --max-time expiry looks like) and succeeds
#     once the simulated hang clears. caprover_api_call runs the mock via
#     a command-substitution subshell, so call-count state must live in a
#     file (a plain shell var would reset to 0 on every invocation). ---
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
COUNT_FILE="$TMP/call-count-1"
echo 0 > "$COUNT_FILE"
mock_curl_timeout_then_ok() {
  local n
  n=$(($(cat "$COUNT_FILE") + 1))
  echo "$n" > "$COUNT_FILE"
  if [[ $n -lt 2 ]]; then
    return 28   # curl's own exit code for CURLE_OPERATION_TIMEDOUT
  fi
  printf '{"status":100,"description":"ok"}\n'
  return 0
}
result="$(caprover_api_call "test op" mock_curl_timeout_then_ok)"
calls="$(cat "$COUNT_FILE")"
if [[ "$result" == '{"status":100,"description":"ok"}' ]] && [[ "$calls" -eq 2 ]]; then
  pass "caprover_api_call retries a timed-out (non-zero exit) curl instead of treating it as success"
else
  fail "expected a retry then a clean success, got result='$result' calls=$calls"
fi

# --- Test 2: caprover_api_call fails loudly (non-zero return) when the
#     curl keeps timing out past max_retries -- never silently "succeeds"
#     with an empty response. ---
mock_curl_always_timeout() { return 28; }
if out="$(caprover_api_call "always times out" mock_curl_always_timeout 2>&1)"; then
  fail "expected caprover_api_call to fail after exhausting retries, got success with: $out"
else
  if [[ "$out" == *"curl exit 28"* ]]; then
    pass "caprover_api_call fails with a clear 'curl exit 28' message after exhausting retries on a persistent timeout"
  else
    fail "caprover_api_call failed (correct) but without a clear exit-code message: $out"
  fi
fi

# --- Test 3: caprover_ensure_app's register call survives a transient
#     hang (simulated as a timing-out curl) via the now-shared retry
#     wrapper, instead of surfacing 'Invalid JSON from register endpoint'
#     for what was really a retryable busy/timeout condition. ---
REGISTER_COUNT_FILE="$TMP/call-count-register"
echo 0 > "$REGISTER_COUNT_FILE"
mock_curl() {
  local url=""
  for arg in "$@"; do
    case "$arg" in
      http*://*) url="$arg" ;;
    esac
  done
  if [[ "$url" == *"/appDefinitions/register"* ]]; then
    local n
    n=$(($(cat "$REGISTER_COUNT_FILE") + 1))
    echo "$n" > "$REGISTER_COUNT_FILE"
    if [[ "$n" -lt 2 ]]; then
      return 28
    fi
    printf '{"status":100,"description":"App created"}\n'
    return 0
  fi
  echo "mock_curl: unexpected call: $*" >&2
  return 1
}
curl() { mock_curl "$@"; }

result="$(caprover_ensure_app "https://example.com" "tok" "qwickapps-secrets-dev" "false" 2>/dev/null)"
register_calls="$(cat "$REGISTER_COUNT_FILE")"
if [[ "$result" == "created" ]] && [[ "$register_calls" -eq 2 ]]; then
  pass "caprover_ensure_app register retries through a simulated hang instead of failing on the first timeout"
else
  fail "expected register to retry then succeed with 'created', got result='$result' calls=$register_calls"
fi

# --- Test 4: caprover_login survives the same transient-hang shape. ---
LOGIN_COUNT_FILE="$TMP/call-count-login"
echo 0 > "$LOGIN_COUNT_FILE"
mock_curl_login() {
  local url=""
  for arg in "$@"; do
    case "$arg" in
      http*://*) url="$arg" ;;
    esac
  done
  if [[ "$url" == *"/login"* ]]; then
    local n
    n=$(($(cat "$LOGIN_COUNT_FILE") + 1))
    echo "$n" > "$LOGIN_COUNT_FILE"
    if [[ "$n" -lt 2 ]]; then
      return 28
    fi
    printf '{"status":100,"data":{"token":"tok-123"}}\n'
    return 0
  fi
  echo "mock_curl_login: unexpected call: $*" >&2
  return 1
}
curl() { mock_curl_login "$@"; }

result="$(caprover_login "https://example.com" "pw" 2>/dev/null)"
login_calls="$(cat "$LOGIN_COUNT_FILE")"
if [[ "$result" == "tok-123" ]] && [[ "$login_calls" -eq 2 ]]; then
  pass "caprover_login retries through a simulated hang instead of failing on the first timeout"
else
  fail "expected login to retry then succeed with token, got result='$result' calls=$login_calls"
fi

echo ""
echo "Tests passed: $PASS"
echo "Tests failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
