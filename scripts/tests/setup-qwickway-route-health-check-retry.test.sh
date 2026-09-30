#!/usr/bin/env bash
#
# Behavioral regression test for setup-qwickway-route.sh's gateway health
# check retry loop under a transient curl failure (ci-workflows, fm run
# 36736130865, exit code 16 / CURLE_HTTP2 -- zero retries on live prod).
#
# Root cause: the script runs under `set -euo pipefail`. The health-check
# loop assigns via command substitution:
#
#   HTTP_STATUS=$(curl ... "$GATEWAY_HEALTH_URL" 2>/dev/null)
#   CURL_EXIT=$?
#
# On unpatched main, if curl itself exits non-zero (connection reset,
# HTTP/2 framing error, TLS hiccup, etc.), `set -e` kills the script on
# that assignment line -- the `CURL_EXIT=$?` fallback that was clearly
# meant to tolerate exactly this case never runs, and the 300s/5s retry
# loop never gets a second attempt. A transient, self-healing curl blip
# is reported as a hard deploy failure.
#
# This test runs the REAL script end-to-end (not an extracted snippet) as
# a subprocess, with a fake `curl` on PATH that fails the health check
# once (nonzero exit, no stdout) and then succeeds on the next attempt.
# It is proven to FAIL on unpatched main: curl's nonzero exit on the first
# health-check attempt kills the script under `set -e` before the retry
# loop's `sleep`/second attempt ever runs.
#
# GATEWAY_HEALTH_MAX_WAIT / GATEWAY_HEALTH_WAIT_INTERVAL let this test
# drive the retry loop in ~1s instead of the production defaults
# (300s / 5s).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$SCRIPTS_DIR/setup-qwickway-route.sh"

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

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

FAKE_BIN="$WORKDIR/bin"
mkdir -p "$FAKE_BIN"

# ── Fake curl: emulates the route CapRover instance + gateway health endpoint ──
#
# Routed entirely by URL (the only positional http(s):// argument). The
# /gateway/health case counts attempts in $FAKE_CURL_STATE_DIR/health_attempts
# and, on the FIRST attempt only, exits 16 (curl's CURLE_HTTP2 code) with no
# stdout -- exactly what a mid-response HTTP/2 framing error looks like to
# the calling script. Every subsequent attempt succeeds with HTTP 200.
cat > "$FAKE_BIN/curl" <<'CURL_STUB'
#!/usr/bin/env bash
set -uo pipefail
STATE_DIR="${FAKE_CURL_STATE_DIR:?FAKE_CURL_STATE_DIR must be set}"

args=("$@")
url=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    http://*|https://*) url="${args[$i]}" ;;
  esac
done

case "$url" in
  */api/v2/login)
    printf '{"status":100,"data":{"token":"faketoken"}}'
    ;;
  */api/v2/user/apps/appDefinitions/register)
    printf '{"status":1901,"description":"already exists"}'
    ;;
  */api/v2/user/apps/appDefinitions/enablebasedomainssl)
    printf '{"status":100}'
    ;;
  */api/v2/user/apps/appDefinitions/update)
    printf '{"status":100}'
    ;;
  */api/v2/user/apps/appDefinitions)
    cat "$STATE_DIR/appdef.json"
    ;;
  */api/v2/user/system/enablessl)
    printf '{"status":100}'
    ;;
  */api/v2/user/registries/update)
    printf '{"status":100}'
    ;;
  */api/v2/user/registries/insert)
    printf '{"status":100}'
    ;;
  */api/v2/user/registries)
    printf '{"status":100,"data":{"defaultPushRegistryId":42,"registries":[{"id":42,"registryDomain":"ghcr.io"}]}}'
    ;;
  */api/v2/user/apps/appData/*)
    printf '{"status":100}'
    ;;
  https://ghcr.io/token\?*)
    printf '{"token":"bearer-fake"}'
    ;;
  */gateway/health)
    n=0
    [ -f "$STATE_DIR/health_attempts" ] && n="$(cat "$STATE_DIR/health_attempts")"
    n=$((n + 1))
    echo "$n" > "$STATE_DIR/health_attempts"
    if [ "$n" -eq 1 ]; then
      # Simulate a transient curl-level failure (e.g. CURLE_HTTP2): no
      # stdout at all, nonzero exit -- NOT an HTTP error status.
      exit 16
    fi
    printf '200'
    ;;
  "")
    echo "fake curl: no URL found in args: ${args[*]}" >&2
    exit 1
    ;;
  *)
    echo "fake curl: unexpected URL: $url (args: ${args[*]})" >&2
    exit 1
    ;;
esac
CURL_STUB
chmod +x "$FAKE_BIN/curl"

APPDEF_JSON='{
  "status": 100,
  "data": {
    "appDefinitions": [
      {
        "appName": "test-gateway",
        "deployedVersion": 1,
        "instanceCount": 1,
        "envVars": [
          {"key": "TARGET_APP", "value": "http://previous-slot.example.com"},
          {"key": "HEALTH_CHECK_PATH", "value": "/health"}
        ],
        "containerHttpPort": 80,
        "forceSsl": true,
        "websocketSupport": true
      }
    ]
  }
}'

STATE_DIR="$WORKDIR/state"
mkdir -p "$STATE_DIR"
echo "$APPDEF_JSON" > "$STATE_DIR/appdef.json"
CASE_OUT="$WORKDIR/case.out"

set +e
GATEWAY_HEALTH_MAX_WAIT=10 GATEWAY_HEALTH_WAIT_INTERVAL=1 \
  CAPROVER_API_MAX_RETRIES=3 CAPROVER_API_INITIAL_RETRY_DELAY=1 \
  PATH="$FAKE_BIN:$PATH" FAKE_CURL_STATE_DIR="$STATE_DIR" \
  bash "$SCRIPT" \
  --gateway-app-name test-gateway \
  --target-app-url http://target.example.com \
  --route-caprover-url https://captain.faketest.example.com \
  --route-caprover-password fakepass \
  --github-token faketoken123 \
  > "$CASE_OUT" 2>&1
RC=$?
set -e

echo "== gateway health check: transient curl failure (exit 16, no stdout) then success =="

assert "script exits 0 (does not crash on the transient curl failure)" \
  test "$RC" -eq 0

assert "the health endpoint was actually retried (2+ attempts recorded)" \
  bash -c "[ -f '$STATE_DIR/health_attempts' ] && [ \"\$(cat '$STATE_DIR/health_attempts')\" -ge 2 ]"

assert "script reports the gateway health check as passed" \
  grep -q "Gateway health check passed" "$CASE_OUT"

assert "script completes the full route setup" \
  grep -q "QwickWay route setup complete" "$CASE_OUT"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
