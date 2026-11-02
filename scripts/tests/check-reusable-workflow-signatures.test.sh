#!/usr/bin/env bash
#
# Regression + false-positive tests for
# scripts/check-reusable-workflow-signatures.sh (ci-workflows#175 guard).
#
# ci-workflows#175: commit 90e0adf9226dcc426750a7785feba7301285d515 rewrote
# main-push-guard.yml from a reusable workflow (on.workflow_call, inputs
# like `image_name`, secrets like `GHCR_PUSH_TOKEN`) into a plain `on.push`
# thin wrapper -- silently dropping its entire callable interface -- while
# 6 dependent repos were still calling it as a reusable workflow with the
# old inputs/secrets. Nothing compared the interface before vs after, so
# the break wasn't noticed for hours. Last-known-good commit was
# 28e9f941223e5ec54bfacd159bf3be0b86506376.
#
# Tests:
#   1. The real historical incident: comparing 28e9f941 (base) against
#      90e0adf9 (breaking commit) must FAIL, and must name
#      main-push-guard.yml and the removed workflow_call interface.
#   2. Control check: comparing the current exact commit to itself must PASS.
#   3. Synthetic unit test: a reusable workflow file that keeps
#      on.workflow_call but renames one input key (add + remove within the
#      same section, net key count unchanged) must FAIL -- proving this
#      isn't just a removal-count check.
#   4. Synthetic unit test: a reusable workflow file whose signature is
#      byte-for-byte re-formatted (key order / quoting changed) but whose
#      key SETS are identical must PASS -- proving the guard compares sets,
#      not YAML formatting or text.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
GUARD="$SCRIPTS_DIR/check-reusable-workflow-signatures.sh"

INCIDENT_BASE_SHA="28e9f941223e5ec54bfacd159bf3be0b86506376"
INCIDENT_BREAKING_SHA="90e0adf9226dcc426750a7785feba7301285d515"

indent() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    printf '    %s\n' "$line"
  done
}

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

echo "== check-reusable-workflow-signatures.sh regression tests (ci-workflows#175) =="

assert "guard script exists" \
  test -f "$GUARD"

# --- Test 1: the real historical incident must be caught -------------------
echo ""
echo "-- Test 1: real incident ($INCIDENT_BASE_SHA -> $INCIDENT_BREAKING_SHA) --"

cd "$ROOT_DIR"
if git rev-parse --verify --quiet "${INCIDENT_BASE_SHA}^{commit}" >/dev/null \
  && git rev-parse --verify --quiet "${INCIDENT_BREAKING_SHA}^{commit}" >/dev/null; then

  incident_out="$(BASE_REF="$INCIDENT_BASE_SHA" HEAD_REF="$INCIDENT_BREAKING_SHA" bash "$GUARD" 2>&1)" && incident_rc=0 || incident_rc=$?
  printf '%s\n' "$incident_out" | indent

  assert "incident: guard exits non-zero (FAILs)" \
    test "$incident_rc" -ne 0
  assert "incident: names main-push-guard.yml" \
    grep -q "main-push-guard.yml" <<<"$incident_out"
  assert "incident: reports the interface as removed" \
    grep -qi "removed" <<<"$incident_out"
  assert "incident: shows the lost inputs (image_name)" \
    grep -q "image_name" <<<"$incident_out"
  assert "incident: shows the lost secret (GHCR_PUSH_TOKEN)" \
    grep -q "GHCR_PUSH_TOKEN" <<<"$incident_out"
else
  echo "  SKIP: historical fixture commits not present in this checkout (need full history)"
fi

# --- Test 2: unchanged exact-commit control --------------------------------
# The implementation PR intentionally changes deploy-app.yml's callable
# signature, so comparing it to its base should fail without approval.  An
# exact same-commit comparison remains a useful no-false-positive control.
echo ""
echo "-- Test 2: unchanged exact-commit control --"

cd "$ROOT_DIR"
if git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  clean_out="$(BASE_REF=HEAD HEAD_REF=HEAD bash "$GUARD" 2>&1)" && clean_rc=0 || clean_rc=$?
  printf '%s\n' "$clean_out" | indent

  assert "unchanged exact commit: exits zero (PASSes)" \
    test "$clean_rc" -eq 0
else
  echo "  SKIP: HEAD not available in this checkout"
fi

# --- Test 3 & 4: synthetic fixtures in a scratch git repo -------------------
echo ""
echo "-- Test 3 & 4: synthetic fixtures (scratch repo) --"

SCRATCH_DIR="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH_DIR"; }
trap cleanup EXIT

