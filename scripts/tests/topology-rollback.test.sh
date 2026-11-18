#!/usr/bin/env bash
# Tests for scripts/topology-rollback.py using a fake `ssh` binary that
# records every docker command it was asked to run, so assertions can check
# exactly what was scaled/restored.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/ssh-calls.log"

pass=0; fail=0
expect_pass() { local label="$1"; shift; if "$@" >"$TMP/out.$label.log" 2>&1; then echo "PASS $label"; pass=$((pass+1)); else echo "FAIL expected pass: $label"; cat "$TMP/out.$label.log" >&2; fail=$((fail+1)); fi; }
expect_fail() { local label="$1"; shift; if "$@" >"$TMP/out.$label.log" 2>&1; then echo "FAIL expected fail: $label"; cat "$TMP/out.$label.log" >&2; fail=$((fail+1)); else echo "PASS failed-as-expected $label"; pass=$((pass+1)); fi; }

cat > "$TMP/ssh" <<FAKESSH
#!/usr/bin/env bash
echo "\$*" >> "$LOG"
exit 0
FAKESSH
chmod +x "$TMP/ssh"

ROLLBACK=(python3 "$ROOT/scripts/topology-rollback.py")

echo "== conflict with a recorded previous owner: scale new claimant to 0, restore owner =="
: > "$LOG"
STATE="$TMP/pre-state.json"
cat > "$STATE" <<'JSON'
{
  "host": "oci-gateway",
  "app": "srv-captain--qwickapps-mcp",
  "previous_owner": {"host": "oci-gateway", "name": "srv-captain--qwickapps-mcp", "replicas": 1, "image": "ghcr.io/qwickapps/qwickway:latest", "ts_hostname": "qwickapps-mcp"}
}
JSON
PATH="$TMP:$PATH" expect_pass "rollback with previous owner" "${ROLLBACK[@]}" \
  --pre-mutation-state "$STATE" --new-claimant-host oci-gateway --new-claimant-app qwickapps-mcp-gateway-canary-20261003

grep -q "service scale qwickapps-mcp-gateway-canary-20261003=0" "$LOG" \
  && { echo "PASS new claimant scaled to 0"; pass=$((pass+1)); } \
  || { echo "FAIL expected pass: new claimant scaled to 0"; fail=$((fail+1)); }
grep -q "service scale srv-captain--qwickapps-mcp=1" "$LOG" \
  && { echo "PASS previous owner replicas restored"; pass=$((pass+1)); } \
  || { echo "FAIL expected pass: previous owner replicas restored"; fail=$((fail+1)); }
grep -q "service update --image ghcr.io/qwickapps/qwickway:latest srv-captain--qwickapps-mcp" "$LOG" \
  && { echo "PASS previous owner image restored"; pass=$((pass+1)); } \
  || { echo "FAIL expected pass: previous owner image restored"; fail=$((fail+1)); }
grep -q "qwickapps-mcp-gateway-canary-20261003" "$LOG" || true

echo "== never renames/edits the registered canonical app name itself =="
grep -q "service update.*--name" "$LOG" \
  && { echo "FAIL expected fail: no rename command issued"; fail=$((fail+1)); } \
  || { echo "PASS no rename/edit command issued against canonical owner"; pass=$((pass+1)); }

echo "== no previous owner recorded (first-ever claimant of this hostname): only neutralize, no restore =="
: > "$LOG"
STATE2="$TMP/pre-state-none.json"
cat > "$STATE2" <<'JSON'
{"host": "oci-gateway", "app": "srv-captain--qwickapps-mcp", "previous_owner": null}
JSON
PATH="$TMP:$PATH" expect_pass "rollback with no previous owner" "${ROLLBACK[@]}" \
  --pre-mutation-state "$STATE2" --new-claimant-host oci-gateway --new-claimant-app srv-captain--qwickapps-mcp
LINES="$(wc -l < "$LOG" | tr -d ' ')"
test "$LINES" -eq 1 \
  && { echo "PASS only the neutralize action ran"; pass=$((pass+1)); } \
  || { echo "FAIL expected pass: only the neutralize action ran (got $LINES ssh calls)"; fail=$((fail+1)); }

echo "== missing snapshot file: abort, never guess at a restore target =="
expect_fail "missing snapshot aborts" "${ROLLBACK[@]}" \
  --pre-mutation-state "$TMP/does-not-exist.json" --new-claimant-host oci-gateway --new-claimant-app whatever

echo "Tests: $pass passed, $fail failed"
test "$fail" -eq 0
