#!/usr/bin/env bash
#
# Unit tests for scripts/validate-env-values.sh (qwickapps/ci-workflows#36).
#
# Covers the loophole that crash-looped the MCP server: a placeholder value
# (`-`) passing a naive non-empty check. Asserts the validator accepts a
# fully-valid env file and rejects empty, placeholder, and format-invalid
# values (auth keys, URLs, short service keys).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATOR="$SCRIPTS_DIR/validate-env-values.sh"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass=0
fail=0

# assert_pass <desc> <env-file-contents>
assert_pass() {
  local desc="$1"
  local body="$2"
  local f="$TMPDIR_TEST/env"
  printf '%s\n' "$body" > "$f"
  if bash "$VALIDATOR" "$f" >/dev/null 2>&1; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc (validator rejected a file it should have accepted)"
    bash "$VALIDATOR" "$f" || true
    fail=$((fail + 1))
  fi
}

# assert_fail <desc> <env-file-contents>
assert_fail() {
  local desc="$1"
  local body="$2"
  local f="$TMPDIR_TEST/env"
  printf '%s\n' "$body" > "$f"
  if bash "$VALIDATOR" "$f" >/dev/null 2>&1; then
    echo "  FAIL: $desc (validator accepted a file it should have rejected)"
    fail=$((fail + 1))
  else
    echo "  PASS: $desc"
    pass=$((pass + 1))
  fi
}

# A fully-valid env file used as the golden baseline. Each typed key is
# well-formed: auth keys carry the tskey- prefix, the API key carries
# tskey-api-, URLs are http(s), and the service/api keys are >= 16 chars.
VALID_ENV="$(cat <<'EOF'
# qwickapps deploy env (golden)
NODE_ENV=production
TS_EPHEMERAL_AUTHKEY=tskey-auth-abc123def456ghi789
TS_API_KEY=tskey-api-xyz987uvw654rst321
SECRETS_SERVICE_URL=https://secrets.qwickforge.com
SECRETS_SERVICE_KEY=super-long-secret-key-1234567890
DATABASE_CONNECTION=postgres://user:pass@host:5432/db?sslmode=require
SOME_API_KEY=0123456789abcdef0123
# trailing comment and blank line below

GREETING=hello=world
EOF
)"

echo "== validate-env-values: golden path =="
assert_pass "fully-valid env file passes" "$VALID_ENV"

echo "== validate-env-values: empty / placeholder rejection =="
assert_fail "literal dash placeholder rejected" \
  "TS_EPHEMERAL_AUTHKEY=-"
assert_fail "empty value rejected" \
  "FOO="
assert_fail "whitespace-only value rejected" \
  "FOO=   "
assert_fail "'changeme' placeholder rejected" \
  "ADMIN_PASSWORD=changeme"
assert_fail "case-insensitive placeholder rejected" \
  "ADMIN_PASSWORD=ChangeMe"
assert_fail "placeholder regex (replace...) rejected" \
  "API_TOKEN=replace-with-real-token"
assert_fail "placeholder regex (...-here) rejected" \
  "API_TOKEN=put-the-token-here"

echo "== validate-env-values: typed-key format rejection =="
assert_fail "TS authkey not starting tskey- rejected" \
  "TS_EPHEMERAL_AUTHKEY=not-a-tailscale-key-value"
assert_fail "TS_API_KEY not starting tskey-api- rejected" \
  "TS_API_KEY=tskey-auth-wrong-prefix-1234567890"
assert_fail "_URL with no scheme rejected" \
  "SECRETS_SERVICE_URL=secrets.qwickforge.com"
assert_fail "short _SERVICE_KEY rejected" \
  "SECRETS_SERVICE_KEY=short"
assert_fail "short _API_KEY rejected" \
  "SOME_API_KEY=tooshort"

echo "== validate-env-values: well-formed typed keys pass =="
assert_pass "TS_API_KEY with tskey-api- prefix passes" \
  "TS_API_KEY=tskey-api-1234567890abcdef"
assert_pass "DATABASE_URL with postgres:// scheme passes" \
  "DATABASE_URL=postgres://user:pass@host:5432/db?sslmode=require"
assert_pass "_URL with redis:// scheme passes" \
  "REDIS_URL=redis://localhost:6379"
assert_pass "comment + blank lines only passes (no values)" \
  "# only a comment"
assert_pass "value containing = passes" \
  "GREETING=key=value=pairs"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
