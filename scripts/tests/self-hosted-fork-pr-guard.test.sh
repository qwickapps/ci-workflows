#!/usr/bin/env bash
#
# Regression gate for ci-workflows#184 / ci-workflows#185 round 2 review:
# self-hosted jobs in workflows triggered by fork-controllable events must
# carry the canonical fork-PR guard.
#
# IMPORTANT (per the #185 review): this scanner, like the guard it checks
# for, lives in a file a hostile fork PR controls (GitHub runs a
# `pull_request` workflow's own definition from the PR's merge ref). It is
# NOT a security boundary -- see ci-workflows#184's real fix (runner-group
# "Allow public repositories" off, plus required approval for external
# contributors; both need org admin). This test guards against accidental
# and non-hostile regressions only: a future PR that adds an unguarded
# self-hosted + fork-triggered job.
#
# Checks, per the #185 review's mutation table:
#   B: globs both *.yml and *.yaml
#   C/D/E: treats any runs-on that isn't a recognized GitHub-hosted label
#     (string, list, dict/group form, or an unresolvable expression) as
#     self-hosted -- fails closed rather than requiring an exact
#     "self-hosted" string match
#   F/G: requires the job's normalized `if:` to equal the canonical guard
#     exactly (or `<canonical> && (...)`), not a substring match -- a
#     wrong-polarity guard (e.g. `event_name == 'pull_request' || ...`,
#     which lets fork PRs straight through) no longer passes
#   H/I: scans every fork-controllable trigger (pull_request,
#     pull_request_review, pull_request_review_comment, issue_comment,
#     merge_group), not just pull_request
#   J: follows a local `uses: ./.github/workflows/*.yml` reusable-workflow
#     call into the callee's own jobs, inheriting the caller's trigger
#     context
#
# Also asserts no workflow anywhere uses pull_request_target.

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

echo "== self-hosted jobs in fork-controllable-trigger workflows must carry the fork-PR guard =="

RESULT_JSON="$(python3 -c "
import yaml, glob, json, sys, re, os

WORKFLOWS_DIR = '$WORKFLOWS_DIR'
ROOT_DIR = '$ROOT_DIR'

FORK_CONTROLLABLE_TRIGGERS = {
    'pull_request',
    'pull_request_review',
    'pull_request_review_comment',
    'issue_comment',
    'merge_group',
}

CANONICAL = \"github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository\"

GITHUB_HOSTED_PREFIXES = ('ubuntu-', 'windows-', 'macos-')

def normalize_expr(s):
    if not isinstance(s, str):
        return None
    return re.sub(r'\s+', ' ', s.strip())

def guard_is_canonical(job_if):
    norm = normalize_expr(job_if)
    if norm is None:
        return False
    if norm == CANONICAL:
        return True
    # allow additional caller-specific conditions ANDed on, e.g.
    # \"<canonical> && (some_other_condition)\"
    prefix = CANONICAL + ' && ('
    return norm.startswith(prefix) and norm.endswith(')')

def is_github_hosted_label(label):
    if not isinstance(label, str):
        return False
    if '\${{' in label:
        return False  # unresolvable expression -- not confirmed github-hosted
    return label.startswith(GITHUB_HOSTED_PREFIXES)

def is_self_hosted(runs_on):
    if runs_on is None:
        return False
    if isinstance(runs_on, dict):
        return True  # group/labels dict form -- always a custom runner, fail closed
    if isinstance(runs_on, str):
        return not is_github_hosted_label(runs_on)
    if isinstance(runs_on, list):
        # GitHub-hosted runners are selected by exactly one bare recognized
        # label; a list with more than one entry, or whose entry isn't a
        # recognized github-hosted label, is a custom/self-hosted selection.
        if len(runs_on) != 1:
            return True
        return not is_github_hosted_label(runs_on[0])
    return True  # unrecognized shape -- fail closed

def get_triggers(doc):
    on = doc.get(True, doc.get('on', {}))
    if on is None:
        on = {}
    if isinstance(on, str):
        return [on]
    if isinstance(on, list):
        return list(on)
    if isinstance(on, dict):
        return list(on.keys())
    return []

def load_workflow(path):
    with open(path) as f:
        try:
            return yaml.safe_load(f)
        except Exception as e:
            print(f'PARSE ERROR {path}: {e}', file=sys.stderr)
            sys.exit(1)

findings = []       # jobs missing the guard entirely, or with a non-canonical/wrong-polarity guard
pr_target_files = []  # any pull_request_target usage anywhere -- must be none

all_paths = sorted(set(glob.glob(f'{WORKFLOWS_DIR}/*.yml') + glob.glob(f'{WORKFLOWS_DIR}/*.yaml')))
docs_by_path = {}
for path in all_paths:
    doc = load_workflow(path)
    if not doc:
        continue
    docs_by_path[path] = doc
    if 'pull_request_target' in get_triggers(doc):
        pr_target_files.append(path)

def check_job(file_label, job_id, job, fork_triggered, visited_callees):
    if not isinstance(job, dict):
        return
    runs_on = job.get('runs-on')
    if runs_on is not None:
        if fork_triggered and is_self_hosted(runs_on):
            job_if = job.get('if')
            if not job_if or not isinstance(job_if, str):
                findings.append({'file': file_label, 'job': job_id, 'problems': ['no if: guard at all']})
            elif not guard_is_canonical(job_if):
                findings.append({'file': file_label, 'job': job_id, 'problems': [
                    f'if: present but is not the canonical guard (or <canonical> && (...)): {job_if!r}'
                ]})
        return

    # No runs-on on this job -- it may be a local reusable-workflow call
    # (\`uses: ./.github/workflows/callee.yml\`). Follow it into the callee's
    # jobs, inheriting this caller's fork-triggered context (mutation J).
    uses = job.get('uses')
    if isinstance(uses, str) and uses.startswith('./'):
        callee_rel = uses.split('@')[0]  # strip an optional @ref
        # Local reusable-workflow references (uses: ./...) are relative to
        # the REPOSITORY ROOT, not the calling workflow file's directory.
        callee_path = os.path.normpath(os.path.join(ROOT_DIR, callee_rel))
        if callee_path in visited_callees:
            return  # avoid infinite recursion on a cycle
        visited_callees = visited_callees | {callee_path}
        callee_doc = docs_by_path.get(callee_path)
        if callee_doc is None and os.path.isfile(callee_path):
            callee_doc = load_workflow(callee_path)
        if callee_doc:
            for callee_job_id, callee_job in callee_doc.get('jobs', {}).items():
                check_job(f'{file_label} -> {callee_path}', callee_job_id, callee_job, fork_triggered, visited_callees)

for path, doc in docs_by_path.items():
    if 'jobs' not in doc:
        continue
    triggers = set(get_triggers(doc))
    fork_triggered = bool(triggers & FORK_CONTROLLABLE_TRIGGERS)
    if not fork_triggered:
        continue
    for job_id, job in doc.get('jobs', {}).items():
        check_job(path, job_id, job, fork_triggered, frozenset({path}))

print(json.dumps({'findings': findings, 'pr_target_files': pr_target_files}))
")"

FINDING_COUNT="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])['findings']))" "$RESULT_JSON")"
PR_TARGET_COUNT="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])['pr_target_files']))" "$RESULT_JSON")"

assert "no self-hosted job in a fork-controllable-trigger workflow is missing/mismatching the canonical fork-PR guard" \
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
