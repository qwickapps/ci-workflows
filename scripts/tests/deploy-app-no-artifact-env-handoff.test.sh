#!/usr/bin/env bash
#
# Regression test for t_ffaf9f03: deploy-app.yml must never hand off the
# rendered app env file via a GitHub Actions artifact or a /tmp fallback
# path. Secret-bearing env files must render IN the job that consumes
# them, via the env_render_script input, and a render that produces no
# file (or an empty one) must fail loudly -- no silent fallback.
#
# Guards against both problems that caused this fix:
#   1. Secrets-at-rest outside QwickSecrets (an uploaded artifact is
#      retained and downloadable by anyone with repo read access).
#   2. The org-wide GH Actions artifact-storage quota wall, which made
#      the upload step itself fail and broke every dev deploy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/deploy-app.yml"

pass=0
fail=0
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

echo "== deploy-app.yml: no artifact/tmp env-file handoff, env_render_script required =="

assert "workflow file exists" \
  test -f "$WORKFLOW"

assert "resolve-docker-endpoint.sh shipped inside ci-workflows" \
  test -x "$SCRIPTS_DIR/resolve-docker-endpoint.sh"

# -- No upload/download-artifact anywhere in the workflow body (comments
# that merely document the removed pattern are fine; this greps the raw
# step 'uses:' lines, not the whole file, to avoid false positives on the
# explanatory comment near the env_render_script input).
UPLOAD_USES="$(grep -c 'uses: actions/upload-artifact' "$WORKFLOW" || true)"
DOWNLOAD_USES="$(grep -c 'uses: actions/download-artifact' "$WORKFLOW" || true)"
assert "no actions/upload-artifact step" test "$UPLOAD_USES" -eq 0
assert "no actions/download-artifact step" test "$DOWNLOAD_USES" -eq 0

# -- No /tmp/app-env-* fallback paths left anywhere.
TMP_FALLBACK="$(grep -c '/tmp/app-env-' "$WORKFLOW" || true)"
assert "no /tmp/app-env- fallback path" test "$TMP_FALLBACK" -eq 0

# -- No lingering caller-side resolve-docker-endpoint.sh call (excludes
# comment lines, which legitimately document the removed pattern by name).
CALLER_DOCKER_SCRIPT="$(grep -v '^\s*#' "$WORKFLOW" | grep -c '\.github/scripts/resolve-docker-endpoint\.sh' || true)"
assert "no caller-repo .github/scripts/resolve-docker-endpoint.sh call outside comments" test "$CALLER_DOCKER_SCRIPT" -eq 0

INFO_JSON="$(python3 -c "
import yaml, json
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
inputs = doc[True]['workflow_call']['inputs']
jobs = doc['jobs']

out = {}
out['env_render_script_present'] = 'env_render_script' in inputs
out['env_render_script_required'] = inputs.get('env_render_script', {}).get('required')
out['env_render_script_type'] = inputs.get('env_render_script', {}).get('type')

def job_steps(name):
    return jobs.get(name, {}).get('steps', [])

for job in ('validate-env', 'deploy-caprover', 'deploy-stable'):
    steps = job_steps(job)
    names = [s.get('name', '') for s in steps]
    out[f'{job}_has_render_step'] = any('Render app env file' in n for n in names)
    out[f'{job}_has_checkout'] = any(
        s.get('uses', '').startswith('actions/checkout@') and 'repository' not in s.get('with', {})
        for s in steps
    )
    # The render step's run body must reference env_render_script and
    # must NOT contain any artifact/tmp fallback.
    render_step = next((s for s in steps if 'Render app env file' in s.get('name', '')), None)
    out[f'{job}_render_uses_input'] = bool(render_step) and 'inputs.env_render_script' in render_step.get('run', '')

build_steps = job_steps('build')
build_names = [s.get('name', '') for s in build_steps]
out['build_has_ci_workflows_checkout'] = any('Checkout ci-workflows scripts' in n for n in build_names)
docker_step = next((s for s in build_steps if s.get('name') == 'Ensure Docker endpoint'), None)
out['build_docker_step_uses_ci_workflows'] = bool(docker_step) and '.ci-workflows/scripts/resolve-docker-endpoint.sh' in docker_step.get('run', '')

print(json.dumps(out))
")"

get_field() {
  python3 -c "import json,sys; print(json.loads('''$INFO_JSON''').get('$1'))"
}

assert "env_render_script input is present" test "$(get_field env_render_script_present)" = "True"
assert "env_render_script input is required" test "$(get_field env_render_script_required)" = "True"
assert "env_render_script input is type string" test "$(get_field env_render_script_type)" = "string"

for job in validate-env deploy-caprover deploy-stable; do
  assert "$job has an in-job 'Render app env file' step" \
    test "$(get_field "${job}_has_render_step")" = "True"
  assert "$job checks out the caller repo (plain actions/checkout, no repository: override)" \
    test "$(get_field "${job}_has_checkout")" = "True"
  assert "$job's render step actually invokes inputs.env_render_script" \
    test "$(get_field "${job}_render_uses_input")" = "True"
done

assert "build job checks out ci-workflows scripts (for resolve-docker-endpoint.sh)" \
  test "$(get_field build_has_ci_workflows_checkout)" = "True"
assert "build job's 'Ensure Docker endpoint' step calls the ci-workflows copy" \
  test "$(get_field build_docker_step_uses_ci_workflows)" = "True"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
