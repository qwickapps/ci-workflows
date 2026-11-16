#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/configure-caprover-app.sh"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
MOCK_BIN="$TMPDIR_TEST/bin"
CALLS="$TMPDIR_TEST/curl-calls"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_CALLS"
case "$*" in
  *"https://target.test/api/v2/login"*|*"https://gateway.test/api/v2/login"*)
    printf '%s\n' '{"status":100,"data":{"token":"test-token"}}'
    ;;
  *"https://gateway.test/api/v2/user/apps/appDefinitions"*)
    printf '%s\n' '{"status":100,"data":{"appDefinitions":[{"appName":"public-orders","instanceCount":1,"customDomain":["orders.example.test"],"envVars":[{"key":"TARGET_APP","value":"https://orders-live.app.qwickforge.com"}]}]}}'
    ;;
  *)
    echo "unexpected curl invocation: $*" >&2
    exit 99
    ;;
esac
MOCK
chmod +x "$MOCK_BIN/curl"

set +e
output="$(PATH="$MOCK_BIN:$PATH" MOCK_CALLS="$CALLS" bash "$SCRIPT" \
  --app-name orders-live \
  --caprover-url https://target.test \
  --caprover-password test-password \
  --gateway-caprover-url https://gateway.test \
  --gateway-caprover-password test-password \
  --instance-count 0 2>&1)"
rc=$?
set -e
printf '%s\n' "$output"

[[ $rc -ne 0 ]] || { echo "expected active gateway refusal" >&2; exit 1; }
[[ "$output" == *"public-orders"* ]] || { echo "refusal omitted gateway name" >&2; exit 1; }
[[ "$output" == *"orders.example.test"* ]] || { echo "refusal omitted domain" >&2; exit 1; }
[[ "$output" == *"Move traffic off this app first"* ]] || { echo "refusal omitted remedy" >&2; exit 1; }
! grep -q '/appDefinitions/update' "$CALLS" || { echo "wrapper reached appDefinitions/update after refusal" >&2; exit 1; }
! grep -q '/appDefinitions/register' "$CALLS" || { echo "wrapper reached app registration after refusal" >&2; exit 1; }
printf 'ok - configure wrapper refuses active scale-to-zero before mutation\n'
