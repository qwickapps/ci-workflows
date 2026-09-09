#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0

assert_tracked_executable() {
  local path="$1"
  local mode

  mode="$(git -C "$ROOT_DIR" ls-files -s "$path" | awk '{print $1}')"
  if [[ "$mode" == "100755" ]]; then
    echo "  PASS: $path is tracked executable"
  else
    echo "  FAIL: $path tracked mode is ${mode:-missing}, expected 100755"
    fail=$((fail + 1))
  fi
}

echo "== script modes =="
assert_tracked_executable "scripts/rotate-infra-ssh-key.sh"
assert_tracked_executable "scripts/sync-authorized-keys.sh"

echo ""
echo "Tests: $((2 - fail)) passed, $fail failed"
[[ "$fail" -eq 0 ]]
