#!/usr/bin/env bash
#
# Dynamic (execution-based) test for ci-workflows#153 checks 1 and 2, both
# implemented in the resolve-stage job's embedded script in deploy-app.yml:
#
#   Check 1 (stage/host agreement): a caller deploying stage=build to
#   anything but oci-dev (captain.dev.qwickforge.com), or stage=uat/live to
#   anything but oci-main (captain.app.qwickforge.com), is refused.
#
#   Check 2 (no per-environment build slots): a computed CapRover app name
#   matching -(uat|live|stable)-build$ is refused outright.
#
# Unlike this repo's other deploy-app.yml tests (which grep the YAML for
# static structure), this test EXTRACTS the resolve-stage step's actual
# `run:` script via a real YAML parse, substitutes `${{ inputs.X }}` / `${{
# env.X }}` references with shell variable expansions, and EXECUTES it under
# bash with controlled inputs -- a genuine dynamic proof that a violating
# input set fails (red) and the equivalent compliant input set succeeds
# (green), not just a check that certain strings exist in the file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/deploy-app.yml"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0

# Extract resolve-stage's run script, substitute GH Actions expressions with
# shell variable references so it can execute standalone.
extract_script() {
  python3 -c "
import yaml
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
print(doc['jobs']['resolve-stage']['steps'][0]['run'])
" | sed -E \
    -e 's/\$\{\{ env\.REGISTRY \}\}/$REGISTRY/g' \
    -e 's/\$\{\{ env\.OWNER \}\}/$OWNER/g' \
    -e 's/\$\{\{ inputs\.app_name \}\}/$IN_APP_NAME/g' \
    -e 's/\$\{\{ inputs\.caprover_host \}\}/$IN_CAPROVER_HOST/g' \
    -e 's/\$\{\{ inputs\.caprover_url \}\}/$IN_CAPROVER_URL/g' \
    -e 's/\$\{\{ inputs\.container_port \}\}/$IN_CONTAINER_PORT/g' \
    -e 's/\$\{\{ inputs\.dockerfile_only \}\}/$IN_DOCKERFILE_ONLY/g' \
    -e 's/\$\{\{ inputs\.gateway_stable_url \}\}/$IN_GATEWAY_STABLE_URL/g' \
    -e 's/\$\{\{ inputs\.health_path \}\}/$IN_HEALTH_PATH/g' \
    -e 's/\$\{\{ inputs\.image_ref \}\}/$IN_IMAGE_REF/g' \
    -e 's/\$\{\{ inputs\.package_json_path \}\}/$IN_PACKAGE_JSON_PATH/g' \
    -e 's/\$\{\{ inputs\.run_migrations \}\}/$IN_RUN_MIGRATIONS/g' \
    -e 's/\$\{\{ inputs\.stage \}\}/$IN_STAGE/g'
}

extract_script > "$TMPDIR/resolve-stage.sh"
# Sanity: no unsubstituted GH Actions expressions left.
if grep -q '\${{' "$TMPDIR/resolve-stage.sh"; then
  echo "FAIL: extraction left unsubstituted \${{ }} expressions -- test needs updating for a new input"
  grep '\${{' "$TMPDIR/resolve-stage.sh"
  exit 1
fi

# Run resolve-stage.sh with a given input set. Returns exit code; stderr+stdout
# captured to $1 (a file path passed as first positional after --).
run_resolve_stage() {
  local out_file="$1"
  (
    export REGISTRY=ghcr.io OWNER=qwickapps
    export IN_APP_NAME="${IN_APP_NAME:-}" IN_CAPROVER_HOST="${IN_CAPROVER_HOST:-}" \
           IN_CAPROVER_URL="${IN_CAPROVER_URL:-}" IN_CONTAINER_PORT="${IN_CONTAINER_PORT:-8080}" \
           IN_DOCKERFILE_ONLY="${IN_DOCKERFILE_ONLY:-true}" IN_GATEWAY_STABLE_URL="${IN_GATEWAY_STABLE_URL:-}" \
           IN_HEALTH_PATH="${IN_HEALTH_PATH:-/health}" IN_IMAGE_REF="${IN_IMAGE_REF:-}" \
           IN_PACKAGE_JSON_PATH="${IN_PACKAGE_JSON_PATH:-}" IN_RUN_MIGRATIONS="${IN_RUN_MIGRATIONS:-false}" \
           IN_STAGE="${IN_STAGE:-}"
    export GITHUB_SHA="0123456789abcdef0123456789abcdef01234567"
    export GITHUB_OUTPUT="$TMPDIR/gh-output-$$"
    : > "$GITHUB_OUTPUT"
    set +e
    bash "$TMPDIR/resolve-stage.sh"
    rc=$?
    set -e
    echo "--- GITHUB_OUTPUT ---"
    cat "$GITHUB_OUTPUT"
    exit "$rc"
  ) > "$out_file" 2>&1
}

