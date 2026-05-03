#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/blue-green-workflow-guard.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_pass() {
  local name="$1"
  shift
  if "$@" >/tmp/blue-green-guard.out 2>&1; then
    echo "ok - $name"
  else
    cat /tmp/blue-green-guard.out
    echo "not ok - $name"
    exit 1
  fi
}

assert_fail() {
  local name="$1"
  shift
  if "$@" >/tmp/blue-green-guard.out 2>&1; then
    cat /tmp/blue-green-guard.out
    echo "not ok - $name"
    exit 1
  else
    echo "ok - $name"
  fi
}

cd "$TMPDIR"
mkdir -p .github/workflows docs

cat > .github/workflows/deploy.yml <<'YAML'
name: Deploy
on:
  workflow_dispatch:
jobs:
  deploy:
    uses: qwickapps/ci-workflows/.github/workflows/deploy-app.yml@main
YAML
assert_pass "allows canonical reusable deploy caller" "$SCRIPT" .github/workflows/deploy.yml

cat > .github/workflows/deploy.yml <<'YAML'
name: Deploy
# blue-green-exempt: legacy platform pipeline tracked in issue #123
on:
  workflow_dispatch:
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: echo direct deploy
YAML
assert_pass "allows explicit exemption with reason" "$SCRIPT" .github/workflows/deploy.yml

cat > .github/workflows/deploy.yml <<'YAML'
name: Deploy
on:
  push:
    branches: [live]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: echo direct push to live
YAML
assert_fail "rejects vendored direct deploy workflow" "$SCRIPT" .github/workflows/deploy.yml

cat > docs/deploy.yml <<'YAML'
not: a workflow
YAML
assert_pass "ignores deploy files outside workflow directory" "$SCRIPT" docs/deploy.yml
