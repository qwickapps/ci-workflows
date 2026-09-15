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

RUN_ID="99887766"
RUN_ATTEMPT="1"
EXTERNAL_ID="${RUN_ID}-${RUN_ATTEMPT}"
COMMIT_SHA="0123456789abcdef0123456789abcdef01234567"
REPO="qwickapps/demo"
WORKFLOW_PATH="qwickapps/ci-workflows/.github/workflows/deploy-app.yml@refs/heads/main"

VALID_MARKER_JSON="$(jq -nc --arg repo "$REPO" --arg sha "$COMMIT_SHA" '{repo:$repo,app_name:"demo",sha:$sha}')"
RUN_RESPONSE_FILE="$TMPDIR/gh-run-response.json"

write_valid_run_response() {
  jq -nc --arg sha "$COMMIT_SHA" --arg repo "$REPO" --arg wf "$WORKFLOW_PATH" '{
    head_sha: $sha,
    repository: {full_name: $repo},
    status: "completed",
    referenced_workflows: [{path: $wf}]
  }' > "$RUN_RESPONSE_FILE"
}
write_valid_run_response

cat > "$TMPDIR/bin/curl" <<MOCK
#!/usr/bin/env bash
url=""
args=("\$@")
i=0
while [ \$i -lt \${#args[@]} ]; do
  a="\${args[\$i]}"
  case "\$a" in
    --url) i=\$((i + 1)); url="\${args[\$i]}" ;;
    http*://*) url="\$a" ;;
  esac
  i=\$((i + 1))
done
case "\$url" in
  */api/v2/login)
    echo '{"data":{"token":"mock-token"}}'
    ;;
  */api/v2/user/apps/appDefinitions)
    case "\${MOCK_CAPROVER_MODE:-normal}" in
      exists)
        echo "{\\"status\\":100,\\"data\\":{\\"appDefinitions\\":[{\\"appName\\":\\"\${MOCK_STABLE_APP_NAME:-demo-stable}\\",\\"hasPersistentData\\":false}]}}"
        ;;
      absent)
        echo '{"status":100,"data":{"appDefinitions":[]}}'
        ;;
      error_envelope)
        # aos#193 review finding #3 repro: CapRover's real HTTP-200 error
        # shape -- valid JSON, but no .data.appDefinitions at all.
        echo '{"status":1106,"description":"Auth token corrupted"}'
        ;;
      empty_object)
        echo '{}'
        ;;
    esac
    ;;
  *)
    echo "mock curl: unexpected url: \$url" >&2
    exit 1
    ;;
esac
MOCK

cat > "$TMPDIR/bin/gh" <<MOCK
#!/usr/bin/env bash
if [ "\${1:-}" != "api" ]; then
  echo "mock gh: unexpected command: \$*" >&2
  exit 1
fi
shift
url=""
for a in "\$@"; do
  case "\$a" in
    -*) ;;
    *) url="\$a" ;;
  esac
