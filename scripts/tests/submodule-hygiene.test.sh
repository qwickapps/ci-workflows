#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0

assert_contains() {
  local file="$1"
  local expected="$2"

  if grep -Fq "$expected" "$ROOT_DIR/$file"; then
    echo "  PASS: $file contains '$expected'"
  else
    echo "  FAIL: $file missing '$expected'"
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"

  if grep -Fq "$unexpected" "$ROOT_DIR/$file"; then
    echo "  FAIL: $file still contains '$unexpected'"
    fail=$((fail + 1))
  else
    echo "  PASS: $file does not contain '$unexpected'"
  fi
}

echo "== ci-workflows submodule hygiene =="
for file in \
  ".github/workflows/main-push-guard.yml" \
  "workflows/main-push-guard.yml" \
  "workflows/pr-validate.yml"
do
  assert_contains "$file" 'git -C "$submodule_path" checkout -- .'
  assert_contains "$file" "git submodule update --init"
  assert_not_contains "$file" "submodules: true"
done

echo ""
echo "Tests: $((9 - fail)) passed, $fail failed"
[[ "$fail" -eq 0 ]]
