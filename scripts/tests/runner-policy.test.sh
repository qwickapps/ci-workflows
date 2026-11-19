#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POLICY="$ROOT_DIR/.github/runner-policy.json"
CHECKER="$ROOT_DIR/scripts/runner-policy.py"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0
expect_pass() {
  local description="$1"; shift
  if "$@"; then
    echo "  PASS: $description"
    pass=$((pass + 1))
  else
    echo "  FAIL: $description" >&2
    fail=$((fail + 1))
  fi
}
expect_fail() {
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  FAIL: $description (unexpected allow)" >&2
    fail=$((fail + 1))
  else
    echo "  PASS: $description"
    pass=$((pass + 1))
  fi
}

make_workflow() {
  local directory="$1" labels="$2"
  mkdir -p "$directory"
  cat > "$directory/fixture.yml" <<EOF
name: fixture
on: [push]
jobs:
  test:
    runs-on: $labels
    steps:
      - run: true
EOF
}

make_dynamic_workflow() {
  local directory="$1"
  mkdir -p "$directory"
  cat > "$directory/fixture.yml" <<'EOF'
name: fixture
on:
  workflow_call:
    inputs:
      runs_on:
        type: string
        default: '["self-hosted", "choco"]'
jobs:
  test:
    runs-on: ${{ fromJson(inputs.runs_on) }}
    steps:
      - run: true
EOF
}

make_workflow "$TMPDIR/old-unknown" '[self-hosted, unknown-host]'
make_workflow "$TMPDIR/old-bare" 'self-hosted'
make_workflow "$TMPDIR/old-hosted-private" 'ubuntu-24.04'
make_workflow "$TMPDIR/old-hosted-unapproved" 'ubuntu-unapproved'
make_dynamic_workflow "$TMPDIR/old-caller-override"
make_workflow "$TMPDIR/new-approved" '[self-hosted, choco]'
make_workflow "$TMPDIR/new-hosted-approved" 'ubuntu-24.04'

python3 - "$POLICY" "$TMPDIR/private-policy.json" <<'PY'
import json, sys
policy = json.load(open(sys.argv[1]))
policy['repositories']['qwickapps/private-fixture'] = {
  'visibility': 'private',
  'job_classes': policy['repositories']['*']['job_classes'],
}
json.dump(policy, open(sys.argv[2], 'w'))
PY

echo "== runner policy fixtures =="
expect_fail "old fixture with unknown label is rejected" \
  python3 "$CHECKER" --policy "$POLICY" validate --repo qwickapps/ci-workflows --workflow-dir "$TMPDIR/old-unknown"
expect_fail "old fixture with bare self-hosted is rejected" \
  python3 "$CHECKER" --policy "$POLICY" validate --repo qwickapps/ci-workflows --workflow-dir "$TMPDIR/old-bare"
expect_fail "old fixture with GitHub-hosted runner in a private repo is rejected" \
  python3 "$CHECKER" --policy "$TMPDIR/private-policy.json" validate --repo qwickapps/private-fixture --workflow-dir "$TMPDIR/old-hosted-private"
expect_fail "public fixture with an unapproved GitHub-hosted label is rejected" \
  python3 "$CHECKER" --policy "$POLICY" validate --repo qwickapps/ci-workflows --workflow-dir "$TMPDIR/old-hosted-unapproved"
expect_fail "caller-controlled runs-on that could override to an unapproved label is rejected" \
  python3 "$CHECKER" --policy "$POLICY" validate --repo qwickapps/ci-workflows --workflow-dir "$TMPDIR/old-caller-override"
expect_pass "new fixture with approved choco labels passes" \
  python3 "$CHECKER" --policy "$POLICY" validate --repo qwickapps/ci-workflows --workflow-dir "$TMPDIR/new-approved"
expect_pass "public fixture with an approved GitHub-hosted label passes" \
  python3 "$CHECKER" --policy "$POLICY" validate --repo qwickapps/ci-workflows --workflow-dir "$TMPDIR/new-hosted-approved"

echo "== caller-facing reusable workflows use org runners =="
# Reusable workflows execute in the caller's repository. choco runners are
# repo-scoped, so a choco label there queues forever (protocols#1769).
for wf in shell-lint.yml validation-evidence-gate.yml; do
  expect_pass "$wf requests the org macmini-fast runner" \
    grep -Eq '^    runs-on: \[self-hosted, macmini, macmini-fast\]$' "$ROOT_DIR/.github/workflows/$wf"
  expect_fail "$wf does not request a repo-scoped choco runner" \
    grep -Eq 'runs-on:.*choco' "$ROOT_DIR/.github/workflows/$wf"
done

echo "== repository workflow policy =="
expect_pass "all ci-workflows jobs use owner-approved labels" \
  python3 "$CHECKER" --policy "$POLICY" validate --repo qwickapps/ci-workflows --workflow-dir "$ROOT_DIR/.github/workflows"

echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