done
case "\$url" in
  *packages/container*/versions*)
    case "\${MOCK_GHCR_MODE:-none}" in
      none)
        echo '[{"id":2,"metadata":{"container":{"tags":["sha-abc123"]}}}]'
        ;;
      history)
        echo '[{"id":1,"metadata":{"container":{"tags":["release"]}}},{"id":2,"metadata":{"container":{"tags":["sha-abc123"]}}}]'
        ;;
      404_genuine)
        echo "gh: Package not found. (HTTP 404)" >&2
        exit 1
        ;;
      404_permission_denied)
        # aos#193 review finding #3 repro: a 404 WITHOUT the specific
        # "Package not found." message (e.g. a private package this
        # token cannot read) must NOT be treated as absence.
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1
        ;;
      non_json)
        echo 'this is not json'
        ;;
      empty)
        echo -n ''
        ;;
    esac
    ;;
  *orgs/*/packages*package_type=container*)
    # aos#193 review finding #2 repro (round 2): the positive-visibility
    # probe queried before a 404 is ever trusted as absence.
    case "\${MOCK_VISIBILITY_MODE:-visible}" in
      visible)
        echo '[{"id":1,"name":"some-other-package","package_type":"container"}]'
        ;;
      empty)
        echo '[]'
        ;;
      fails)
        echo "gh: Forbidden (HTTP 403)" >&2
        exit 1
        ;;
    esac
    ;;
  *commits/*/check-runs*)
    case "\${MOCK_MARKER_MODE:-none}" in
      none)
        echo '{"total_count":0,"check_runs":[]}'
        ;;
      valid)
        echo "{\\"total_count\\":1,\\"check_runs\\":[{\\"id\\":1,\\"name\\":\\"blue-green/first-deploy-used/demo\\",\\"output\\":{\\"text\\":\${MOCK_MARKER_TEXT_JSON}},\\"app\\":{\\"slug\\":\\"\${MOCK_MARKER_APP_SLUG:-github-actions}\\"},\\"external_id\\":\\"\${MOCK_MARKER_EXTERNAL_ID:-$EXTERNAL_ID}\\"}]}"
        ;;
    esac
    ;;
  *actions/runs/*)
    cat "$RUN_RESPONSE_FILE"
    ;;
  *)
    echo "mock gh: unexpected api url: \$url" >&2
    exit 1
    ;;
esac
MOCK

chmod +x "$TMPDIR/bin/curl" "$TMPDIR/bin/gh"

run_sut() {
  local out_file="$1"
  (
    export PATH="$TMPDIR/bin:$PATH"
    export MOCK_CAPROVER_MODE="${MOCK_CAPROVER_MODE:-absent}"
    export MOCK_GHCR_MODE="${MOCK_GHCR_MODE:-none}"
    export MOCK_VISIBILITY_MODE="${MOCK_VISIBILITY_MODE:-visible}"
    export MOCK_MARKER_MODE="${MOCK_MARKER_MODE:-none}"
    export MOCK_MARKER_TEXT_JSON="${MOCK_MARKER_TEXT_JSON:-$(jq -nc --arg v "$VALID_MARKER_JSON" '$v')}"
    export MOCK_MARKER_APP_SLUG="${MOCK_MARKER_APP_SLUG:-github-actions}"
    export MOCK_MARKER_EXTERNAL_ID="${MOCK_MARKER_EXTERNAL_ID:-$EXTERNAL_ID}"
    export MOCK_STABLE_APP_NAME="demo-stable"
    export GITHUB_OUTPUT="$TMPDIR/gh-output-$$"
    : > "$GITHUB_OUTPUT"
    bash "$SUT" \
      --caprover-url "https://captain.app.qwickforge.com" \
      --caprover-password "irrelevant" \
      --stable-app-name "demo-stable" \
      --github-token "irrelevant" \
      --owner "qwickapps" \
      --repo "$REPO" \
      --app-name "demo" \
      --image-name "img-demo" \
      --commit-sha "$COMMIT_SHA"
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

assert_hard_failure() {
  local desc="$1" needle="$2"
  local out="$TMPDIR/out-$RANDOM"
  set +e
  run_sut "$out"
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ] && grep -qF "$needle" "$out"; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc -- expected exit!=0 containing '$needle', got exit=$rc"
    sed 's/^/      /' "$out"
    fail=$((fail + 1))
  fi
}

echo "== check-first-deploy-proof.sh: 3-way verdict logic =="

MOCK_CAPROVER_MODE=absent MOCK_GHCR_MODE=none MOCK_MARKER_MODE=none \
  assert_verdict "all three absent -> first_deploy=true (genuinely new app)" "true"

MOCK_CAPROVER_MODE=absent MOCK_GHCR_MODE=404_genuine MOCK_VISIBILITY_MODE=visible MOCK_MARKER_MODE=none \
  assert_verdict "GHCR package never published (genuine 404, positive 'Package not found' evidence, AND confirmed token package-visibility) counts as absent, combined with the other two -> true" "true"

MOCK_CAPROVER_MODE=exists MOCK_GHCR_MODE=none MOCK_MARKER_MODE=none \
  assert_verdict "CapRover <app>-stable exists -> false" "false"

MOCK_CAPROVER_MODE=absent MOCK_GHCR_MODE=history MOCK_MARKER_MODE=none \
  assert_verdict "GHCR has release/stable tag history (app was promoted, slot later deleted) -> false" "false"

MOCK_CAPROVER_MODE=absent MOCK_GHCR_MODE=none MOCK_MARKER_MODE=valid \
  assert_verdict "valid first-deploy-used marker already recorded on this commit, for this app, by the legitimate workflow -> false" "false"

MOCK_CAPROVER_MODE=exists MOCK_GHCR_MODE=history MOCK_MARKER_MODE=valid \
  assert_verdict "all three present -> false" "false"

echo ""
echo "== check-first-deploy-proof.sh: hard failures never guess a verdict =="

assert_hard_failure_custom() {
  # Like assert_hard_failure, but with a fully custom curl mock swapped in
  # first (for the CapRover-login-failure case, which doesn't fit the
  # MOCK_CAPROVER_MODE switch above).
  local desc="$1" needle="$2"
  local out="$TMPDIR/out-$RANDOM"
  set +e
  (
    export PATH="$TMPDIR/bin:$PATH"
    export GITHUB_OUTPUT="$TMPDIR/gh-output-custom-$$"
    : > "$GITHUB_OUTPUT"
    bash "$SUT" \
      --caprover-url "https://captain.app.qwickforge.com" \
      --caprover-password "irrelevant" \
      --stable-app-name "demo-stable" \
      --github-token "irrelevant" \
      --owner "qwickapps" \
      --repo "$REPO" \
      --app-name "demo" \
      --image-name "img-demo" \
      --commit-sha "$COMMIT_SHA"
  ) > "$out" 2>&1
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ] && grep -qF "$needle" "$out"; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc -- expected exit!=0 containing '$needle', got exit=$rc"
    sed 's/^/      /' "$out"
    fail=$((fail + 1))
  fi
}

cat > "$TMPDIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
echo '{"data":{"token":null}}'
MOCK
chmod +x "$TMPDIR/bin/curl"
assert_hard_failure_custom "CapRover auth failure exits non-zero (never guesses first-deploy status)" "could not authenticate to CapRover"

echo ""
echo "== check-first-deploy-proof.sh: CapRover HTTP-200 error envelope must NOT be read as app-absence (aos#193 review finding #3) =="

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
  */api/v2/login) echo '{"data":{"token":"mock-token"}}' ;;
  */api/v2/user/apps/appDefinitions) echo '{"status":1106,"description":"Auth token corrupted"}' ;;
  *) echo "unexpected url: $url" >&2; exit 1 ;;
