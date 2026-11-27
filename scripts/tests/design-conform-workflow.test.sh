#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/design-conform.yml"
TOOL="$ROOT_DIR/scripts/design-conform/design_conform.py"

pass=0
fail=0
expect_match() {
  local description="$1" pattern="$2" file="$3"
  if grep -Eq "$pattern" "$file"; then
    echo "  PASS: $description"
    pass=$((pass + 1))
  else
    echo "  FAIL: $description" >&2
    fail=$((fail + 1))
  fi
}
expect_no_match() {
  local description="$1" pattern="$2" file="$3"
  if grep -Eq "$pattern" "$file"; then
    echo "  FAIL: $description" >&2
    fail=$((fail + 1))
  else
    echo "  PASS: $description"
    pass=$((pass + 1))
  fi
}

echo "== design-conform reusable workflow contract =="
expect_match "workflow is callable" '^  workflow_call:$' "$WORKFLOW"
expect_match "workflow uses the approved Julie pool" '^    runs-on: \[interserver-x64, julie\]$' "$WORKFLOW"
expect_match "reusable job carries the canonical caller-context fork-PR guard" "^    if: github\.event_name != 'pull_request' \|\| github\.event\.pull_request\.head\.repo\.full_name == github\.repository$" "$WORKFLOW"
if python3 - "$WORKFLOW" <<'PY'
import sys, yaml
canonical = "github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
bad = [j for j, spec in jobs.items() if " ".join(str(spec.get("if", "")).split()) != canonical]
sys.exit(1 if bad else 0)
PY
then
  echo "  PASS: every reusable-workflow job is fork-PR guarded (parsed YAML)"
  pass=$((pass + 1))
else
  echo "  FAIL: every reusable-workflow job is fork-PR guarded (parsed YAML)" >&2
  fail=$((fail + 1))
fi
expect_no_match "workflow never schedules on choco" 'runs-on:.*choco' "$WORKFLOW"
expect_no_match "workflow never schedules on macmini" 'runs-on:.*macmini' "$WORKFLOW"
expect_match "tool checkout is bound to reusable workflow repository" 'repository: \$\{\{ job\.workflow_repository \}\}' "$WORKFLOW"
expect_match "tool checkout is bound to reusable workflow SHA" 'ref: \$\{\{ job\.workflow_sha \}\}' "$WORKFLOW"
expect_match "evidence upload runs even on failure" '^        if: \$\{\{ always\(\) \}\}$' "$WORKFLOW"
expect_match "missing evidence fails closed" 'if-no-files-found: error' "$WORKFLOW"
expect_match "target SHA is a declared workflow output" '^      target_git_sha:$' "$WORKFLOW"
expect_match "manifest_path is a workflow_call input" '^      manifest_path:$' "$WORKFLOW"
expect_match "target_url is a workflow_call input" '^      target_url:$' "$WORKFLOW"
expect_match "tool exit status fails the job" '^          exit "\$status"$' "$WORKFLOW"
expect_no_match "third-party actions are SHA-pinned" 'uses: [^ ]+@v[0-9]' "$WORKFLOW"
expect_no_match "test workflow actions are SHA-pinned" 'uses: [^ ]+@v[0-9]' "$ROOT_DIR/.github/workflows/design-conform-tests.yml"
expect_match "test workflow installs PyYAML for runner-policy.py" "'PyYAML==[0-9.]+'" "$ROOT_DIR/.github/workflows/design-conform-tests.yml"

echo "== design-conform Python contract =="
expect_match "tool has an executable entrypoint" '^if __name__ == "__main__":$' "$TOOL"
expect_match "PASS and FAIL use verdict exit semantics" 'return 0 if report\["verdict"\] == "PASS" else 1' "$TOOL"
expect_match "tool errors return exit 2" 'return 2' "$TOOL"
expect_match "health metadata is required" 'health probe.*has no gitSha' "$TOOL"

python3 "$ROOT_DIR/scripts/tests/design-conform.test.py"

scripts/tests/runner-policy.test.sh

echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
