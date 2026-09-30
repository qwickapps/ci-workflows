#!/usr/bin/env bash
#
# Behavioral regression test for setup-qwickway-route.sh's GHCR
# registry-refresh fail-safety (ci-workflows, fm run 36567567640 / job
# 109403847162 post-mortem).
#
# Root cause (verified live by prime, 2026-09-29): CapRover's
# DockerRegistryHelper reports a transient `docker daemon -> ghcr.io`
# network timeout under the SAME status code (1112, "authentication
# failed") as a genuine bad credential. The pre-fix script (a) never
# retried 1112 at all, and (b) wrote the gateway's TARGET_APP env var
# (flipping the live route) BEFORE refreshing the registry credentials --
# so a transient registry timeout still mutated production and then
# reported red.
#
# This test runs the REAL script end-to-end (not an extracted snippet) as
# a subprocess, with a fake `curl` executable on PATH that emulates the
# route CapRover instance and ghcr.io. Each case is proven to FAIL on
# unpatched main (see the PR description for the recorded run).
#
# Cases (ci-workflows regression requirements):
#   a. A 1112 on the first registry update followed by 100 on retry leads
#      to overall success.
#   b. A persistent 1112 exits non-zero, AND the stubbed
#      appDefinitions/update endpoint (the one that writes TARGET_APP) is
#      NEVER called -- the route is not flipped.
#   c. The registryUser in both the update and insert payloads equals the
#      username passed via --registry-user.

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

# ── Fake curl: emulates the route CapRover instance + ghcr.io token endpoint ──
#
# Routed entirely by URL (the only positional http(s):// argument). State
# (attempt counters, captured payloads, "was this endpoint ever called")
# lives in $FAKE_CURL_STATE_DIR so each test case gets a clean slate.
cat > "$FAKE_BIN/curl" <<'CURL_STUB'
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="${FAKE_CURL_STATE_DIR:?FAKE_CURL_STATE_DIR must be set}"

args=("$@")
url=""
payload=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    http://*|https://*) url="${args[$i]}" ;;
  esac
  if [ "${args[$i]}" = "-d" ]; then
    payload="${args[$((i + 1))]}"
  fi
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
    # This is the TARGET_APP-writing call. Record that it happened so test
    # (b) can prove it was never reached when the registry refresh fails.
    echo "called" >> "$STATE_DIR/appdef_update_calls"
    printf '{"status":100}'
    ;;
  */api/v2/user/apps/appDefinitions)
    cat "$STATE_DIR/appdef.json"
    ;;
  */api/v2/user/system/enablessl)
    printf '{"status":100}'
    ;;
  */api/v2/user/registries/update)
    n=0
    [ -f "$STATE_DIR/registry_update_attempts" ] && n="$(cat "$STATE_DIR/registry_update_attempts")"
    n=$((n + 1))
    echo "$n" > "$STATE_DIR/registry_update_attempts"
    printf '%s' "$payload" > "$STATE_DIR/last_update_payload.json"
    mode="always_1112"
    [ -f "$STATE_DIR/registry_update_mode" ] && mode="$(cat "$STATE_DIR/registry_update_mode")"
    case "$mode" in
      fail_then_succeed)
        if [ "$n" -lt 2 ]; then
          printf '{"status":1112,"description":"authentication failed"}'
        else
          printf '{"status":100}'
        fi
        ;;
      always_1112)
        printf '{"status":1112,"description":"authentication failed"}'
        ;;
      succeed)
        printf '{"status":100}'
        ;;
    esac
    ;;
  */api/v2/user/registries/insert)
    printf '%s' "$payload" > "$STATE_DIR/last_insert_payload.json"
    printf '{"status":100}'
    ;;
  */api/v2/user/registries)
    cat "$STATE_DIR/registries.json"
    ;;
  */api/v2/user/apps/appData/*)
    printf '{"status":100}'
    ;;
  https://ghcr.io/token\?*)
    # ghcr_probe_auth_only's probe. Always "authenticates" here -- these
    # tests are about the CapRover-side retry/ordering/username behavior,
    # not the probe's own pass/fail branch (covered by
    # scripts/tests/ghcr-token-select.test.sh).
    printf '{"token":"bearer-fake"}'
    ;;
  */gateway/health)
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

# TARGET_APP here is deliberately the PREVIOUS slot's URL, not the one this
# run passes via --target-app-url below -- the app-definition update this
# fixture drives is a real state change (an actual blue/green promotion),
# not a skipped no-op. This is what makes test (b) meaningful: on the
# pre-fix script (TARGET_APP write BEFORE the registry refresh), this
# exact fixture WOULD flip TARGET_APP to the new slot even though the
# registry refresh fails right after.
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

REGISTRIES_JSON_DEFAULT_PUSH='{
  "status": 100,
  "data": {
    "defaultPushRegistryId": 42,
    "registries": [
      {"id": 42, "registryDomain": "ghcr.io"}
    ]
  }
}'

REGISTRIES_JSON_NO_GHCR='{
  "status": 100,
  "data": {
    "defaultPushRegistryId": "",
    "registries": []
  }
}'

