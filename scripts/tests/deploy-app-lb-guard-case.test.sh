#!/usr/bin/env bash
#
# Dynamic (execution-based) test for ci-workflows#163: deploy-app.yml's
# "Verify LB target resolves to the node just deployed (infra#101 guard)"
# step (present in both deploy-caprover and deploy-stable) must not fail
# OPEN (silently skip the safety check entirely) for a legitimately-cased
# Tailscale hostname -- the gate `if [[ "$RAW_URL" != *.ts.net* ]]` compared
# case-sensitively, so "https://myapp.mytailnet.TS.NET" incorrectly matched
# "not a Tailscale hostname" and skipped the check outright, not merely
# picking a wrong-but-valid value the way #161/#162's bug did.
#
# Extracts just the RAW_URL_LOWER assignment + gate `if` from each job's
# step (a real YAML parse), not the full step -- the rest of the step makes
# real network/secrets calls this sandbox can't and shouldn't exercise; the
# gate decision (skip vs. proceed) is the only thing #163 is about.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/deploy-app.yml"

pass=0
fail=0

# extract_gate2 JOB STEP_INDEX OUTPUT_REF -- pulls the run script for that
# step (a real YAML parse), substitutes the one output reference it needs,
# and truncates at the gate's own closing "fi" (its own `if` block's first
# match) -- everything after that point makes real network/secrets calls
# this test doesn't need or want to exercise.
extract_gate2() {
  local job="$1" idx="$2" output_ref="$3"
  python3 -c "
import yaml
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
print(doc['jobs']['$job']['steps'][$idx]['run'])
" | sed -E "s/\\\$\\{\\{ needs\\.resolve-stage\\.outputs\\.$output_ref \\}\\}/\$IN_URL/g" \
  | sed -n '1,/^fi$/p'
}

run_gate() {
  local job="$1" idx="$2" output_ref="$3" url="$4"
  local out
  out="$(extract_gate2 "$job" "$idx" "$output_ref")"
  if grep -q '\${{' <<<"$out"; then
    echo "EXTRACTION_ERROR: unsubstituted \${{ }} remain" >&2
    echo "$out" >&2
    return 2
  fi
  IN_URL="$url" bash -c "$out" 2>&1
}

assert_skips() {
  local desc="$1" job="$2" idx="$3" output_ref="$4" url="$5"
  local out
  out="$(run_gate "$job" "$idx" "$output_ref" "$url")"
  if grep -qF "is not a Tailscale hostname" <<<"$out"; then
    echo "  PASS (skips, as expected): $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL (expected skip): $desc"
    echo "    output: $out"
    fail=$((fail + 1))
  fi
}

assert_proceeds() {
  local desc="$1" job="$2" idx="$3" output_ref="$4" url="$5"
  local out
  out="$(run_gate "$job" "$idx" "$output_ref" "$url")"
  if grep -qF "is not a Tailscale hostname" <<<"$out"; then
    echo "  FAIL (expected proceed past the gate, but it skipped): $desc"
    echo "    output: $out"
    fail=$((fail + 1))
  else
    echo "  PASS (proceeds past the gate, as expected): $desc"
    pass=$((pass + 1))
  fi
}

echo "== deploy-caprover job's LB guard (stable_app_url) =="

assert_proceeds "lowercase .ts.net hostname proceeds (baseline, already worked)" \
  deploy-caprover 17 stable_app_url "https://myapp.mytailnet.ts.net"

assert_proceeds "MIXED-CASE .TS.NET hostname proceeds, does not fail open (ci-workflows#163)" \
  deploy-caprover 17 stable_app_url "https://myapp.mytailnet.TS.NET"

assert_skips "a genuinely non-Tailscale URL still correctly skips" \
  deploy-caprover 17 stable_app_url "https://myapp.app.qwickforge.com"

echo ""
echo "== deploy-stable job's LB guard (target_app_url) =="

assert_proceeds "lowercase .ts.net hostname proceeds (baseline, already worked)" \
  deploy-stable 8 target_app_url "https://myapp.mytailnet.ts.net"

assert_proceeds "MIXED-CASE .TS.NET hostname proceeds, does not fail open (ci-workflows#163)" \
  deploy-stable 8 target_app_url "https://myapp.mytailnet.TS.NET"

assert_skips "a genuinely non-Tailscale URL still correctly skips" \
  deploy-stable 8 target_app_url "https://myapp.app.qwickforge.com"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
