#!/usr/bin/env bash
#
# Regression gate for ci-workflows#184: this repo is PUBLIC. Any job that
# (a) runs in a workflow triggered by pull_request and (b) runs on the
# fleet's self-hosted macmini runner would, without a guard, execute a
# fork PR's own workflow-file changes and step scripts directly on that
# host -- untrusted code with access to the runner and whatever it can
# reach from there.
#
# Every such job must carry a job-level `if:` that:
#   1. is a no-op for non-pull_request events (push, workflow_dispatch,
#      etc. must be unaffected) -- checked for the `event_name` guard
#      clause, since github.event.pull_request is only populated for
#      pull_request events and a bare comparison against it would
#      silently skip the job on every other trigger too.
#   2. actually compares the PR head repo against the base repo
#      (`pull_request.head.repo.full_name == github.repository`), which
#      is false for a fork PR and true for a same-repo PR.
#
# Also asserts no workflow anywhere uses `pull_request_target` (a trigger
# that runs with base-repo secrets/permissions against a fork's code --
# categorically worse than the plain pull_request gap this guards).
#
# This test scans every workflow file, not just the ones fixed by
# ci-workflows#184, so a future new self-hosted + pull_request workflow
# that omits the guard fails this test instead of silently reintroducing
# the same fork-code-execution gap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
WORKFLOWS_DIR="$ROOT_DIR/.github/workflows"

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

echo "== self-hosted jobs in pull_request-triggered workflows must carry the fork-PR guard =="

RESULT_JSON="$(python3 -c "
import yaml, glob, json, sys

findings = []       # jobs missing the guard entirely, or missing the safety pieces
pr_target_files = []  # any pull_request_target usage anywhere -- must be none

for path in sorted(glob.glob('$WORKFLOWS_DIR/*.yml')):
    with open(path) as f:
        try:
            doc = yaml.safe_load(f)
        except Exception as e:
            print(f'PARSE ERROR {path}: {e}', file=sys.stderr)
            sys.exit(1)
    if not doc or 'jobs' not in doc:
        continue

    on = doc.get(True, doc.get('on', {}))
    if on is None:
        on = {}
    if isinstance(on, str):
        triggers = [on]
    elif isinstance(on, list):
        triggers = on
    elif isinstance(on, dict):
        triggers = list(on.keys())
    else:
        triggers = []

    if 'pull_request_target' in triggers:
        pr_target_files.append(path)

    if 'pull_request' not in triggers:
        continue

    for job_id, job in doc.get('jobs', {}).items():
        if not isinstance(job, dict):
            continue
        runs_on = job.get('runs-on')
        is_self_hosted = (
            (isinstance(runs_on, list) and 'self-hosted' in runs_on) or
            (isinstance(runs_on, str) and 'self-hosted' in runs_on)
        )
        if not is_self_hosted:
            continue

        job_if = job.get('if')
        problems = []
        if not job_if or not isinstance(job_if, str):
            problems.append('no if: guard at all')
        else:
            if 'pull_request.head.repo.full_name' not in job_if or 'github.repository' not in job_if:
                problems.append('if: present but does not compare pull_request.head.repo.full_name against github.repository')
            if 'event_name' not in job_if and len(triggers) > 1:
                problems.append('if: present but does not guard non-pull_request events (event_name), and this workflow has other triggers too')

        if problems:
            findings.append({'file': path, 'job': job_id, 'problems': problems})

print(json.dumps({'findings': findings, 'pr_target_files': pr_target_files}))
")"

echo "$RESULT_JSON" > /dev/null  # fail loudly above via set -e if the python step itself errored

FINDING_COUNT="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])['findings']))" "$RESULT_JSON")"
PR_TARGET_COUNT="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])['pr_target_files']))" "$RESULT_JSON")"

assert "no self-hosted job in a pull_request-triggered workflow is missing the fork-PR guard" \
  test "$FINDING_COUNT" -eq 0
if [ "$FINDING_COUNT" -ne 0 ]; then
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
for f in d['findings']:
    print(f\"    {f['file']} job={f['job']}: {'; '.join(f['problems'])}\", file=sys.stderr)
" "$RESULT_JSON"
fi

assert "no workflow uses pull_request_target anywhere in the repo" \
  test "$PR_TARGET_COUNT" -eq 0
if [ "$PR_TARGET_COUNT" -ne 0 ]; then
  python3 -c "
import json, sys
d = json.loads(sys.argv[1])
for f in d['pr_target_files']:
    print(f'    {f}', file=sys.stderr)
" "$RESULT_JSON"
fi

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