# run_script REGISTRIES_JSON [REGISTRY_USER]
# Runs the real script as a subprocess with the fake curl on PATH. Prints
# combined stdout+stderr to $CASE_OUT and returns the script's exit code
# (never triggers set -e in the caller -- caller must capture $?).
#
# REGISTRY_USER is OPTIONAL and only passed as --registry-user when given
# non-empty: cases (a) and (b) deliberately omit it (they test retry/
# ordering behavior that has nothing to do with the username, and main
# doesn't understand --registry-user at all -- passing it unconditionally
# would make those two cases fail on main for the wrong reason, an
# unrecognized-flag error, instead of demonstrating the actual regressions).
# Only case (c) passes a custom user, to test --registry-user itself.
run_script() {
  local registries_json="$1" registry_user="${2:-}"
  echo "$registries_json" > "$STATE_DIR/registries.json"
  echo "$APPDEF_JSON" > "$STATE_DIR/appdef.json"

  local extra_args=()
  if [ -n "$registry_user" ]; then
    extra_args=(--registry-user "$registry_user")
  fi

  PATH="$FAKE_BIN:$PATH" FAKE_CURL_STATE_DIR="$STATE_DIR" \
    bash "$SCRIPT" \
    --gateway-app-name test-gateway \
    --target-app-url http://target.example.com \
    --route-caprover-url https://captain.faketest.example.com \
    --route-caprover-password fakepass \
    --github-token faketoken123 \
    "${extra_args[@]}" \
    > "$CASE_OUT" 2>&1
}

# ── (a) 1112 then 100 on retry leads to overall success ─────────────────
echo "== (a) registry update: 1112 then 100 on retry succeeds =="

STATE_DIR="$WORKDIR/case-a"
mkdir -p "$STATE_DIR"
echo "fail_then_succeed" > "$STATE_DIR/registry_update_mode"
CASE_OUT="$WORKDIR/case-a.out"

set +e
CAPROVER_API_MAX_RETRIES=3 CAPROVER_API_INITIAL_RETRY_DELAY=1 \
  run_script "$REGISTRIES_JSON_DEFAULT_PUSH"
RC_A=$?
set -e

assert "(a) script exits 0 after a 1112-then-100 registry update" \
  test "$RC_A" -eq 0

assert "(a) registries/update was actually retried (2 attempts recorded)" \
  bash -c "test \"\$(cat '$STATE_DIR/registry_update_attempts')\" = 2"

assert "(a) script reports the registry credentials as updated" \
  grep -q "Registry credentials updated" "$CASE_OUT"

assert "(a) script completes the full route setup" \
  grep -q "QwickWay route setup complete" "$CASE_OUT"

# ── (b) persistent 1112 exits non-zero and never flips the route ────────
echo ""
echo "== (b) persistent registry 1112: fails without ever calling appDefinitions/update =="

STATE_DIR="$WORKDIR/case-b"
mkdir -p "$STATE_DIR"
echo "always_1112" > "$STATE_DIR/registry_update_mode"
CASE_OUT="$WORKDIR/case-b.out"

set +e
CAPROVER_API_MAX_RETRIES=2 CAPROVER_API_INITIAL_RETRY_DELAY=1 \
  run_script "$REGISTRIES_JSON_DEFAULT_PUSH"
RC_B=$?
set -e

assert "(b) script exits non-zero when the registry refresh never recovers" \
  test "$RC_B" -ne 0

assert "(b) the TARGET_APP-writing appDefinitions/update endpoint was NEVER called" \
  bash -c "[ ! -f '$STATE_DIR/appdef_update_calls' ]"

assert "(b) failure is reported as registry reachability, not blindly as bad credentials" \
  grep -qi "registry reachability" "$CASE_OUT"

# ── (c) registryUser hygiene: update AND insert both use the passed username ──
echo ""
echo "== (c) --registry-user is used consistently in both update and insert payloads =="

CUSTOM_USER="custom-registry-actor"

# (c1) update path: an existing default-push ghcr.io entry.
STATE_DIR="$WORKDIR/case-c-update"
mkdir -p "$STATE_DIR"
echo "succeed" > "$STATE_DIR/registry_update_mode"
CASE_OUT="$WORKDIR/case-c-update.out"

set +e
run_script "$REGISTRIES_JSON_DEFAULT_PUSH" "$CUSTOM_USER"
RC_C1=$?
set -e

assert "(c1) script succeeds against the update path" \
  test "$RC_C1" -eq 0
assert "(c1) the update payload's registryUser matches --registry-user" \
  bash -c "jq -e --arg u '$CUSTOM_USER' '.registryUser == \$u' '$STATE_DIR/last_update_payload.json' >/dev/null"

# (c2) insert path: no existing ghcr.io entry at all.
STATE_DIR="$WORKDIR/case-c-insert"
mkdir -p "$STATE_DIR"
CASE_OUT="$WORKDIR/case-c-insert.out"

set +e
run_script "$REGISTRIES_JSON_NO_GHCR" "$CUSTOM_USER"
RC_C2=$?
set -e

assert "(c2) script succeeds against the insert path" \
  test "$RC_C2" -eq 0
assert "(c2) the insert payload's registryUser matches --registry-user" \
  bash -c "jq -e --arg u '$CUSTOM_USER' '.registryUser == \$u' '$STATE_DIR/last_insert_payload.json' >/dev/null"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