assert_fails_with() {
  local desc="$1" needle="$2"
  local out="$TMPDIR/out-$RANDOM"
  set +e
  run_resolve_stage "$out"
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ] && grep -qF "$needle" "$out"; then
    echo "  PASS (red):  $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL (red):  $desc -- expected exit!=0 with message containing: $needle"
    echo "    actual exit=$rc, output:"
    sed 's/^/      /' "$out"
    fail=$((fail + 1))
  fi
}

assert_succeeds() {
  local desc="$1"
  local out="$TMPDIR/out-$RANDOM"
  set +e
  run_resolve_stage "$out"
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "  PASS (green): $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL (green): $desc -- expected exit=0, got $rc"
    sed 's/^/      /' "$out"
    fail=$((fail + 1))
  fi
}

echo "== Check 1: stage/host agreement =="

# RED: build stage pointed at oci-main (the faabzi-uat-build-shaped mistake,
# generalized to the build slot itself).
IN_STAGE=build IN_APP_NAME=demo IN_CAPROVER_HOST=captain.app.qwickforge.com \
  assert_fails_with "build stage targeting oci-main host is refused" \
  "stage 'build' must deploy to 'captain.dev.qwickforge.com'"

# GREEN: same app/stage, correct oci-dev host.
IN_STAGE=build IN_APP_NAME=demo IN_CAPROVER_HOST=captain.dev.qwickforge.com \
  assert_succeeds "build stage targeting oci-dev host succeeds"

# RED: uat stage pointed at oci-dev.
IN_STAGE=uat IN_APP_NAME=demo IN_CAPROVER_HOST=captain.dev.qwickforge.com \
  assert_fails_with "uat stage targeting oci-dev host is refused" \
  "stage 'uat' must deploy to 'captain.app.qwickforge.com'"

# GREEN: uat stage, correct oci-main host.
IN_STAGE=uat IN_APP_NAME=demo IN_CAPROVER_HOST=captain.app.qwickforge.com \
  assert_succeeds "uat stage targeting oci-main host succeeds"

# RED: live stage pointed at oci-dev via the caprover_url override (not just
# caprover_host) -- confirms the override path is checked too.
IN_STAGE=live IN_APP_NAME=demo IN_CAPROVER_HOST=captain.app.qwickforge.com \
  IN_CAPROVER_URL=https://captain.dev.qwickforge.com \
  assert_fails_with "live stage's caprover_url override to oci-dev is refused" \
  "stage 'live' must deploy to 'captain.app.qwickforge.com'"

# GREEN: live stage, correct oci-main host.
IN_STAGE=live IN_APP_NAME=demo IN_CAPROVER_HOST=captain.app.qwickforge.com \
  assert_succeeds "live stage targeting oci-main host succeeds"

# GREEN: stable stage is exempt from check 1 (never goes through CapRover)
# regardless of caprover_host value -- required input, but unchecked here.
IN_STAGE=stable IN_APP_NAME=demo IN_CAPROVER_HOST=captain.dev.qwickforge.com \
  IN_GATEWAY_STABLE_URL=http://demo-stable.taile324e7.ts.net:8080 \
  assert_succeeds "stable stage is exempt from the host check"

echo ""
echo "== Check 2: no per-environment build slots =="

# RED: app_name already carries an environment suffix, producing exactly the
# faabzi-uat-build shape when combined with stage=build.
IN_STAGE=build IN_APP_NAME=faabzi-uat IN_CAPROVER_HOST=captain.dev.qwickforge.com \
  assert_fails_with "app_name carrying a -uat suffix + stage=build is refused" \
  "computed CapRover app name 'faabzi-uat-build' is a per-environment build slot"

