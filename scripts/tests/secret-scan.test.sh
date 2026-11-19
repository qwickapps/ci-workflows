#!/usr/bin/env bash
# scripts/tests/secret-scan.test.sh
#
# Regression gate for scripts/lib/secret-scan.py -- the leak-prevention
# scanner (aos#198, triggered by aos#191 committing 28 live credentials
# into a test fixture). Every positive case is a SYNTHETIC value.
#
# Two assertion shapes, per research-lead's aos#191 review of their own
# first-pass detector ("a detector cannot validate itself; re-running blind
# patterns over their own output proves only that they're still blind"):
#   RED  -- every credential class this scanner must catch, seeded fresh.
#   QUIET -- hashes, source identifiers, paths/URLs, and other benign
#            shapes that a naive entropy fallback tends to also flag,
#            which is what makes a "no override" gate unlivable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)/.."
SCANNER="$ROOT/scripts/lib/secret-scan.py"

pass=0
fail=0

assert_red() {
  local name="$1" line="$2"
  local rc
  printf '+%s' "$line" | python3 "$SCANNER" --diff >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 1 ]]; then
    printf '[PASS] RED: %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '[FAIL] RED: %s should have been flagged (rc=%s): %s\n' "$name" "$rc" "$line"
    fail=$((fail + 1))
  fi
}

assert_quiet() {
  local name="$1" line="$2"
  local out rc
  out="$(printf '+%s' "$line" | python3 "$SCANNER" --diff 2>&1)"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    printf '[PASS] QUIET: %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '[FAIL] QUIET: %s incorrectly flagged: %s\n' "$name" "$out"
    fail=$((fail + 1))
  fi
}

# ---------------------------------------------------------------------------
# RED: every credential class aos#198 requires, synthetic values only.
# ---------------------------------------------------------------------------

assert_red "tskey-auth, bare (no assignment at all -- aos#191 review gap #1)" \
  'tailscale up --authkey=tskey-auth-kABCDE1234CNTRL-abcdefghijklmnopqrstuvwxyz1234'
assert_red "tskey-api" \
  'TS_KEY=tskey-api-kABCDE1234CNTRL-abcdefghijklmnopqrstuvwxyz1234'
assert_red "github classic PAT" \
  'GH_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
assert_red "github fine-grained PAT" \
  'GITHUB_PAT=github_pat_11ABCDEFG0abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGabcdefghij'
assert_red "anthropic key" \
  'ANTHROPIC_API_KEY=sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnop'
assert_red "openai-style sk- key" \
  'OPENAI_KEY=sk-ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefgh'
assert_red "litellm key" \
  'LITELLM_KEY=sk-litellm-ABCDEFGHIJKLMNOP'
assert_red "coolify sanctum token, contains a pipe (aos#191 review gap #3)" \
  'COOLIFY_TOKEN=12|abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNO'
assert_red "coolify token via generic momo-specific name" \
  'COOLIFY_MOMO_TOKEN=7|abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNO'
assert_red "telegram bot token" \
  'BOT_TOKEN=123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi'
assert_red "private key block" \
  '-----BEGIN OPENSSH PRIVATE KEY-----'
assert_red "db url with inline credentials" \
  'DATABASE_URL=postgres://appuser:hunter2pass@db.internal:5432/appdb'
assert_red "curl basic auth flag" \
  'curl -u produser:s3cr3tpass https://api.example.com'
assert_red "sshpass -p" \
  'sshpass -p hunter2pass ssh user@host'
assert_red "json password field" \
  '{"username":"admin","password":"hunter2pass"}'
assert_red "single-quoted secret assignment (aos#191 review gap #2)" \
  "MY_SECRET='abc123XyzSecretValue987'"
assert_red "arbitrary *_KEY= name, not just API_KEY (aos#191 review gap #4)" \
  'SOME_SERVICE_KEY=abcd1234efgh5678'
assert_red "MCP_PASS after a pipe" \
  'echo x | MCP_PASS=abcd1234efgh5678 some-command'
assert_red "CapRover password via generic _PASSWORD= rule" \
  'CAPROVER_PASSWORD=hunter2pass'
assert_red "unnamed high-entropy value, no format rule for it (aos#191 review gap #5)" \
  'random_blob = aZ9kQm2Vx7Lp4Rt8Bn3Wf6Yc1Ju5Ho0Se2Di9Gk'

# ---------------------------------------------------------------------------
# QUIET: benign shapes a naive entropy fallback tends to also flag.
# ---------------------------------------------------------------------------

assert_quiet "a long commit SHA" \
  'Fixes 486def1b8e9c520e4692557e738a26c9384645dd'
assert_quiet "a hash= assignment of a long hex digest (this scanner's own bug, found and fixed against this exact case)" \
  'hash=486def1b8e9c520e4692557e738a26c9384645dd'
assert_quiet "a public https URL with no credentials" \
  'curl https://api.tailscale.com/api/v2/device/123/name'
assert_quiet "mention of an env var name with no assignment" \
  'the hook checks whether GITHUB_TOKEN is set'
assert_quiet "a long snake_case source identifier" \
  '_maybe_spawn_session_reviewer_helper_function is defined here'
assert_quiet "a dunder-heavy MCP tool name" \
  'call mcp__qwickapps__send_telegram with a message'
assert_quiet "a relative path" \
  'tests/fixtures/sentinel_classifier/corpus.log.gz'
assert_quiet "a URL tail with no scheme" \
  'see //api.anthropic.com/v1/messages for docs'
assert_quiet "a docker image digest" \
  'image: myapp@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
assert_quiet "an ordinary sentence containing the word key" \
  'this is the key insight of the design'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
