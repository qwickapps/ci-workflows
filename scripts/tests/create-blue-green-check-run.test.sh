#!/usr/bin/env bash
#
# Scenario tests for scripts/create-blue-green-check-run.sh (aos#193 Phase
# 1 §1/§2/§5). Invokes the real script as a subprocess with `gh` replaced
# by a mock first on PATH.
#
# Primary focus (aos#193 review §5 mutation gap "P5"): --on-permission-denied
# skip must swallow ONLY a genuine 403 ("HTTP 403" or "Resource not
# accessible by integration"), never any other `gh api` failure. A
# mutation that broadens the matching grep to catch ANY error (e.g.
# dropping the -E pattern for a bare `true`, or swapping it for something
# that always matches) would make `skip` silently hide a real outage
# (network failure, malformed payload, rate limit, etc.) as if it were the
# documented "checks:write not granted yet" case -- this must fail closed
# instead of skip.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SUT="$SCRIPTS_DIR/create-blue-green-check-run.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0
mkdir -p "$TMPDIR/bin"

cat > "$TMPDIR/bin/gh" <<MOCK
#!/usr/bin/env bash
if [ "\${1:-}" != "api" ]; then
  echo "mock gh: unexpected command: \$*" >&2
  exit 1
fi
mode="\${MOCK_GH_MODE:-success}"
case "\$mode" in
  success)
    echo '{"id": 12345, "html_url": "https://github.com/qwickapps/demo/runs/12345"}'
    ;;
  http_403)
    echo "gh: HTTP 403: Resource not accessible by integration" >&2
    exit 1
    ;;
  resource_not_accessible)
    echo "gh: Resource not accessible by integration" >&2
    exit 1
    ;;
  network_error)
    echo "gh: could not connect to api.github.com: connection reset by peer" >&2
    exit 1
    ;;
  rate_limited)
    echo "gh: API rate limit exceeded (HTTP 429)" >&2
    exit 1
    ;;
  malformed_payload)
    echo "gh: Unprocessable Entity (HTTP 422): head_sha is not a valid commit sha" >&2
    exit 1
    ;;
  bad_response)
    echo '{"unexpected": "shape, no id field"}'
    ;;
esac
MOCK
chmod +x "$TMPDIR/bin/gh"

run_sut() {
  local out_file="$1"; shift
  (
    export PATH="$TMPDIR/bin:$PATH"
    bash "$SUT" \
      --github-token irrelevant \
      --repo "qwickapps/demo" \
      --sha "0123456789abcdef0123456789abcdef01234567" \
      --name "blue-green/live-e2e-approved/demo" \
      --title "Live e2e validated" \
      --summary "test" \
      "$@"
  ) > "$out_file" 2>&1
}

assert_exit() {
  local desc="$1" expected_rc="$2"; shift 2
  local out="$TMPDIR/out-$RANDOM"
  set +e
  run_sut "$out" "$@"
  local rc=$?
  set -e
  if [ "$rc" -eq "$expected_rc" ]; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc -- expected exit=$expected_rc, got $rc"
    sed 's/^/      /' "$out"
    fail=$((fail + 1))
  fi
}

echo "== create-blue-green-check-run.sh: baseline success/failure =="

MOCK_GH_MODE=success assert_exit "successful creation -> exit 0" 0

MOCK_GH_MODE=bad_response assert_exit "response with no .id field -> exit 1 (unexpected response)" 1

echo ""
echo "== create-blue-green-check-run.sh: --on-permission-denied skip scope (aos#193 review §5 mutation gap 'P5') =="

MOCK_GH_MODE=http_403 assert_exit "genuine 'HTTP 403' error + --on-permission-denied skip -> exit 0 (documented skip case)" 0 --on-permission-denied skip

MOCK_GH_MODE=resource_not_accessible assert_exit "genuine 'Resource not accessible by integration' error + --on-permission-denied skip -> exit 0" 0 --on-permission-denied skip

MOCK_GH_MODE=http_403 assert_exit "genuine 403 error WITHOUT --on-permission-denied skip (default 'fail') -> exit 1" 1

MOCK_GH_MODE=network_error assert_exit "a NETWORK error (not a 403) + --on-permission-denied skip -> still exit 1 -- skip must never swallow a non-permission failure" 1 --on-permission-denied skip

MOCK_GH_MODE=rate_limited assert_exit "a RATE-LIMIT error (HTTP 429, not 403) + --on-permission-denied skip -> still exit 1" 1 --on-permission-denied skip

MOCK_GH_MODE=malformed_payload assert_exit "a MALFORMED-PAYLOAD error (HTTP 422, not 403) + --on-permission-denied skip -> still exit 1" 1 --on-permission-denied skip

echo ""
echo "== create-blue-green-check-run.sh: --output-json validation =="

OUT="$TMPDIR/out-badjson"
MOCK_GH_MODE=success
set +e
(
  export PATH="$TMPDIR/bin:$PATH"
  bash "$SUT" \
    --github-token irrelevant --repo "qwickapps/demo" \
    --sha "0123456789abcdef0123456789abcdef01234567" \
    --name "blue-green/live-e2e-approved/demo" \
    --title "t" --summary "s" \
    --output-json "not valid json"
) > "$OUT" 2>&1
RC=$?
set -e
if [ "$RC" -eq 2 ] && grep -qF "not valid JSON" "$OUT"; then
  echo "  PASS: invalid --output-json is rejected before ever calling gh"
  pass=$((pass + 1))
else
  echo "  FAIL: invalid --output-json should be rejected with exit 2 -- got exit=$RC"
  sed 's/^/      /' "$OUT"
  fail=$((fail + 1))
fi

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
