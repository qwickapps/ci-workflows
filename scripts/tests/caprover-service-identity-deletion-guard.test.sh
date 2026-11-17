#!/usr/bin/env bash
# Regression: a persistent-app cutover must update service-identities.json
# before it removes the legacy CapRover app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

# shellcheck source=scripts/lib/caprover-api.sh
source "$ROOT/scripts/lib/caprover-api.sh"

registry="$TMP/service-identities.json"
cat > "$registry" <<'JSON'
{"services":[{"canonical_hostname":"qwickapps-llm","app":"srv-captain--qwickapps-llm"}]}
JSON
export CAPROVER_SERVICE_IDENTITIES_FILE="$registry"

if blocked="$(caprover_remove_app "https://example.invalid" "token" "srv-captain--qwickapps-llm" 2>&1)"; then
  fail "refuses deleting an app still named by service identities"
elif [[ "$blocked" == *"refusing to delete"* && "$blocked" == *"qwickapps-llm"* ]]; then
  pass "refuses deleting an app still named by service identities"
else
  fail "blocked deletion identifies the registry owner"
fi

calls="$TMP/calls"
mock_curl() {
  local method="GET" url=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -X) method="$2"; shift 2 ;;
      -H|-d) shift 2 ;;
      -s|-k) shift ;;
      *) url="$1"; shift ;;
    esac
  done
  printf '%s %s\n' "$method" "$url" >> "$calls"
  if [[ "$method" == "GET" ]]; then
    printf '%s\n' '{"status":100,"data":{"appDefinitions":[{"appName":"retired-app"}]}}'
  else
    printf '%s\n' '{"status":100}'
  fi
}
curl() { mock_curl "$@"; }

if caprover_remove_app "https://example.invalid" "token" "retired-app" >/dev/null 2>&1 && grep -q '^POST ' "$calls"; then
  pass "allows deletion after the registry no longer names the app"
else
  fail "allows deletion after the registry no longer names the app"
fi

echo ""
echo "Tests passed: $PASS"
echo "Tests failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
