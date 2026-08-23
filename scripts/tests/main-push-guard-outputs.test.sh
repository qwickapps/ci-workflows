#!/usr/bin/env bash
#
# Unit tests for qwickapps/ci-workflows#122: main-push-guard.yml's
# `on.workflow_call` block declared `inputs`/`secrets` but never
# re-exposed the `build-push` job's `image_ref`/`image_tag` outputs via
# a top-level `on.workflow_call.outputs` block. Per GitHub Actions
# semantics, a reusable workflow's job outputs are invisible to a
# caller (`needs.<job>.outputs.X`) unless explicitly re-declared that
# way — so every consumer's `needs.build-once.outputs.image_ref` (or
# equivalent) silently resolved to an empty string, with no error.
#
# Traced live in qwickapps/mcp#333: mcp's deploy.yml read the empty
# output as `GUARD_IMAGE=""`, which sent deploy-app.yml down its own
# default-image fallback path — rebuilding a redundant image under the
# wrong GHCR repo (missing mcp's `-prod` suffix) and silently retagging
# `:release-candidate` there instead of the real image repo. That is
# why `:release-candidate` sat on a two-month-old commit despite the
# pipeline's own documented design ("UAT/live/stable never rebuild;
# they retag forward only" — deploy-app.yml's header comment).
#
# This is intentionally a plain assertion test (unlike
# contract.test.sh's validator + mutation-rejection harness) — the fix
# is a single, narrow structural addition to one file, not a
# general-purpose contract with many independently-violable rules.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/main-push-guard.yml"

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

echo "== main-push-guard.yml: workflow_call re-exposes build-push's job outputs (ci-workflows#122) =="

assert "workflow file exists" \
  test -f "$WORKFLOW"

if python3 - "$WORKFLOW" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.stderr.write(
        "::error::PyYAML is required for this test; install with `pip install PyYAML`\n"
    )
    sys.exit(2)

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)

# YAML 1.1 quirk (also relied on by validate-deploy-contract.sh and
# contract.test.sh): the bare key `on` is parsed as the boolean True.
on_block = doc.get(True, doc.get("on"))
workflow_call = (on_block or {}).get("workflow_call") or {}
outputs = workflow_call.get("outputs") or {}

build_push_outputs = ((doc.get("jobs") or {}).get("build-push") or {}).get("outputs") or {}

errors = []

for name in ("image_ref", "image_tag"):
    if name not in outputs:
        errors.append(f"on.workflow_call.outputs.{name} is missing")
        continue
    value = outputs[name].get("value") if isinstance(outputs[name], dict) else None
    if value is None:
        errors.append(f"on.workflow_call.outputs.{name} has no 'value' key")
        continue
    expected = f"${{{{ jobs.build-push.outputs.{name} }}}}"
    if value != expected:
        errors.append(
            f"on.workflow_call.outputs.{name}.value is {value!r}, expected {expected!r}"
        )
    if name not in build_push_outputs:
        errors.append(
            f"jobs.build-push.outputs.{name} no longer exists — the value "
            f"this output points at would be dangling"
        )

if errors:
    for e in errors:
        sys.stderr.write(f"FAIL: {e}\n")
    sys.exit(1)

sys.exit(0)
PY
then
  echo "  PASS: on.workflow_call.outputs.image_ref/image_tag wired to jobs.build-push.outputs"
  pass=$((pass + 1))
else
  echo "  FAIL: on.workflow_call.outputs.image_ref/image_tag not correctly wired"
  fail=$((fail + 1))
fi

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
