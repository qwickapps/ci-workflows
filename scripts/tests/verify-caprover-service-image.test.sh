#!/usr/bin/env bash
# Execution tests for verify-caprover-service-image.sh. The real SSH command
# is mocked so matching, mismatching, and absent/new-task cases exercise the
# production parser and bounded retry contract.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/../verify-caprover-service-image.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
MOCK_BIN="$TMPDIR/bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MOCK_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
case "${MOCK_TASK_SET:?}" in
  matching)
    printf '%s\n' 'Running 10 seconds ago|Running|ghcr.io/qwickapps/img-memories@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    ;;
  mismatching)
    printf '%s\n' 'Running 2 minutes ago|Running|ghcr.io/qwickapps/img-memories@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    ;;
  mixed)
    printf '%s\n' 'Running 10 seconds ago|Running|ghcr.io/qwickapps/img-memories@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    printf '%s\n' 'Running 2 minutes ago|Running|ghcr.io/qwickapps/img-memories@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    ;;
  none)
    printf '%s\n' 'Shutdown 1 minute ago|Shutdown|ghcr.io/qwickapps/img-memories@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    ;;
  *) echo "unknown MOCK_TASK_SET: $MOCK_TASK_SET" >&2; exit 2 ;;
esac
EOF
chmod +x "$MOCK_BIN/sleep" "$MOCK_BIN/ssh"

run_case() {
  local task_set="$1"
  local log="$TMPDIR/$task_set.log"
  PATH="$MOCK_BIN:$PATH" MOCK_TASK_SET="$task_set" "$TARGET" \
    --ssh-host oci-main \
    --service srv-captain--qwickapps-memories-dev \
    --image-ref ghcr.io/qwickapps/img-memories@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --max-attempts 2 \
    --sleep 0 \
    >"$log" 2>&1
  LAST_RC=$?
  LAST_LOG="$log"
}

pass=0
fail=0

run_case matching
if [[ "$LAST_RC" -eq 0 ]] && grep -q 'Verified 1 running task' "$LAST_LOG"; then
  echo 'PASS: matching running task image passes'
  pass=$((pass + 1))
else
  echo "FAIL: matching running task image should pass (exit $LAST_RC)"
  cat "$LAST_LOG"
  fail=$((fail + 1))
fi

for scenario in mismatching mixed none; do
  run_case "$scenario"
  if [[ "$LAST_RC" -ne 0 ]] && grep -q 'never reached an all-running task set' "$LAST_LOG"; then
    echo "PASS: $scenario task set fails closed"
    pass=$((pass + 1))
  else
    echo "FAIL: $scenario task set should fail closed (exit $LAST_RC)"
    cat "$LAST_LOG"
    fail=$((fail + 1))
  fi
done

echo "Tests: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
