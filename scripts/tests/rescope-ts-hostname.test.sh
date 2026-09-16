#!/usr/bin/env bash
# Unit tests for scripts/rescope-ts-hostname.sh (protocols#299, ported into
# the shared promote-to-stable.yml).
#
# Review on ci-workflows#202: the port added a presence gate that does not
# exist in the original fix (documents' swap-instances.sh set_ts_hostname(),
# which is unconditional) and shipped with zero tests for it. These tests
# cover exactly the cases the review asked for: key present (with a real
# value), key absent, key present-but-empty, key present-but-whitespace --
# plus a sanity check that other stable-app fields survive untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT

# shellcheck source=/dev/null
source "$ROOT/scripts/rescope-ts-hostname.sh"

pass=0
fail=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $name"
    pass=$((pass + 1))
  else
    echo "not ok - $name"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    fail=$((fail + 1))
  fi
}

STABLE_DEF='{"appName":"img-documents-stable","instanceCount":1,"envVars":[{"key":"OLD","value":"stale"}]}'

# ── Case 1: key present with a real (build-slot) value -> rescoped ─────────
ENV_PRESENT='[{"key":"TS_HOSTNAME","value":"img-documents-build"},{"key":"OTHER","value":"x"}]'
RESULT_PRESENT="$(rescope_ts_hostname "$STABLE_DEF" "$ENV_PRESENT" "img-documents-stable")"
TS_VALUE="$(echo "$RESULT_PRESENT" | jq -r '.envVars[] | select(.key=="TS_HOSTNAME") | .value')"
assert_eq "key present -> rescoped to the stable app's own name" "img-documents-stable" "$TS_VALUE"

# ── Case 2: key absent entirely -> no TS_HOSTNAME key introduced ───────────
ENV_ABSENT='[{"key":"OTHER","value":"x"}]'
RESULT_ABSENT="$(rescope_ts_hostname "$STABLE_DEF" "$ENV_ABSENT" "img-documents-stable")"
HAS_TS="$(echo "$RESULT_ABSENT" | jq -e 'any(.envVars[]; .key=="TS_HOSTNAME")' >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "key absent -> no TS_HOSTNAME introduced" "no" "$HAS_TS"
OTHER_STILL_THERE="$(echo "$RESULT_ABSENT" | jq -r '.envVars[] | select(.key=="OTHER") | .value')"
assert_eq "key absent -> other env vars still copied over" "x" "$OTHER_STILL_THERE"

# ── Case 3: key present but value is an empty string -> still rescoped ─────
# (presence of the key is what gates this, not the content of its value)
ENV_EMPTY='[{"key":"TS_HOSTNAME","value":""}]'
RESULT_EMPTY="$(rescope_ts_hostname "$STABLE_DEF" "$ENV_EMPTY" "img-documents-stable")"
TS_VALUE_EMPTY="$(echo "$RESULT_EMPTY" | jq -r '.envVars[] | select(.key=="TS_HOSTNAME") | .value')"
assert_eq "key present with empty value -> still rescoped" "img-documents-stable" "$TS_VALUE_EMPTY"

# ── Case 4: key present but value is whitespace-only -> still rescoped ─────
ENV_WHITESPACE='[{"key":"TS_HOSTNAME","value":"   "}]'
RESULT_WHITESPACE="$(rescope_ts_hostname "$STABLE_DEF" "$ENV_WHITESPACE" "img-documents-stable")"
TS_VALUE_WS="$(echo "$RESULT_WHITESPACE" | jq -r '.envVars[] | select(.key=="TS_HOSTNAME") | .value')"
assert_eq "key present with whitespace-only value -> still rescoped" "img-documents-stable" "$TS_VALUE_WS"

# ── Sanity: fields on the stable app definition other than envVars survive
# untouched (this is a targeted patch of one field, not a rebuild). ────────
INSTANCE_COUNT="$(echo "$RESULT_PRESENT" | jq -r '.instanceCount')"
assert_eq "unrelated stable-app fields are preserved" "1" "$INSTANCE_COUNT"
APP_NAME_FIELD="$(echo "$RESULT_PRESENT" | jq -r '.appName')"
assert_eq "appName field is preserved" "img-documents-stable" "$APP_NAME_FIELD"

# ── Sanity: exactly one TS_HOSTNAME entry survives, not a duplicate ────────
TS_COUNT="$(echo "$RESULT_PRESENT" | jq '[.envVars[] | select(.key=="TS_HOSTNAME")] | length')"
assert_eq "exactly one TS_HOSTNAME entry after rescoping (no duplicate)" "1" "$TS_COUNT"

echo
echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
