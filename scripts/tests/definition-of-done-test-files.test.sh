#!/usr/bin/env bash
# scripts/tests/definition-of-done-test-files.test.sh
#
# Regression tests for ci-workflows#147: "Check 2 — test files in diff" in
# .github/workflows/definition-of-done.yml could never pass for a PR whose
# diff is only lockfiles. The step's real `run:` script is extracted from
# the workflow (not a copy) and executed against throwaway git repos.
#
#   T1 — lockfile-only diff (package-lock.json + pnpm-lock.yaml)   → pass
#   T2 — nested lockfiles across ecosystems (monorepo)             → pass
#   T3 — lockfile + source file, no test                           → fail
#   T4 — manifest (package.json) + lockfile                        → fail
#   T5 — source + test file                                        → pass (test-file path)
#   T6 — look-alike name (my-package-lock.json)                    → fail
#   T7 — empty diff                                                → fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/definition-of-done.yml"

PASS=0
FAIL=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STEP_SCRIPT="$TMP/step.sh"
python3 - "$WORKFLOW" "$STEP_SCRIPT" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
for job in wf["jobs"].values():
    for step in job.get("steps", []):
        if step.get("id") == "test_check":
            open(sys.argv[2], "w").write(step["run"])
            sys.exit(0)
sys.exit("test_check step not found in workflow")
PY

# run_case NAME EXPECTED_STATUS FILE...
# Builds a repo with a base commit, then a head commit touching FILE...,
# runs the step script and checks the status output.
run_case() {
  local name="$1" expected="$2"
  shift 2
  local repo="$TMP/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name t
  echo base > "$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
  local base_sha
  base_sha="$(git -C "$repo" rev-parse HEAD)"
  local f
  for f in "$@"; do
    mkdir -p "$repo/$(dirname "$f")"
    echo change >> "$repo/$f"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -qm head --allow-empty

  sed "s|\${{ github.event.pull_request.base.sha }}|$base_sha|" "$STEP_SCRIPT" > "$repo.step.sh"
  local out="$repo.out"
  : > "$out"
  (cd "$repo" && GITHUB_OUTPUT="$out" bash "$repo.step.sh" >/dev/null 2>&1) || true

  local status detail
  status="$(sed -n 's/^status=//p' "$out")"
  detail="$(sed -n 's/^detail=//p' "$out")"
  if [ "$status" = "$expected" ]; then
    echo "  PASS: $name (status=$status: $detail)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expected status=$expected, got '$status': $detail)"
    FAIL=$((FAIL + 1))
  fi
}

echo "== definition-of-done Check 2 — lockfile-only exemption (ci-workflows#147) =="

run_case t1-lockfile-only        pass package-lock.json pnpm-lock.yaml
run_case t2-nested-lockfiles     pass apps/web/yarn.lock svc/go.sum crates/x/Cargo.lock py/poetry.lock py/Pipfile.lock php/composer.lock rb/Gemfile.lock npm-shrinkwrap.json
run_case t3-lockfile-plus-source fail package-lock.json src/index.ts
run_case t4-manifest-plus-lock   fail package.json package-lock.json
run_case t5-source-plus-test     pass src/index.ts src/index.test.ts
run_case t6-lookalike-name       fail my-package-lock.json
run_case t7-empty-diff           fail

# The exemption detail must be the lockfile one, not a test-file match.
if grep -q '^detail=Lockfile-only diff' "$TMP/t1-lockfile-only.out"; then
  echo "  PASS: t1 detail names the lockfile-only exemption"
  PASS=$((PASS + 1))
else
  echo "  FAIL: t1 detail does not name the lockfile-only exemption"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
