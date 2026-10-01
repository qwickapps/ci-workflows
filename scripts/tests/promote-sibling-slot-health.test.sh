#!/usr/bin/env bash
#
# Dynamic regression test for the blue-green promotion contract: a promotion
# must fail closed unless BOTH live and stable slots are healthy afterwards.
# The test extracts the actual sibling-health `run:` blocks from the reusable
# workflows, executes them with mocked curl/sleep, and proves each accepts a
# healthy sibling but fails after its bounded retry budget when that sibling
# remains unavailable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
LIVE_WORKFLOW="$ROOT_DIR/.github/workflows/promote-to-live.yml"
STABLE_WORKFLOW="$ROOT_DIR/.github/workflows/promote-to-stable.yml"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass=0
fail=0

extract_step() {
  local workflow="$1" job="$2" step_name="$3"
  python3 - "$workflow" "$job" "$step_name" <<'PY'
import sys
import yaml

workflow, job, step_name = sys.argv[1:]
with open(workflow, encoding="utf-8") as f:
    doc = yaml.safe_load(f)
for step in doc["jobs"][job]["steps"]:
    if step.get("name") == step_name:
        print(step["run"])
        break
else:
    raise SystemExit(f"step not found: {step_name}")
PY
}

assert() {
  local description="$1"
  shift
  if "$@"; then
    echo "  PASS: $description"
    pass=$((pass + 1))
  else
    echo "  FAIL: $description"
    fail=$((fail + 1))
  fi
}

assert_step_order() {
  local workflow="$1" job="$2" primary="$3" sibling="$4"
  python3 - "$workflow" "$job" "$primary" "$sibling" <<'PY'
import sys
import yaml

workflow, job, primary, sibling = sys.argv[1:]
with open(workflow, encoding="utf-8") as f:
    steps = yaml.safe_load(f)["jobs"][job]["steps"]
names = [step.get("name") for step in steps]
sys.exit(0 if names.index(sibling) > names.index(primary) else 1)
PY
}

make_mocks() {
  local mock_dir="$1"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
exit "$CURL_RC"
SH
  cat > "$mock_dir/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SLEEP_LOG"
SH
  chmod +x "$mock_dir/curl" "$mock_dir/sleep"
}

run_step() {
  local script="$1" curl_rc="$2" health_var="$3" health_url="$4" output="$5"
  local run_dir="$TMPDIR_TEST/run-$RANDOM"
  mkdir -p "$run_dir"
  make_mocks "$run_dir/bin"
  : > "$run_dir/curl.log"
  : > "$run_dir/sleep.log"

  set +e
  (
    export PATH="$run_dir/bin:$PATH"
    export CURL_LOG="$run_dir/curl.log" SLEEP_LOG="$run_dir/sleep.log" CURL_RC="$curl_rc"
    export HEALTH_PATH="/_health"
    export "$health_var=$health_url"
    bash "$script"
  ) > "$output" 2>&1
  local rc=$?
  set -e

  printf '%s\n%s\n%s\n' "$rc" "$run_dir/curl.log" "$run_dir/sleep.log"
}

check_case() {
  local label="$1" script="$2" health_var="$3" health_url="$4" expected_error="$5"
  local result rc curl_log sleep_log output

  output="$TMPDIR_TEST/${label// /-}-healthy.out"
  result="$(run_step "$script" 0 "$health_var" "$health_url" "$output")"
  rc="$(printf '%s\n' "$result" | sed -n '1p')"
  curl_log="$(printf '%s\n' "$result" | sed -n '2p')"
  sleep_log="$(printf '%s\n' "$result" | sed -n '3p')"
  assert "$label: healthy sibling succeeds immediately" test "$rc" -eq 0
  assert "$label: healthy sibling uses the expected URL" grep -qF -- "${health_url}/_health" "$curl_log"
  assert "$label: healthy sibling does not back off" test ! -s "$sleep_log"

  output="$TMPDIR_TEST/${label// /-}-unhealthy.out"
  result="$(run_step "$script" 22 "$health_var" "$health_url" "$output")"
  rc="$(printf '%s\n' "$result" | sed -n '1p')"
  curl_log="$(printf '%s\n' "$result" | sed -n '2p')"
  sleep_log="$(printf '%s\n' "$result" | sed -n '3p')"
  assert "$label: unhealthy sibling fails the promotion" test "$rc" -ne 0
  assert "$label: unhealthy sibling is retried exactly three times" test "$(wc -l < "$curl_log")" -eq 3
  assert "$label: unhealthy sibling backs off only between attempts" test "$(wc -l < "$sleep_log")" -eq 2
  assert "$label: failure identifies the sibling health gate" grep -qF -- "$expected_error" "$output"
}

live_script="$TMPDIR_TEST/live-sibling-health.sh"
stable_script="$TMPDIR_TEST/stable-sibling-health.sh"
extract_step "$LIVE_WORKFLOW" "promote-to-live" "Validate stable slot health after live promotion" > "$live_script"
extract_step "$STABLE_WORKFLOW" "promote-to-stable" "Validate live slot health after stable promotion" > "$stable_script"

assert "promote-to-live checks stable only after validating live" \
  assert_step_order "$LIVE_WORKFLOW" "promote-to-live" "Validate live slot health" "Validate stable slot health after live promotion"
assert "promote-to-stable checks live only after validating stable" \
  assert_step_order "$STABLE_WORKFLOW" "promote-to-stable" "Validate stable slot health" "Validate live slot health after stable promotion"

check_case "promote-to-live" "$live_script" "STABLE_TAILNET_HEALTH_URL" \
  "http://demo-stable.taile324e7.ts.net:8080" \
  "ERROR: Stable slot health check failed after 3 attempts."
check_case "promote-to-stable" "$stable_script" "LIVE_APP_URL" \
  "https://demo-live.app.qwickforge.com" \
  "ERROR: Live slot health check failed after 3 attempts."

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
