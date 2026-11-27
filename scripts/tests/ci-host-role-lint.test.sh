#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINTER="$ROOT_DIR/scripts/ci-host-role-lint.py"
BASE_POLICY="$ROOT_DIR/config/ci-host-role-policy.json"
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

make_repo() {
  local name="$1"
  mkdir -p "$TMPDIR/$name/.github/workflows"
  cp "$BASE_POLICY" "$TMPDIR/$name/policy.json"
}
write_workflow() {
  local repo="$1" path="$2" content="$3"
  mkdir -p "$(dirname "$TMPDIR/$repo/.github/workflows/$path")"
  printf '%s\n' "$content" > "$TMPDIR/$repo/.github/workflows/$path"
}
allow_exact() {
  local repo="$1" key="$2" path="$3" job="$4"
  python3 - "$TMPDIR/$repo/policy.json" "$key" "$path" "$job" <<'PY'
import json, sys
path, key, workflow, job = sys.argv[1:]
data = json.load(open(path))
data[key].append({"path": workflow, "jobs": [job]})
json.dump(data, open(path, "w"))
PY
}
lint_repo() {
  local repo="$1"
  python3 "$LINTER" --policy "$TMPDIR/$repo/policy.json" --workflow-dir "$TMPDIR/$repo/.github/workflows"
}

make_repo direct-choco
write_workflow direct-choco direct.yml $'name: direct\non: [push]\njobs:\n  lint:\n    runs-on: [self-hosted, choco]\n    steps:\n      - run: true'

make_repo array-choco
write_workflow array-choco array.yml $'name: array\non: [push]\njobs:\n  lint:\n    runs-on:\n      - self-hosted\n      - choco\n    steps:\n      - run: true'

make_repo alias-choco
write_workflow alias-choco alias.yml $'name: alias\non: [push]\nx-runner: &choco_runner [self-hosted, choco]\njobs:\n  lint:\n    runs-on: *choco_runner\n    steps:\n      - run: true'

make_repo dynamic-runner
write_workflow dynamic-runner dynamic.yml $'name: dynamic\non: [push]\njobs:\n  lint:\n    runs-on: [self-hosted, "${{ inputs.runner }}"]\n    steps:\n      - run: true'

make_repo reusable-call
write_workflow reusable-call caller.yml $'name: caller\non: [push]\njobs:\n  invoke:\n    uses: ./.github/workflows/hidden.yml'
write_workflow reusable-call hidden.yml $'name: hidden\non:\n  workflow_call:\njobs:\n  hidden:\n    runs-on: [self-hosted, choco]\n    steps:\n      - run: true'

make_repo hermes-allowed
write_workflow hermes-allowed hermes-platform.yml $'name: hermes platform\non: [push]\njobs:\n  agent-platform:\n    runs-on: [self-hosted, choco]\n    steps:\n      - run: true'
allow_exact hermes-allowed choco_allowlist .github/workflows/hermes-platform.yml agent-platform

make_repo julie
write_workflow julie ci.yml $'name: julie\non: [push]\njobs:\n  test:\n    runs-on: [interserver-x64, julie]\n    steps:\n      - run: true'

make_repo generic-linux
write_workflow generic-linux ci.yml $'name: generic linux\non: [push]\njobs:\n  test:\n    runs-on: [self-hosted, Linux]\n    steps:\n      - run: true'

make_repo macmini-default-deny
write_workflow macmini-default-deny apple.yml $'name: apple\non: [push]\njobs:\n  build-apple:\n    runs-on: [self-hosted, macmini, macmini-fast]\n    steps:\n      - run: true'

make_repo macmini-allowed
write_workflow macmini-allowed apple.yml $'name: apple\non: [push]\njobs:\n  build-apple:\n    runs-on: [self-hosted, macmini, macmini-fast]\n    steps:\n      - run: true'
allow_exact macmini-allowed macmini_allowlist .github/workflows/apple.yml build-apple

echo "== CI host-role lint fixtures =="
expect_fail "direct non-Hermes choco runner is denied" lint_repo direct-choco
expect_fail "array-form choco runner is denied" lint_repo array-choco
expect_fail "YAML alias resolving to choco is denied" lint_repo alias-choco
expect_fail "dynamic runs-on expressions are denied fail-closed" lint_repo dynamic-runner
expect_fail "reusable local workflow cannot hide a choco runner" lint_repo reusable-call
expect_pass "reviewed exact-path Hermes workflow may use choco" lint_repo hermes-allowed
expect_pass "Julie x64 labels are accepted for non-Mac CI" lint_repo julie
expect_fail "generic self-hosted Linux labels cannot bypass Julie" lint_repo generic-linux
expect_fail "macmini is denied outside an exact Apple-build allowlist" lint_repo macmini-default-deny
expect_pass "reviewed exact-path Apple build may use macmini" lint_repo macmini-allowed

echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
