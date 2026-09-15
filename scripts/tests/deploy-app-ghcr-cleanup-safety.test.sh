#!/usr/bin/env bash
#
# Regression test: the "Remove GHCR credentials" cleanup step in
# verify-provenance (ci-workflows#183) must never delete anything outside
# its own deterministic RUNNER_TEMP path, no matter what $DOCKER_CONFIG
# happens to hold when it runs.
#
# deploy-stable no longer has this step (mcp#392 / ci-workflows deploy-
# stable-caprover fix): now that it deploys via CapRover (deploy-from-
# ghcr.sh) instead of a local `docker buildx imagetools inspect` + Docker-
# config login, there's no local GHCR credential file to write or clean up
# at all.
#
# Why this matters: actions-runner-critical-macmini's own .env sets a
# persistent, ambient DOCKER_CONFIG for that runner. The credential step
# earlier in each job only overrides DOCKER_CONFIG (via a GITHUB_ENV
# export) as its LAST action, after writing the temp config file. If that
# step fails on any earlier line (mkdir, symlink, printf), the GITHUB_ENV
# export never runs -- so every later step in the job, including this
# cleanup step (which runs unconditionally via `if: always()`), would see
# whatever DOCKER_CONFIG the runner's own .env set, not the job's temp
# path. A cleanup step that trusted $DOCKER_CONFIG naively would then
# `rm -rf` the runner's real Docker config on every single job run.
#
# The fix: the cleanup step recomputes the same deterministic path
# ("$RUNNER_TEMP/ghcr-docker-config-$GITHUB_RUN_ID-$GITHUB_JOB")
# independently -- it never reads $DOCKER_CONFIG at all -- plus a `case`
# guard requiring the computed path to still be under $RUNNER_TEMP as a
# second, independent line of defense, even under a future refactor.

set -euo pipefail

TEST_SCRATCH="$(mktemp -d)"
trap 'rm -rf "$TEST_SCRATCH"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/deploy-app.yml"

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

