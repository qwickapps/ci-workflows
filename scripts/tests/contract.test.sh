#!/usr/bin/env bash
#
# Unit tests for ci-workflows#6 deploy contract:
#   - workflows/deploy.yml conforms (validate-deploy-contract.sh)
#   - mutated copies fail loudly (negative cases)
#   - scripts/deploy-evidence.sh emits the right shape

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
DEPLOY_YML="$ROOT_DIR/workflows/deploy.yml"
EVIDENCE="$SCRIPTS_DIR/deploy-evidence.sh"
VALIDATOR="$SCRIPTS_DIR/validate-deploy-contract.sh"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

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

# ── Contract validator: golden path ─────────────────────────────────────
echo "== validator: workflows/deploy.yml conforms =="

assert "validator passes on shipped deploy.yml" \
  bash "$VALIDATOR" "$DEPLOY_YML"

# ── Contract validator: negative cases ──────────────────────────────────
echo "== validator: mutated copies fail =="

# Helper: copy deploy.yml into TMPDIR_TEST, run a python script that
# mutates a single key, then assert the validator rejects.
mutate_and_validate() {
  local desc="$1"
  local mutator_script="$2"
  local copy="$TMPDIR_TEST/deploy.yml"
  cp "$DEPLOY_YML" "$copy"
  python3 - "$copy" <<PY
import sys, yaml
path = sys.argv[1]
with open(path) as fh:
    doc = yaml.safe_load(fh)
$mutator_script
with open(path, "w") as fh:
    yaml.safe_dump(doc, fh)
PY
  if bash "$VALIDATOR" "$copy" >/dev/null 2>&1; then
    echo "  FAIL: $desc (validator should have rejected the mutation)"
    fail=$((fail + 1))
  else
    echo "  PASS: $desc"
    pass=$((pass + 1))
  fi
}

mutate_and_validate "removing tests job rejects" '
del doc["jobs"]["tests"]
'
mutate_and_validate "removing evidence job rejects" '
del doc["jobs"]["evidence"]
'
mutate_and_validate "removing build job rejects" '
del doc["jobs"]["build"]
'
mutate_and_validate "removing deploy job rejects" '
del doc["jobs"]["deploy"]
'
mutate_and_validate "removing validate job rejects" '
del doc["jobs"]["validate"]
'
mutate_and_validate "deploy not depending on build rejects" '
doc["jobs"]["deploy"]["needs"] = "preflight"
'
mutate_and_validate "validate not depending on deploy rejects" '
doc["jobs"]["validate"]["needs"] = "build"
'
mutate_and_validate "evidence missing always() rejects" '
doc["jobs"]["evidence"]["if"] = "needs.preflight.result == \"success\""
'
mutate_and_validate "missing image_ref input rejects" '
del doc[True]["workflow_call"]["inputs"]["image_ref"]
'
mutate_and_validate "missing commit output rejects" '
del doc[True]["workflow_call"]["outputs"]["commit"]
'
mutate_and_validate "test_command marked not-required rejects" '
doc[True]["workflow_call"]["inputs"]["test_command"]["required"] = False
'

# ── Evidence script: happy path + required field set ────────────────────
echo "== deploy-evidence: happy path =="

EV_OUT="$($EVIDENCE \
  --commit abcdef1 \
  --target dev \
  --actor operator-test \
  --image-ref ghcr.io/qwickapps/img-foo:1.2.3 \
  --image-digest sha256:abc123 \
  --rollback-target ghcr.io/qwickapps/img-foo:1.2.2 \
  --deploy-result success \
  --validation pass)"

assert "evidence is single-line JSON" \
  bash -c "echo '$EV_OUT' | jq -e . >/dev/null"

# All AC-required output fields present.
for field in commit target actor image_ref deploy_result validation_result emitted_at; do
  assert "evidence includes $field" \
    bash -c "echo '$EV_OUT' | jq -e 'has(\"$field\")' >/dev/null"
done

assert "image_digest round-trips when supplied" \
  bash -c "echo '$EV_OUT' | jq -re '.image_digest' | grep -q '^sha256:abc123\$'"
assert "rollback_target round-trips when supplied" \
  bash -c "echo '$EV_OUT' | jq -re '.rollback_target' | grep -q '^ghcr.io/qwickapps/img-foo:1.2.2\$'"

# ── Evidence script: optional-field omission ────────────────────────────
echo "== deploy-evidence: optional-field omission =="

EV_NO_DIGEST="$($EVIDENCE \
  --commit abc --target dev --actor t --image-ref x:1 \
  --deploy-result success --validation skipped)"

assert "evidence omits image_digest when empty" \
  bash -c "echo '$EV_NO_DIGEST' | jq -e 'has(\"image_digest\") | not' >/dev/null"
assert "evidence omits rollback_target when empty" \
  bash -c "echo '$EV_NO_DIGEST' | jq -e 'has(\"rollback_target\") | not' >/dev/null"
assert "evidence omits caller_metadata when empty" \
  bash -c "echo '$EV_NO_DIGEST' | jq -e 'has(\"caller_metadata\") | not' >/dev/null"

# ── Evidence script: caller-metadata merge ──────────────────────────────
echo "== deploy-evidence: caller_metadata =="

EV_META="$($EVIDENCE \
  --commit abc --target dev --actor t --image-ref x:1 \
  --deploy-result success --validation pass \
  --extra-json '{"branch":"feat/x","run":42}')"

assert "caller_metadata round-trips" \
  bash -c "echo '$EV_META' | jq -e '.caller_metadata.branch == \"feat/x\" and .caller_metadata.run == 42' >/dev/null"

# ── Evidence script: input validation ───────────────────────────────────
echo "== deploy-evidence: input validation =="

assert "missing --commit rejected" \
  bash -c "$EVIDENCE --target d --actor t --image-ref x:1 --deploy-result success --validation pass >/dev/null 2>&1; rc=\$?; test \$rc -eq 2"
assert "invalid --validation rejected" \
  bash -c "$EVIDENCE --commit a --target d --actor t --image-ref x:1 --deploy-result success --validation explosion >/dev/null 2>&1; rc=\$?; test \$rc -eq 2"
assert "invalid --deploy-result rejected" \
  bash -c "$EVIDENCE --commit a --target d --actor t --image-ref x:1 --deploy-result yes --validation pass >/dev/null 2>&1; rc=\$?; test \$rc -eq 2"
assert "non-object --extra-json rejected" \
  bash -c "$EVIDENCE --commit a --target d --actor t --image-ref x:1 --deploy-result success --validation pass --extra-json '[1,2,3]' >/dev/null 2>&1; rc=\$?; test \$rc -eq 2"
assert "malformed --extra-json rejected" \
  bash -c "$EVIDENCE --commit a --target d --actor t --image-ref x:1 --deploy-result success --validation pass --extra-json 'not json' >/dev/null 2>&1; rc=\$?; test \$rc -eq 2"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
