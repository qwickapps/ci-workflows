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
    with:
      caprover_host: ${{ secrets.CAPROVER_HOST }}
YAML
assert_pass "allows canonical reusable deploy caller that also references a CapRover secret" "$SCRIPT" .github/workflows/deploy.yml

cat > .github/workflows/deploy.yml <<'YAML'
name: Deploy
# blue-green-exempt: legacy platform pipeline tracked in issue #123
on:
  workflow_dispatch:
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Deploy to CapRover directly
        env:
          CAPROVER_PASSWORD: ${{ secrets.CAPROVER_PASSWORD }}
        run: echo direct deploy
YAML
assert_pass "allows explicit exemption with reason on a workflow that DOES reference a CapRover secret" "$SCRIPT" .github/workflows/deploy.yml

cat > .github/workflows/deploy.yml <<'YAML'
name: Deploy
on:
  push:
    branches: [live]
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Login to CapRover
        env:
          CAPROVER_PASSWORD: ${{ secrets.CAPROVER_PASSWORD }}
        run: echo direct push to live
YAML
assert_fail "rejects vendored direct deploy workflow (named deploy.yml, references a CapRover secret, no canonical uses:)" "$SCRIPT" .github/workflows/deploy.yml

# ci-workflows#153: the actual bug this issue reports. qwickapps/billing's
# promote-to-live.yml / promote-to-stable.yml have no "deploy" in their
# filenames at all and evaded the OLD filename-based `*deploy*.yml` check
# entirely while directly accessing secrets.OCI_*/GHCR_* CapRover
# credentials. This is that exact shape, reproduced as a regression test —
# it must be rejected even though nothing in its filename looks like a
# deploy workflow.
cat > .github/workflows/promote-to-live.yml <<'YAML'
name: Promote to Live
on:
  workflow_dispatch:
jobs:
  promote:
    runs-on: ubuntu-latest
    steps:
      - name: Login to CapRover
        env:
          CAPROVER_URL: ${{ secrets.OCI_MAIN_CAPROVER_URL }}
          CAPROVER_PASSWORD: ${{ secrets.OCI_MAIN_CAPROVER_PASSWORD }}
        run: echo "promoting directly, bypassing the shared pipeline"
YAML
assert_fail "rejects a non-deploy-named workflow that references CapRover secrets directly (the billing shape)" "$SCRIPT" .github/workflows/promote-to-live.yml

# The mirror-image case: a non-deploy-named workflow that does the RIGHT
# thing (calls the canonical reusable workflow) must still be allowed.
cat > .github/workflows/promote-to-stable.yml <<'YAML'
name: Promote to Stable
on:
  workflow_dispatch:
jobs:
  promote:
    uses: qwickapps/ci-workflows/.github/workflows/deploy-app.yml@main
    with:
      caprover_url: ${{ secrets.OCI_MAIN_CAPROVER_URL }}
YAML
assert_pass "allows a non-deploy-named workflow that correctly calls the canonical reusable workflow" "$SCRIPT" .github/workflows/promote-to-stable.yml

# A workflow that never touches CapRover at all (e.g. a lint/test workflow)
# must never be flagged, regardless of its name.
cat > .github/workflows/lint.yml <<'YAML'
name: Lint
on:
  pull_request:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: npm run lint
YAML
assert_pass "ignores workflows that never reference a CapRover secret" "$SCRIPT" .github/workflows/lint.yml

cat > docs/deploy.yml <<'YAML'
not: a workflow
CAPROVER_PASSWORD: ${{ secrets.CAPROVER_PASSWORD }}
YAML
assert_pass "ignores deploy-shaped files outside the workflow directory even if they mention a CapRover secret" "$SCRIPT" docs/deploy.yml