(
  cd "$SCRATCH_DIR"
  git init -q
  git config user.email "test@example.com"
  git config user.name "test"
  mkdir -p .github/workflows

  cat > .github/workflows/fixture.yml <<'YAML'
name: Fixture
on:
  workflow_call:
    inputs:
      image_name:
        required: true
        type: string
    secrets:
      TOKEN:
        required: true
YAML
  git add -A
  git commit -q -m "base"
  git tag fixture-base

  # Test 3: rename image_name -> image_ref (same count, different keys)
  cat > .github/workflows/fixture.yml <<'YAML'
name: Fixture
on:
  workflow_call:
    inputs:
      image_ref:
        required: true
        type: string
    secrets:
      TOKEN:
        required: true
YAML
  git add -A
  git commit -q -m "rename input key"
  git tag fixture-renamed
)

rename_out="$(cd "$SCRATCH_DIR" && BASE_REF=fixture-base HEAD_REF=fixture-renamed bash "$GUARD" 2>&1)" && rename_rc=0 || rename_rc=$?
printf '%s\n' "$rename_out" | indent
assert "synthetic rename: guard exits non-zero (FAILs)" \
  test "$rename_rc" -ne 0
assert "synthetic rename: reports the old key (image_name)" \
  grep -q "image_name" <<<"$rename_out"
assert "synthetic rename: reports the new key (image_ref)" \
  grep -q "image_ref" <<<"$rename_out"

(
  cd "$SCRATCH_DIR"
  # Test 4: same keys, reformatted YAML (quoting + key order) -> must PASS
  cat > .github/workflows/fixture.yml <<'YAML'
name: Fixture
on:
  workflow_call:
    secrets:
      TOKEN:
        required: true
    inputs:
      "image_ref":
        type: string
        required: true
YAML
  git add -A
  git commit -q -m "reformat only"
  git tag fixture-reformatted
)

reformat_out="$(cd "$SCRATCH_DIR" && BASE_REF=fixture-renamed HEAD_REF=fixture-reformatted bash "$GUARD" 2>&1)" && reformat_rc=0 || reformat_rc=$?
printf '%s\n' "$reformat_out" | indent
assert "synthetic reformat-only: guard exits zero (PASSes)" \
  test "$reformat_rc" -eq 0

# --- Test 5: exact auditable PR-comment approval ---------------------------
echo ""
echo "-- Test 5: exact PR-comment approval marker --"
MOCK_BIN="$SCRATCH_DIR/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "api" ] && [[ "$2" == repos/example/repo/issues/42/comments ]]; then
  cat "$MOCK_COMMENTS"
  exit 0
fi
exit 2
SH
chmod +x "$MOCK_BIN/gh"
fixture_base_sha="$(cd "$SCRATCH_DIR" && git rev-parse fixture-base)"
fixture_head_sha="$(cd "$SCRATCH_DIR" && git rev-parse fixture-renamed)"
EVENT_JSON="$SCRATCH_DIR/event.json"
COMMENTS_JSON="$SCRATCH_DIR/comments.json"
python3 - "$EVENT_JSON" "$fixture_base_sha" "$fixture_head_sha" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump({"pull_request": {"number": 42, "base": {"sha": sys.argv[2]}, "head": {"sha": sys.argv[3]}}}, fh)
PY
printf '[]\n' > "$COMMENTS_JSON"
approval_missing_out="$(cd "$SCRATCH_DIR" && PATH="$MOCK_BIN:$PATH" MOCK_COMMENTS="$COMMENTS_JSON" GITHUB_EVENT_PATH="$EVENT_JSON" GITHUB_REPOSITORY=example/repo GH_TOKEN=test SIGNATURE_APPROVAL_LOGIN=approver BASE_REF=fixture-base HEAD_REF=fixture-renamed bash "$GUARD" 2>&1)" && approval_missing_rc=0 || approval_missing_rc=$?
printf '%s\n' "$approval_missing_out" | indent
assert "synthetic approval: missing marker exits non-zero (FAILs)" \
  test "$approval_missing_rc" -ne 0
approval_marker="$(grep -F 'Required auditable PR-comment marker: ' <<<"$approval_missing_out" | sed 's/^.*marker: //')"
assert "synthetic approval: guard emits an exact marker" \
  test -n "$approval_marker"
python3 - "$COMMENTS_JSON" "$approval_marker" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump([{"user": {"login": "approver"}, "body": sys.argv[2]}], fh)
PY
approval_ok_out="$(cd "$SCRATCH_DIR" && PATH="$MOCK_BIN:$PATH" MOCK_COMMENTS="$COMMENTS_JSON" GITHUB_EVENT_PATH="$EVENT_JSON" GITHUB_REPOSITORY=example/repo GH_TOKEN=test SIGNATURE_APPROVAL_LOGIN=approver BASE_REF=fixture-base HEAD_REF=fixture-renamed bash "$GUARD" 2>&1)" && approval_ok_rc=0 || approval_ok_rc=$?
printf '%s\n' "$approval_ok_out" | indent
assert "synthetic approval: exact trusted marker exits zero (PASSes)" \
  test "$approval_ok_rc" -eq 0
assert "synthetic approval: reports accepted approval" \
  grep -q 'APPROVED: exact reusable-workflow signature diff' <<<"$approval_ok_out"

