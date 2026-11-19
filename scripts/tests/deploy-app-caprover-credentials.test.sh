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

assert() {
  local desc="$1"; shift
  if "$@"; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc"
    fail=$((fail + 1))
  fi
}

echo "== ci-workflows#204: 'Resolve CapRover credentials' no longer raw-exports GHCR_PULL_TOKEN =="
# Before #204, this exact step exported secrets.GHCR_PULL_TOKEN into
# GITHUB_ENV unconditionally, regardless of whether it still worked --
# selection now happens in a separate, dedicated step (see the assertion
# below) that probes ghcr.io before exporting anything.
RAW_STEP="$(python3 -c "
import yaml
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
print(doc['jobs']['deploy-caprover']['steps'][2]['run'])
")"
assert "deploy-caprover: 'Resolve CapRover credentials' step no longer exports GHCR_PULL_TOKEN directly" \
  bash -c '! printf "%s" "$1" | grep -qF "GHCR_PULL_TOKEN="' _ "$RAW_STEP"

for job in deploy-caprover deploy-stable; do
  assert "$job: has a dedicated 'Select GHCR pull token' step (ci-workflows#204)" \
    bash -c "python3 -c \"
import yaml, sys
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
steps = doc['jobs']['$job']['steps']
sys.exit(0 if any('Select GHCR pull token' in s.get('name', '') for s in steps) else 1)
\""
done

echo ""
echo "== ci-workflows#207 review round 1: qwickway route registry-user consistency =="
# 'Route qwickway to ordered live/stable for live stage' probes GHCR with
# ghcr_probe_auth_only using one actor, then calls setup-qwickway-route.sh
# with --registry-user; if those two ever diverge (e.g. a future edit
# reverts one call site to a literal "${{ github.actor }}" while the other
# keeps a shared shell var, or --registry-user is dropped entirely), the
# credential pair CapRover validates no longer matches the pair it stores.
ROUTE_STEP="$(python3 -c "
import sys, yaml
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
steps = doc['jobs']['deploy-caprover']['steps']
match = [s for s in steps if s.get('name') == 'Route qwickway to ordered live/stable for live stage']
if not match:
    print('FAIL: step not found', file=sys.stderr)
    sys.exit(1)
print(match[0]['run'])
")"

assert "route step passes --registry-user to setup-qwickway-route.sh" \
  bash -c 'printf "%s" "$1" | grep -qF -- "--registry-user "' _ "$ROUTE_STEP"

assert "route step's ghcr_probe_auth_only and --registry-user use the SAME shell variable (not two independent \${{ github.actor }} refs)" \
  bash -c '
    step="$1"
    probe_arg="$(printf "%s" "$step" | grep -oE "ghcr_probe_auth_only \"[^\"]+\"" | sed -E "s/ghcr_probe_auth_only \"([^\"]+)\"/\1/")"
    flag_arg="$(printf "%s" "$step" | grep -oE -- "--registry-user \"[^\"]+\"" | sed -E "s/--registry-user \"([^\"]+)\"/\1/")"
    [ -n "$probe_arg" ] && [ -n "$flag_arg" ] && [ "$probe_arg" = "$flag_arg" ]
  ' _ "$ROUTE_STEP"

echo ""
echo "== route_gateway: non-routing live deployments retain health but skip gateway mutation =="
ROUTE_GATEWAY_CONTRACT="$(python3 -c "
import yaml
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
inputs = doc[True]['workflow_call']['inputs']
if inputs.get('route_gateway', {}).get('type') != 'boolean' or inputs['route_gateway'].get('default') is not True:
    raise SystemExit(1)
steps = doc['jobs']['deploy-caprover']['steps']
for name in ['Route qwickway to ordered live/stable for live stage', 'Verify LB target resolves to the node just deployed (infra#101 guard)']:
    step = next((s for s in steps if s.get('name') == name), None)
    if not step or step.get('if') != \"needs.resolve-stage.outputs.stage == 'live' && inputs.route_gateway == true\":
        raise SystemExit(1)
print('ok')
")"
assert "route_gateway is boolean default true and gates only live qwickway mutation plus post-route verification" \
  test "$ROUTE_GATEWAY_CONTRACT" = "ok"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