esac
MOCK
chmod +x "$TMPDIR/bin/curl"
MOCK_CAPROVER_MODE=error_envelope MOCK_GHCR_MODE=none MOCK_MARKER_MODE=none \
  assert_hard_failure "CapRover HTTP-200 error envelope ({\"status\":1106,...}) is a hard failure, never read as app-absence" "CapRover appDefinitions query failed"

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
  */api/v2/login) echo '{"data":{"token":"mock-token"}}' ;;
  */api/v2/user/apps/appDefinitions) echo '{}' ;;
  *) echo "unexpected url: $url" >&2; exit 1 ;;
esac
MOCK
chmod +x "$TMPDIR/bin/curl"
MOCK_CAPROVER_MODE=empty_object MOCK_GHCR_MODE=none MOCK_MARKER_MODE=none \
  assert_hard_failure "CapRover '{}' response is a hard failure, never read as app-absence" "CapRover appDefinitions query failed"

echo ""
echo "== check-first-deploy-proof.sh: GHCR parse failures never guess 'no history' (aos#193 review finding #3) =="

# Restore the normal (status-carrying) curl mock for the remaining GHCR/marker tests.
cat > "$TMPDIR/bin/curl" <<MOCK
#!/usr/bin/env bash
url=""
args=("\$@")
i=0
while [ \$i -lt \${#args[@]} ]; do
  a="\${args[\$i]}"
  case "\$a" in
    --url) i=\$((i + 1)); url="\${args[\$i]}" ;;
    http*://*) url="\$a" ;;
  esac
  i=\$((i + 1))
done
case "\$url" in
  */api/v2/login) echo '{"data":{"token":"mock-token"}}' ;;
  */api/v2/user/apps/appDefinitions) echo '{"status":100,"data":{"appDefinitions":[]}}' ;;
  *) echo "unexpected url: \$url" >&2; exit 1 ;;
