#!/usr/bin/env bash
#
# Dynamic (execution-based) test for ci-workflows#161: deploy-app.yml's
# "Resolve CapRover credentials" step (deploy-caprover job) must select the
# dev vs. main credential case-insensitively -- DNS hostnames are
# case-insensitive, but the selection glob previously matched
# `*dev.qwickforge.com*` literally, so a mixed-case host (reaching this step
# either via a mixed-case `caprover_host_name` job output, or via
# `caprover_url` passed directly, which bypasses `caprover_host_name`
# entirely) selected the wrong secret.
#
# Same extraction-and-execute approach as
# deploy-app-stage-host-gate.test.sh: pulls the step's actual `run:` script
# via a real YAML parse, substitutes `${{ ... }}` references with shell
# variables (secrets substituted with distinguishable marker strings so the
# test can assert WHICH credential was selected without needing real
# secrets), and executes it under bash.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/deploy-app.yml"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0

extract_script() {
  python3 -c "
import yaml
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
print(doc['jobs']['deploy-caprover']['steps'][2]['run'])
" | sed -E \
    -e 's/\$\{\{ inputs\.caprover_url \}\}/$IN_CAPROVER_URL/g' \
    -e 's/\$\{\{ needs\.resolve-stage\.outputs\.caprover_host_name \}\}/$NEEDS_CAPROVER_HOST_NAME/g' \
    -e 's/\$\{\{ needs\.resolve-stage\.outputs\.stage \}\}/$NEEDS_STAGE/g' \
    -e 's/\$\{\{ secrets\.GHCR_PULL_TOKEN \}\}/$SECRET_GHCR_PULL_TOKEN/g' \
    -e 's/\$\{\{ secrets\.OCI_DEV_CAPROVER_PASSWORD \}\}/DEV_SECRET_MARKER/g' \
    -e 's/\$\{\{ secrets\.OCI_MAIN_CAPROVER_PASSWORD \}\}/MAIN_SECRET_MARKER/g'
}

extract_script > "$TMPDIR/resolve-creds.sh"
if grep -q '\${{' "$TMPDIR/resolve-creds.sh"; then
  echo "FAIL: extraction left unsubstituted \${{ }} expressions -- test needs updating for a new reference"
  grep '\${{' "$TMPDIR/resolve-creds.sh"
  exit 1
fi

# Run resolve-creds.sh with a given input set, capture the resolved
# CP_PASS/CP_URL via the same GITHUB_ENV mechanism the real step uses.
run_resolve_creds() {
  local out_file="$1"
  (
    export IN_CAPROVER_URL="${IN_CAPROVER_URL:-}" \
           NEEDS_CAPROVER_HOST_NAME="${NEEDS_CAPROVER_HOST_NAME:-}" \
           NEEDS_STAGE="${NEEDS_STAGE:-uat}" \
           SECRET_GHCR_PULL_TOKEN="dummy-token"
    export GITHUB_ENV="$TMPDIR/gh-env-$$"
    : > "$GITHUB_ENV"
    bash "$TMPDIR/resolve-creds.sh"
    cat "$GITHUB_ENV"
  ) > "$out_file" 2>&1
}

assert_selects() {
  local desc="$1" expect_marker="$2"
  local out="$TMPDIR/out-$RANDOM"
  set +e
  run_resolve_creds "$out"
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -qF "CAPROVER_PASSWORD=$expect_marker" "$out"; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc -- expected exit=0 and CAPROVER_PASSWORD=$expect_marker"
    echo "    actual exit=$rc, output:"
    sed 's/^/      /' "$out"
    fail=$((fail + 1))
  fi
}

# assert_selects_and_url: same as assert_selects, plus asserts the resolved
# CAPROVER_URL is exactly the expected well-formed value (single scheme
# prefix) -- guards against ci-workflows#166's malformed-double-scheme bug
# ("https://HTTPS://...") when caprover_url carries a mixed-case scheme.
assert_selects_and_url() {
  local desc="$1" expect_marker="$2" expect_url="$3"
  local out="$TMPDIR/out-$RANDOM"
  set +e
  run_resolve_creds "$out"
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ] && grep -qF "CAPROVER_PASSWORD=$expect_marker" "$out" && grep -qF "CAPROVER_URL=$expect_url" "$out"; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc -- expected exit=0, CAPROVER_PASSWORD=$expect_marker, CAPROVER_URL=$expect_url"
    echo "    actual exit=$rc, output:"
    sed 's/^/      /' "$out"
    fail=$((fail + 1))
  fi
}

echo "== ci-workflows#161: case-insensitive dev/main credential selection =="

# Baseline: lowercase host via caprover_host_name selects DEV correctly
# (already worked before this fix -- confirms the extraction/harness itself
# is sound before testing the actual regression case).
NEEDS_CAPROVER_HOST_NAME="captain.dev.qwickforge.com" \
  assert_selects "lowercase dev host (baseline, already worked) selects DEV" DEV_SECRET_MARKER

# RED (pre-fix)/GREEN (post-fix): mixed-case host via caprover_host_name.
NEEDS_CAPROVER_HOST_NAME="Captain.Dev.QwickForge.Com" \
  assert_selects "mixed-case dev host via caprover_host_name selects DEV, not MAIN" DEV_SECRET_MARKER

# Mixed-case host via the caprover_url override -- a DIFFERENT path that
# bypasses caprover_host_name entirely (line: `if [ -n caprover_url ]; then
# CP_URL=caprover_url`), so lowercasing only caprover_host_name would have
# left this path broken. Confirms CP_URL itself is lowercased right before
# the glob, regardless of which input produced it.
IN_CAPROVER_URL="https://Captain.Dev.QwickForge.Com" NEEDS_CAPROVER_HOST_NAME="captain.app.qwickforge.com" \
  assert_selects "mixed-case dev host via caprover_url override selects DEV, not MAIN" DEV_SECRET_MARKER

# Mixed-case main host stays MAIN (not accidentally swept into DEV by a
# too-broad fix).
NEEDS_CAPROVER_HOST_NAME="Captain.App.QwickForge.Com" \
  assert_selects "mixed-case main host still selects MAIN" MAIN_SECRET_MARKER

echo ""
echo "== ci-workflows#166: case-insensitive scheme handling on caprover_url =="

# RED (pre-fix)/GREEN (post-fix): a mixed-case SCHEME in caprover_url (as
# opposed to a mixed-case host, which #161 already covered) used to fail the
# case-sensitive `http://*|https://*` scheme-presence check and get a second
# "https://" prepended, producing a malformed double-scheme URL
# ("https://HTTPS://Captain.Dev.QwickForge.Com"). Must still select the
# correct DEV credential AND produce a single well-formed lowercase URL.
IN_CAPROVER_URL="HTTPS://Captain.Dev.QwickForge.Com" \
  assert_selects_and_url "mixed-case scheme in caprover_url selects DEV and normalizes to a single scheme" \
  DEV_SECRET_MARKER "https://captain.dev.qwickforge.com"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
