#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
SCRIPT="$ROOT/caprover-slot-admin.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert() {
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

url=""
payload=""
method="GET"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -d) payload="$2"; shift 2 ;;
    --url) url="$2"; shift 2 ;;
    http*://*) url="$1"; shift ;;
    *) shift ;;
  esac
done

case "$url" in
  */api/v2/login)
    printf '{"status":100,"data":{"token":"fake-token"}}\n'
    ;;
  */api/v2/user/apps/appDefinitions/update)
    printf '%s' "$payload" > "$STATE_DIR/update-payload.json"
    count=0
    [[ -f "$STATE_DIR/update-count" ]] && count="$(cat "$STATE_DIR/update-count")"
    printf '%s\n' "$((count + 1))" > "$STATE_DIR/update-count"
    printf '{"status":100}\n'
    ;;
  */api/v2/user/apps/appDefinitions)
    count=0
    [[ -f "$STATE_DIR/get-count" ]] && count="$(cat "$STATE_DIR/get-count")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$STATE_DIR/get-count"
    if [[ "${MODE:-dry-run}" == "apply" && "$count" -gt 1 ]]; then
      cat "$STATE_DIR/filtered-response.json"
    elif [[ "${MODE:-dry-run}" == "mismatch" && "$count" -gt 1 ]]; then
      cat "$STATE_DIR/original-response.json"
    else
      cat "$STATE_DIR/original-response.json"
    fi
    ;;
  *)
    echo "unexpected curl URL: $url ($method)" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$TMP/bin/curl"

write_fixtures() {
  local state_dir="$1"
  mkdir -p "$state_dir"
  cat > "$state_dir/original-response.json" <<'JSON'
{"status":100,"data":{"appDefinitions":[{"appName":"demo","instanceCount":2,"containerHttpPort":3000,"forceSsl":true,"envVars":[{"key":"KEEP","value":"keep-value"},{"key":"OLD_TOKEN","value":"secret-value"},{"key":"LEGACY_URL","value":"https://old.example"}]}]}}
JSON
  cat > "$state_dir/filtered-response.json" <<'JSON'
{"status":100,"data":{"appDefinitions":[{"appName":"demo","instanceCount":2,"containerHttpPort":3000,"forceSsl":true,"envVars":[{"key":"KEEP","value":"keep-value"}]}]}}
JSON
  printf '0\n' > "$state_dir/update-count"
  printf '0\n' > "$state_dir/get-count"
}

run_remove_env() {
  local state_dir="$1"
  local mode="$2"
  shift 2
  STATE_DIR="$state_dir" MODE="$mode" PATH="$TMP/bin:$PATH" \
    CAPROVER_API_MAX_RETRIES=1 CAPROVER_API_INITIAL_RETRY_DELAY=0 \
    bash "$SCRIPT" remove-env \
      --app-name demo \
      --keys OLD_TOKEN,LEGACY_URL,MISSING \
      --caprover-url https://captain.example \
      --caprover-password fake-password \
      "$@"
}

# Dry-run is the default: report presence without sending an update.
STATE="$TMP/dry-run"
write_fixtures "$STATE"
OUT="$STATE/out"
run_remove_env "$STATE" dry-run > "$OUT" 2>&1
assert "dry-run defaults to no update" test "$(cat "$STATE/update-count")" -eq 0
assert "dry-run reports present key names" grep -q '^PRESENT: OLD_TOKEN' "$OUT"
assert "dry-run reports absent key names" grep -q '^ABSENT: MISSING' "$OUT"
assert "dry-run does not print removed secret values" bash -c "! grep -q 'secret-value\|https://old.example' '$OUT'"

# Apply mode sends one update and requires exact read-back state.
STATE="$TMP/apply"
write_fixtures "$STATE"
OUT="$STATE/out"
run_remove_env "$STATE" apply --dry-run false > "$OUT" 2>&1
assert "apply performs exactly one atomic update" test "$(cat "$STATE/update-count")" -eq 1
assert "apply preserves non-env app fields" jq -e '.instanceCount == 2 and .containerHttpPort == 3000 and .forceSsl == true' "$STATE/update-payload.json"
assert "apply preserves untouched env vars and removes only named keys" jq -e '.envVars == [{"key":"KEEP","value":"keep-value"}]' "$STATE/update-payload.json"
assert "apply confirms successful read-back verification" grep -q '^Removed and verified env keys on demo:' "$OUT"

# A mismatched read-back must fail even if CapRover accepted the update request.
STATE="$TMP/mismatch"
write_fixtures "$STATE"
OUT="$STATE/out"
if run_remove_env "$STATE" mismatch --dry-run false > "$OUT" 2>&1; then
  fail "apply fails when live envVars do not exactly match the requested result"
else
  pass "apply fails when live envVars do not exactly match the requested result"
fi
assert "mismatch still sends only one update" test "$(cat "$STATE/update-count")" -eq 1
assert "mismatch reports verification failure" grep -q 'live envVars do not exactly match' "$OUT"

# Invalid options fail before authentication or mutation.
STATE="$TMP/invalid"
write_fixtures "$STATE"
OUT="$STATE/out"
if run_remove_env "$STATE" dry-run --dry-run yes > "$OUT" 2>&1; then
  fail "invalid --dry-run value is rejected"
else
  pass "invalid --dry-run value is rejected"
fi
assert "invalid --dry-run performs no API calls" test "$(cat "$STATE/get-count")" -eq 0

printf '\nTests passed: %s\n' "$PASS"
printf 'Tests failed: %s\n' "$FAIL"
[[ "$FAIL" -eq 0 ]]