esac
MOCK
chmod +x "$TMPDIR/bin/curl"

MOCK_CAPROVER_MODE=absent MOCK_GHCR_MODE=non_json MOCK_MARKER_MODE=none \
  assert_hard_failure "GHCR non-JSON body is a hard failure, never read as 'no tag history'" "not valid JSON"

MOCK_CAPROVER_MODE=absent MOCK_GHCR_MODE=empty MOCK_MARKER_MODE=none \
  assert_hard_failure "GHCR empty body is a hard failure, never read as 'no tag history'" "response was empty"

MOCK_CAPROVER_MODE=absent MOCK_GHCR_MODE=404_permission_denied MOCK_MARKER_MODE=none \
  assert_hard_failure "GHCR 404 WITHOUT the specific 'Package not found' message (e.g. a private/inaccessible package) is a hard failure, never read as absence" "query failed unexpectedly"

echo ""
echo "== check-first-deploy-proof.sh: GHCR 404 positive-visibility probe (aos#193 review finding #2, round 2) =="

MOCK_CAPROVER_MODE=absent MOCK_GHCR_MODE=404_genuine MOCK_VISIBILITY_MODE=empty MOCK_MARKER_MODE=none \
  assert_hard_failure "a 404 'Package not found' WITH an empty org-packages visibility probe is INDETERMINATE, never read as absence" "could not positively confirm this token can see ANY container package"

MOCK_CAPROVER_MODE=absent MOCK_GHCR_MODE=404_genuine MOCK_VISIBILITY_MODE=fails MOCK_MARKER_MODE=none \
  assert_hard_failure "a 404 'Package not found' WITH a failing org-packages visibility probe is INDETERMINATE, never read as absence" "could not positively confirm this token can see ANY container package"

echo ""
echo "== deploy-app.yml wiring: --image-name must be resolve-stage's real image_name, not a derived app_name string (aos#193 review finding #3) =="

# aos#193 review finding #3's real repro: deploy-app.yml used to pass
# "--image-name img-${{ inputs.app_name }}" -- a DERIVED string that is
# wrong for any app whose real GHCR package name differs from app_name
# (e.g. mcp's real image is img-qwickapps-mcp-prod, not
# img-qwickapps-mcp), silently making check 2 always read "no history".
# resolve-stage already computes and outputs the real image_name; this
# guards that the "Check first-deploy proof" step actually threads THAT
# output through, by name, and never falls back to reconstructing a name
# from inputs.app_name.
WORKFLOW="$SCRIPTS_DIR/../.github/workflows/deploy-app.yml"
FIRST_DEPLOY_PROOF_STEP="$(python3 -c "
import yaml
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
for step in doc['jobs']['deploy-caprover']['steps']:
    if step.get('id') == 'first-deploy-proof':
        print(step.get('run', ''))
        break
")"

FIRST_DEPLOY_PROOF_STEP_IF="$(python3 -c "
import yaml
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
for step in doc['jobs']['deploy-caprover']['steps']:
    if step.get('id') == 'first-deploy-proof':
        print(step.get('if', ''))
        break
")"

assert_yaml() {
  local desc="$1" expr="$2"
  if eval "$expr"; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc"
    fail=$((fail + 1))
  fi
}

assert_yaml "sanity: found the first-deploy-proof step's run script" \
  '[ -n "$FIRST_DEPLOY_PROOF_STEP" ]'

assert_yaml "--image-name is threaded from needs.resolve-stage.outputs.image_name" \
  'printf "%s" "$FIRST_DEPLOY_PROOF_STEP" | grep -q "resolve-stage.outputs.image_name"'

assert_yaml "--image-name is never reconstructed as a derived img-\${app_name} string" \
  '! printf "%s" "$FIRST_DEPLOY_PROOF_STEP" | grep -qE -- "--image-name \"img-\\\$\{\{ inputs\.app_name"'