# --- Test 6: PR-event-shaped exact base/head integration -------------------
# GitHub's pull_request checkout defaults to a synthetic merge ref.  This
# integration drives the guard with the exact event-shaped base/head pair used
# by the workflows, and proves every approval binding fails closed except the
# exact marker from the approved login.
echo ""
echo "-- Test 6: PR-event-shaped exact base/head approval integration --"
pr_base_sha="${PR_EVENT_BASE_SHA:-}"
pr_head_sha="${PR_EVENT_HEAD_SHA:-}"
if [ -z "$pr_base_sha" ]; then
  pr_base_sha="$(cd "$ROOT_DIR" && git merge-base origin/main HEAD)"
fi
if [ -z "$pr_head_sha" ]; then
  pr_head_sha="$(cd "$ROOT_DIR" && git rev-parse HEAD)"
fi

if git -C "$ROOT_DIR" rev-parse --verify --quiet "${pr_base_sha}^{commit}" >/dev/null \
  && git -C "$ROOT_DIR" rev-parse --verify --quiet "${pr_head_sha}^{commit}" >/dev/null; then
  PR_EVENT_JSON="$SCRATCH_DIR/pr-event.json"
  STALE_EVENT_JSON="$SCRATCH_DIR/pr-event-stale-head.json"
  python3 - "$PR_EVENT_JSON" "$STALE_EVENT_JSON" "$pr_base_sha" "$pr_head_sha" <<'PY'
import json, sys
event = {"number": 42, "pull_request": {"number": 42, "base": {"sha": sys.argv[3]}, "head": {"sha": sys.argv[4]}}}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(event, fh)
event["pull_request"]["head"]["sha"] = sys.argv[3]
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(event, fh)
PY

  run_pr_event_guard() {
    (cd "$ROOT_DIR" && PATH="$MOCK_BIN:$PATH" MOCK_COMMENTS="$COMMENTS_JSON" \
      GITHUB_EVENT_PATH="$1" GITHUB_REPOSITORY=example/repo GH_TOKEN=test \
      SIGNATURE_APPROVAL_LOGIN=approver BASE_REF="$pr_base_sha" \
      HEAD_REF="$pr_head_sha" bash "$GUARD" 2>&1)
  }

  printf '[]\n' > "$COMMENTS_JSON"
  pr_missing_out="$(run_pr_event_guard "$PR_EVENT_JSON")" && pr_missing_rc=0 || pr_missing_rc=$?
  printf '%s\n' "$pr_missing_out" | indent
  assert "PR event: absent marker exits non-zero (FAILs)" \
    test "$pr_missing_rc" -ne 0
  pr_marker="$(grep -F 'Required auditable PR-comment marker: ' <<<"$pr_missing_out" | sed 's/^.*marker: //')"
  assert "PR event: emits an exact base/head marker" \
    test -n "$pr_marker"

  python3 - "$COMMENTS_JSON" "${pr_marker%?}x" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump([{"user": {"login": "approver"}, "body": sys.argv[2]}], fh)
PY
  pr_wrong_digest_out="$(run_pr_event_guard "$PR_EVENT_JSON")" && pr_wrong_digest_rc=0 || pr_wrong_digest_rc=$?
  printf '%s\n' "$pr_wrong_digest_out" | indent
  assert "PR event: wrong-digest marker exits non-zero (FAILs)" \
    test "$pr_wrong_digest_rc" -ne 0

  python3 - "$COMMENTS_JSON" "$pr_marker" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump([{"user": {"login": "untrusted-reviewer"}, "body": sys.argv[2]}], fh)
PY
  pr_wrong_author_out="$(run_pr_event_guard "$PR_EVENT_JSON")" && pr_wrong_author_rc=0 || pr_wrong_author_rc=$?
  printf '%s\n' "$pr_wrong_author_out" | indent
  assert "PR event: wrong-author marker exits non-zero (FAILs)" \
    test "$pr_wrong_author_rc" -ne 0

  python3 - "$COMMENTS_JSON" "$pr_marker" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump([{"user": {"login": "approver"}, "body": sys.argv[2]}], fh)
PY
  pr_stale_head_out="$(run_pr_event_guard "$STALE_EVENT_JSON")" && pr_stale_head_rc=0 || pr_stale_head_rc=$?
  printf '%s\n' "$pr_stale_head_out" | indent
  assert "PR event: stale-head context exits non-zero (FAILs)" \
    test "$pr_stale_head_rc" -ne 0

  pr_exact_out="$(run_pr_event_guard "$PR_EVENT_JSON")" && pr_exact_rc=0 || pr_exact_rc=$?
  printf '%s\n' "$pr_exact_out" | indent
  assert "PR event: exact head/digest/approved-login marker exits zero (PASSes)" \
    test "$pr_exact_rc" -eq 0
else
  echo "  SKIP: PR base/head commits are not available in this checkout"
fi

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