IN_STAGE=build IN_APP_NAME=faabzi-live IN_CAPROVER_HOST=captain.dev.qwickforge.com \
  assert_fails_with "app_name carrying a -live suffix + stage=build is refused" \
  "computed CapRover app name 'faabzi-live-build' is a per-environment build slot"

IN_STAGE=build IN_APP_NAME=faabzi-stable IN_CAPROVER_HOST=captain.dev.qwickforge.com \
  assert_fails_with "app_name carrying a -stable suffix + stage=build is refused" \
  "computed CapRover app name 'faabzi-stable-build' is a per-environment build slot"

# GREEN: the legal shape -- plain app_name, build stage -> <app>-build only.
IN_STAGE=build IN_APP_NAME=faabzi IN_CAPROVER_HOST=captain.dev.qwickforge.com \
  assert_succeeds "plain app_name + stage=build (the only legal build slot) succeeds"

# RED: mixed-case app_name suffix reproduces the exact faabzi-uat-build
# incident with different casing -- the check-2 glob is lowercase-only, so
# app_name="faabzi-UAT" + stage=build must still be refused. This is the
# case-sensitivity bypass found in adversarial review of ci-workflows#157.
IN_STAGE=build IN_APP_NAME=faabzi-UAT IN_CAPROVER_HOST=captain.dev.qwickforge.com \
  assert_fails_with "app_name carrying a mixed-case -UAT suffix + stage=build is refused" \
  "is a per-environment build slot"

echo ""
echo "== Check 1: case-insensitive host comparison =="

# GREEN: mixed-case resolved host must still match the canonical lowercase
# host -- DNS hostnames are case-insensitive, and the comparison must not
# reject a caller who happens to pass e.g. Captain.App.QwickForge.Com.
IN_STAGE=uat IN_APP_NAME=demo IN_CAPROVER_HOST=Captain.App.QwickForge.Com \
  assert_succeeds "mixed-case uat host still matches the canonical oci-main host"

echo ""
echo "== ci-workflows#166: stage normalized once at the input boundary =="

# GREEN: a mixed-case stage input ("BUILD") is normalized rather than
# rejected by the `case "$STAGE_INPUT" in build|uat|live|stable)` validity
# check, and still resolves to the correct oci-dev host requirement.
IN_STAGE=BUILD IN_APP_NAME=demo IN_CAPROVER_HOST=captain.dev.qwickforge.com \
  assert_succeeds "mixed-case stage 'BUILD' is normalized and succeeds against the correct oci-dev host"

# RED: normalizing stage must not create a NEW bypass of check 1 -- a
# mixed-case stage input pointed at the WRONG host is still refused, proving
# the host-agreement guard applies to the normalized value, not the raw one.
IN_STAGE=Live IN_APP_NAME=demo IN_CAPROVER_HOST=captain.dev.qwickforge.com \
  assert_fails_with "mixed-case stage 'Live' targeting the wrong (oci-dev) host is still refused" \
  "stage 'live' must deploy to 'captain.app.qwickforge.com'"

# RED: normalization must not widen the validity check itself -- a stage
# that is genuinely invalid even after lowercasing is still rejected.
IN_STAGE=Bogus IN_APP_NAME=demo IN_CAPROVER_HOST=captain.dev.qwickforge.com \
  assert_fails_with "genuinely invalid stage 'Bogus' is still rejected after normalization" \
  "invalid stage 'bogus'"

echo ""
echo "== ci-workflows#166: caprover_host_name normalized once (boundary hoist) =="

# GREEN + output check: mixed-case caprover_host still produces a lowercase
# caprover_host_name output now that the lowercasing happens once before the
# stage case block, not duplicated inside each of its four arms.
assert_output_contains() {
  local desc="$1" needle="$2"
  local out="$TMPDIR/out-$RANDOM"
  set +e
  run_resolve_stage "$out"
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -qF "$needle" "$out"; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc -- expected exit=0 and output containing: $needle"
    echo "    actual exit=$rc, output:"
    sed 's/^/      /' "$out"
    fail=$((fail + 1))
  fi
}

IN_STAGE=build IN_APP_NAME=demo IN_CAPROVER_HOST=Captain.Dev.QwickForge.Com \
  assert_output_contains "mixed-case caprover_host still yields a lowercased caprover_host_name output" \
  "caprover_host_name=captain.dev.qwickforge.com"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