# aos#193 review §5 mutation gap "P1": the first-deploy-proof step must
# remain gated on BOTH stage=='live' AND require_live_approval_check ==
# true. Dropping the require_live_approval_check conjunct (so the step,
# and the branch that skips the unconditional stable-health check, would
# run unconditionally on every live deploy again) must fail this
# assertion -- it is checked against the step's actual `if:` condition
# text, not just its run script, so a mutation that removes the conjunct
# cannot pass by coincidence.
assert_yaml "first-deploy-proof step's if: requires require_live_approval_check == true (aos#193 review finding, round 2, mutation gap P1) -- not just stage == 'live' alone" \
  'printf "%s" "$FIRST_DEPLOY_PROOF_STEP_IF" | grep -qF "require_live_approval_check == true"'

assert_yaml "first-deploy-proof step's if: still requires stage == live" \
  "printf '%s' \"\$FIRST_DEPLOY_PROOF_STEP_IF\" | grep -qF \"resolve-stage.outputs.stage == 'live'\""

echo ""
echo "== check-first-deploy-proof.sh: marker binding (aos#193 review finding #5 / finding #1) =="

MOCK_MARKER_MODE=valid
MOCK_MARKER_TEXT_JSON="$(jq -nc '{repo:"qwickapps/OTHER-REPO",app_name:"demo",sha:"0123456789abcdef0123456789abcdef01234567"} | tojson')"
MOCK_CAPROVER_MODE=absent MOCK_GHCR_MODE=none \
  assert_verdict "marker payload repo mismatch -> not counted as a valid marker -> first_deploy stays true" "true"

MOCK_MARKER_MODE=valid
MOCK_MARKER_TEXT_JSON="$(jq -nc '{repo:"qwickapps/demo",app_name:"OTHER-APP",sha:"0123456789abcdef0123456789abcdef01234567"} | tojson')"
MOCK_CAPROVER_MODE=absent MOCK_GHCR_MODE=none \
  assert_verdict "marker payload app_name mismatch (a DIFFERENT app's marker on the same commit) -> not counted -> first_deploy stays true" "true"

echo ""
echo "== check-first-deploy-proof.sh: marker GitHub-Actions-API binding (aos#193 review finding #1, BLOCKER, round 2) =="

MOCK_MARKER_MODE=valid
MOCK_MARKER_TEXT_JSON="$(jq -nc --arg v "$VALID_MARKER_JSON" '$v')"
MOCK_MARKER_APP_SLUG="some-other-app"
MOCK_CAPROVER_MODE=absent MOCK_GHCR_MODE=none \
  assert_verdict "marker check run was created by an app other than github-actions -> not counted (self-reported payload alone is never trusted) -> first_deploy stays true" "true"
unset MOCK_MARKER_APP_SLUG

MOCK_MARKER_MODE=valid
MOCK_MARKER_TEXT_JSON="$(jq -nc --arg v "$VALID_MARKER_JSON" '$v')"
MOCK_MARKER_EXTERNAL_ID="not-a-run-id"
MOCK_CAPROVER_MODE=absent MOCK_GHCR_MODE=none \
  assert_verdict "marker check run has a malformed external_id -> not counted -> first_deploy stays true" "true"
unset MOCK_MARKER_EXTERNAL_ID

FORGED_RUN="$(jq -nc --arg sha "$COMMIT_SHA" --arg repo "$REPO" '{head_sha: $sha, repository: {full_name: $repo}, status: "completed", referenced_workflows: [{path: "qwickapps/some-other-repo/.github/workflows/totally-unrelated.yml@refs/heads/main"}]}')"
printf '%s' "$FORGED_RUN" > "$RUN_RESPONSE_FILE"
MOCK_MARKER_MODE=valid
MOCK_MARKER_TEXT_JSON="$(jq -nc --arg v "$VALID_MARKER_JSON" '$v')"
MOCK_CAPROVER_MODE=absent MOCK_GHCR_MODE=none \
  assert_verdict "the run named by the marker's external_id never referenced deploy-app.yml (forgery attempt) -> not counted -> first_deploy stays true" "true"
write_valid_run_response

MOCK_MARKER_MODE=valid
MOCK_MARKER_TEXT_JSON="$(jq -nc --arg v "$VALID_MARKER_JSON" '$v')"
MOCK_CAPROVER_MODE=absent MOCK_GHCR_MODE=none \
  assert_verdict "marker payload fully matches AND the GitHub-Actions-run binding verifies -> counted -> first_deploy=false" "false"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
