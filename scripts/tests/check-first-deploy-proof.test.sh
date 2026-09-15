#!/usr/bin/env bash
#
# Scenario tests for scripts/check-first-deploy-proof.sh (aos#193 Phase 1
# §2). Invokes the real script as a subprocess (it has its own shebang and
# calls `exit` directly, so it isn't safely sourceable the way
# lib/caprover-api.sh's individual functions are in
# caprover-ensure-app.test.sh) with `curl` and `gh` replaced by small mock
# scripts placed first on PATH -- this proves the actual 3-way verdict
# logic (CapRover app-absence AND GHCR tag-history-absence AND
# first-deploy-used-marker-absence => first_deploy=true; any one of the
# three present => first_deploy=false), not just that the script parses.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SUT="$SCRIPTS_DIR/check-first-deploy-proof.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0

mkdir -p "$TMPDIR/bin"

cat > "$TMPDIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
url=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  a="${args[$i]}"
  case "$a" in
    --url) i=$((i + 1)); url="${args[$i]}" ;;
    http*://*) url="$a" ;;
  esac
  i=$((i + 1))
done
case "$url" in
  */api/v2/login)
    echo '{"data":{"token":"mock-token"}}'
    ;;
  */api/v2/user/apps/appDefinitions)
    if [ "${MOCK_CAPROVER_APP_EXISTS:-0}" = "1" ]; then
      echo "{\"data\":{\"appDefinitions\":[{\"appName\":\"${MOCK_STABLE_APP_NAME:-demo-stable}\",\"hasPersistentData\":false}]}}"
    else
      echo '{"data":{"appDefinitions":[]}}'
    fi
    ;;
  *)
    echo "mock curl: unexpected url: $url" >&2
    exit 1
    ;;
esac
MOCK

cat > "$TMPDIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
if [ "${1:-}" != "api" ]; then
  echo "mock gh: unexpected command: $*" >&2
  exit 1
fi
shift
url=""
for a in "$@"; do
  case "$a" in
    -*) ;;
    *) url="$a" ;;
  esac
done
case "$url" in
  *packages/container*/versions*)
    if [ "${MOCK_GHCR_404:-0}" = "1" ]; then
      echo "gh: Package not found. (HTTP 404)" >&2
      exit 1
    fi
    if [ "${MOCK_GHCR_TAG_HISTORY:-0}" = "1" ]; then
      echo '[{"id":1,"metadata":{"container":{"tags":["release"]}}},{"id":2,"metadata":{"container":{"tags":["sha-abc123"]}}}]'
    else
      echo '[{"id":2,"metadata":{"container":{"tags":["sha-abc123"]}}}]'
    fi
    ;;
  *commits/*/check-runs*)
    if [ "${MOCK_MARKER_FOUND:-0}" = "1" ]; then
      echo '{"total_count":1,"check_runs":[{"id":1,"name":"blue-green/first-deploy-used"}]}'
    else
      echo '{"total_count":0,"check_runs":[]}'
    fi
    ;;
  *)
    echo "mock gh: unexpected api url: $url" >&2
    exit 1
    ;;
esac
MOCK

chmod +x "$TMPDIR/bin/curl" "$TMPDIR/bin/gh"

run_sut() {
  local out_file="$1"
  (
    export PATH="$TMPDIR/bin:$PATH"
    export MOCK_CAPROVER_APP_EXISTS="${MOCK_CAPROVER_APP_EXISTS:-0}"
    export MOCK_GHCR_TAG_HISTORY="${MOCK_GHCR_TAG_HISTORY:-0}"
    export MOCK_GHCR_404="${MOCK_GHCR_404:-0}"
    export MOCK_MARKER_FOUND="${MOCK_MARKER_FOUND:-0}"
    export MOCK_STABLE_APP_NAME="demo-stable"
    export GITHUB_OUTPUT="$TMPDIR/gh-output-$$"
    : > "$GITHUB_OUTPUT"
    bash "$SUT" \
      --caprover-url "https://captain.app.qwickforge.com" \
      --caprover-password "irrelevant" \
      --stable-app-name "demo-stable" \
      --github-token "irrelevant" \
      --owner "qwickapps" \
      --repo "qwickapps/demo" \
      --image-name "img-demo" \
      --commit-sha "0123456789abcdef0123456789abcdef01234567"
  ) > "$out_file" 2>&1
}

assert_verdict() {
  local desc="$1" expected="$2"
  local out="$TMPDIR/out-$RANDOM"
  set +e
  run_sut "$out"
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "  FAIL: $desc -- script exited $rc (expected 0)"
    sed 's/^/      /' "$out"
    fail=$((fail + 1))
    return
  fi
  local actual
  actual="$(tail -n1 "$out")"
  if [ "$actual" = "first_deploy=${expected}" ]; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc -- expected 'first_deploy=${expected}', got '${actual}'"
    sed 's/^/      /' "$out"
    fail=$((fail + 1))
  fi
}

echo "== check-first-deploy-proof.sh: 3-way verdict logic =="

MOCK_CAPROVER_APP_EXISTS=0 MOCK_GHCR_TAG_HISTORY=0 MOCK_GHCR_404=0 MOCK_MARKER_FOUND=0 \
  assert_verdict "all three absent -> first_deploy=true (genuinely new app)" "true"

MOCK_CAPROVER_APP_EXISTS=0 MOCK_GHCR_404=1 MOCK_MARKER_FOUND=0 \
  assert_verdict "GHCR package never published (404) counts as absent, combined with the other two -> true" "true"

MOCK_CAPROVER_APP_EXISTS=1 MOCK_GHCR_TAG_HISTORY=0 MOCK_MARKER_FOUND=0 \
  assert_verdict "CapRover <app>-stable exists -> false" "false"

MOCK_CAPROVER_APP_EXISTS=0 MOCK_GHCR_TAG_HISTORY=1 MOCK_MARKER_FOUND=0 \
  assert_verdict "GHCR has release/stable tag history (app was promoted, slot later deleted) -> false" "false"

MOCK_CAPROVER_APP_EXISTS=0 MOCK_GHCR_TAG_HISTORY=0 MOCK_MARKER_FOUND=1 \
  assert_verdict "first-deploy-used marker already recorded on this commit -> false" "false"

MOCK_CAPROVER_APP_EXISTS=1 MOCK_GHCR_TAG_HISTORY=1 MOCK_MARKER_FOUND=1 \
  assert_verdict "all three present -> false" "false"

echo ""
echo "== check-first-deploy-proof.sh: hard failures never guess a verdict =="

CAPROVER_LOGIN_FAIL_OUT="$TMPDIR/out-login-fail"
cat > "$TMPDIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"data":{"token":null}}'
MOCK
chmod +x "$TMPDIR/bin/curl"
set +e
(
  export PATH="$TMPDIR/bin:$PATH"
  bash "$SUT" \
    --caprover-url "https://captain.app.qwickforge.com" \
    --caprover-password "irrelevant" \
    --stable-app-name "demo-stable" \
    --github-token "irrelevant" \
    --owner "qwickapps" \
    --repo "qwickapps/demo" \
    --image-name "img-demo" \
    --commit-sha "0123456789abcdef0123456789abcdef01234567"
) > "$CAPROVER_LOGIN_FAIL_OUT" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "  PASS: CapRover auth failure exits non-zero (never guesses first-deploy status)"
  pass=$((pass + 1))
else
  echo "  FAIL: CapRover auth failure should exit non-zero"
  sed 's/^/      /' "$CAPROVER_LOGIN_FAIL_OUT"
  fail=$((fail + 1))
fi

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