# extract_step JOB STEP_NAME -- pulls a step's run script by exact name
# (a real YAML parse), erroring loudly on zero or more-than-one matches.
extract_step() {
  local job="$1" step_name="$2"
  python3 -c "
import sys, yaml
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
steps = doc['jobs']['$job']['steps']
matches = [s for s in steps if s.get('name') == '''$step_name''']
if not matches:
    sys.exit(f\"no step named '$step_name' in job '$job'\")
if len(matches) > 1:
    sys.exit(f\"step name '$step_name' is ambiguous in job '$job' ({len(matches)} matches)\")
print(matches[0]['run'])
"
}

CLEANUP_STEP="Remove GHCR credentials"

for JOB in verify-provenance; do
  echo "== $JOB: cleanup step safety =="

  cleanup_script="$(extract_step "$JOB" "$CLEANUP_STEP")"

  # -- Scenario 1: credential step never ran (or failed before its
  # GITHUB_ENV export) -- DOCKER_CONFIG is left at the runner's own
  # ambient/persistent value. Cleanup must not touch it.
  AMBIENT_DIR="$(mktemp -d)"
  echo '{"auths":{"ghcr.io":{"auth":"ambient-should-survive"}}}' > "$AMBIENT_DIR/config.json"
  RUNNER_TEMP_DIR="$(mktemp -d)"

  set +e
  DOCKER_CONFIG="$AMBIENT_DIR" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  GITHUB_RUN_ID="99999" \
  GITHUB_JOB="$JOB" \
    bash -c "$cleanup_script" >"$TEST_SCRATCH/cleanup_out_1.txt" 2>&1
  cleanup_exit=$?
  set -e

  assert "$JOB: cleanup step exits 0 even when the real temp dir never existed" \
    test "$cleanup_exit" -eq 0

  assert "$JOB: ambient DOCKER_CONFIG dir survives untouched (credential step never ran)" \
    test -f "$AMBIENT_DIR/config.json"

  rm -rf "$AMBIENT_DIR" "$RUNNER_TEMP_DIR"

  # -- Scenario 2: credential step succeeded -- the real temp config
  # exists at the deterministic path. Cleanup must remove it (and must
  # still leave the ambient dir alone, in case DOCKER_CONFIG is ALSO set
  # to something else for any reason).
  AMBIENT_DIR="$(mktemp -d)"
  echo '{"auths":{"ghcr.io":{"auth":"ambient-should-still-survive"}}}' > "$AMBIENT_DIR/config.json"
  RUNNER_TEMP_DIR="$(mktemp -d)"
  REAL_TARGET="$RUNNER_TEMP_DIR/ghcr-docker-config-99999-$JOB"
  mkdir -p "$REAL_TARGET"
  echo '{"auths":{"ghcr.io":{"auth":"real-should-be-deleted"}}}' > "$REAL_TARGET/config.json"

  set +e
  DOCKER_CONFIG="$AMBIENT_DIR" \
  RUNNER_TEMP="$RUNNER_TEMP_DIR" \
  GITHUB_RUN_ID="99999" \
  GITHUB_JOB="$JOB" \
    bash -c "$cleanup_script" >"$TEST_SCRATCH/cleanup_out_2.txt" 2>&1
  cleanup_exit=$?
  set -e

  assert "$JOB: cleanup step exits 0 on the real temp dir" \
    test "$cleanup_exit" -eq 0

  assert "$JOB: real temp config dir is removed" \
    test ! -e "$REAL_TARGET"

  assert "$JOB: ambient DOCKER_CONFIG dir still untouched" \
    test -f "$AMBIENT_DIR/config.json"

  rm -rf "$AMBIENT_DIR" "$RUNNER_TEMP_DIR"

  # -- Scenario 3: RUNNER_TEMP itself missing/empty -- the guard must
  # refuse to delete anything and must not touch the ambient dir.
  AMBIENT_DIR="$(mktemp -d)"
  echo '{"auths":{"ghcr.io":{"auth":"ambient-survives-missing-runner-temp"}}}' > "$AMBIENT_DIR/config.json"

  set +e
  DOCKER_CONFIG="$AMBIENT_DIR" \
  RUNNER_TEMP="" \
  GITHUB_RUN_ID="99999" \
  GITHUB_JOB="$JOB" \
    bash -c "$cleanup_script" >"$TEST_SCRATCH/cleanup_out_3.txt" 2>&1
  cleanup_exit=$?
  set -e

  assert "$JOB: cleanup step fails loudly when RUNNER_TEMP is unset/empty" \
    test "$cleanup_exit" -ne 0

  assert "$JOB: ambient DOCKER_CONFIG dir untouched when RUNNER_TEMP is unset/empty" \
    test -f "$AMBIENT_DIR/config.json"

  rm -rf "$AMBIENT_DIR"

  # -- Scenario 4: RUNNER_TEMP is itself a symlink to a real directory
  # (realistic on the actual macmini runner -- macOS's /tmp is a symlink
  # to /private/tmp). The guard's `case "$TARGET" in "$RUNNER_TEMP"/*)` is
  # a plain string-prefix match, not a filesystem resolution -- TARGET is
  # built directly from $RUNNER_TEMP, so the prefix always matches
  # regardless of whether $RUNNER_TEMP itself resolves through a symlink.
  # `rm -rf "$TARGET"` then reaches the real target the normal way any
  # shell command does: the OS transparently follows the symlink when the
  # path is actually accessed. No special resolution logic is needed or
  # present for this to work.
  REAL_TEMP_DIR="$(mktemp -d)"
  SYMLINK_TEMP_DIR="$(mktemp -u)"
  ln -s "$REAL_TEMP_DIR" "$SYMLINK_TEMP_DIR"
  REAL_TARGET="$REAL_TEMP_DIR/ghcr-docker-config-99999-$JOB"
  mkdir -p "$REAL_TARGET"
  echo '{"auths":{"ghcr.io":{"auth":"real-should-be-deleted-through-symlink"}}}' > "$REAL_TARGET/config.json"

  set +e
  RUNNER_TEMP="$SYMLINK_TEMP_DIR" \
  GITHUB_RUN_ID="99999" \
  GITHUB_JOB="$JOB" \
    bash -c "$cleanup_script" >"$TEST_SCRATCH/cleanup_out_4.txt" 2>&1
  cleanup_exit=$?
  set -e

  assert "$JOB: cleanup step exits 0 when RUNNER_TEMP is a symlink to a real dir" \
    test "$cleanup_exit" -eq 0

  assert "$JOB: real temp config dir is removed through the RUNNER_TEMP symlink" \
    test ! -e "$REAL_TARGET"

  rm -rf "$REAL_TEMP_DIR" "$SYMLINK_TEMP_DIR"

  echo ""
done

echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
