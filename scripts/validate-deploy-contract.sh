#!/usr/bin/env bash
#
# validate-deploy-contract.sh — assert that workflows/deploy.yml has
# all the required gates wired with strict `needs:` ordering. Closes
# part of qwickapps/ci-workflows#6 ("contract tests proving required
# gates and evidence outputs cannot be skipped by callers").
#
# The verification is intentionally simple: walk the YAML with
# `yq` (or `python3 -c` as a fallback) and assert the structure.
# The reason the test is at this layer is that GitHub Actions
# reusable workflows aren't directly unit-testable — the only way
# to prove the contract holds is to validate the workflow file
# itself.
#
# Usage:
#   ./validate-deploy-contract.sh [path/to/deploy.yml]
#
# Defaults to ../workflows/deploy.yml relative to the script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DEPLOY="$(cd "$SCRIPT_DIR/.." && pwd)/workflows/deploy.yml"
DEPLOY_FILE="${1:-$DEFAULT_DEPLOY}"

if [ ! -f "$DEPLOY_FILE" ]; then
  echo "::error::deploy.yml not found at $DEPLOY_FILE" >&2
  exit 2
fi

# We use python3 + the yaml stdlib (PyYAML, available on every
# self-hosted runner via pip; falls back to a manual parse if not
# installed) rather than yq to keep the runtime dependency surface
# down to "python3, which we already need for everything else."
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "::error::PyYAML is required to validate the deploy contract; pip install PyYAML" >&2
  exit 2
fi

# ── Drive the assertions in Python ───────────────────────────────────────
python3 - "$DEPLOY_FILE" <<'PY'
import sys
import yaml

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)

errors: list[str] = []

def fail(msg: str) -> None:
    errors.append(msg)

# 1. Must be a workflow_call (reusable) workflow.
# YAML 1.1 quirk: the bare key `on` is parsed as the boolean True by
# PyYAML's safe_load. Look it up under both keys so the validator
# works regardless of which dialect parsed the file.
on = None
if isinstance(doc, dict):
    on = doc.get("on")
    if on is None:
        on = doc.get(True)  # YAML 1.1 boolean key
if isinstance(on, dict):
    if "workflow_call" not in on:
        fail("on.workflow_call missing — deploy.yml must be a reusable workflow")
elif on is True or on == "workflow_call":
    pass  # accept the shorthand form
else:
    fail("on: must be a mapping containing workflow_call")

# 2. Required inputs (cannot be defaulted away).
inputs = ((on or {}).get("workflow_call") or {}).get("inputs") or {}
required_inputs = {
    "target_environment": True,
    "image_name":         True,
    "image_ref":          True,
    "test_command":       True,
    "build_command":      True,
    "deploy_command":     True,
}
for name, must_be_required in required_inputs.items():
    spec = inputs.get(name)
    if not isinstance(spec, dict):
        fail(f"input.{name} missing")
        continue
    if must_be_required and not spec.get("required"):
        fail(f"input.{name}.required must be true (cannot be defaulted away)")

# 3. Required outputs (the AC explicitly enumerates these).
outputs = ((on or {}).get("workflow_call") or {}).get("outputs") or {}
for name in (
    "commit", "image_digest", "target", "actor",
    "validation_result", "rollback_target",
):
    if name not in outputs:
        fail(f"output.{name} missing — required by AC")

# 4. Required jobs in a strict needs chain.
jobs = doc.get("jobs") or {}
required_chain = [
    ("preflight", None),
    ("tests",     "preflight"),
    ("build",     "tests"),
    ("deploy",    "build"),
    ("validate",  "deploy"),
]
for job_name, expected_dep in required_chain:
    job = jobs.get(job_name)
    if not isinstance(job, dict):
        fail(f"job.{job_name} missing")
        continue
    if expected_dep is None:
        continue
    needs = job.get("needs")
    if isinstance(needs, str):
        needs_list = [needs]
    elif isinstance(needs, list):
        needs_list = needs
    else:
        needs_list = []
    if expected_dep not in needs_list:
        fail(
            f"job.{job_name}.needs must include {expected_dep!r} "
            f"(got {needs_list!r}) — without it a caller could disable the upstream gate"
        )

# 5. Evidence job must exist and depend on validate (so the audit
# record reflects the validation outcome) and on preflight (to capture
# the deploy context).
evidence = jobs.get("evidence")
if not isinstance(evidence, dict):
    fail("job.evidence missing — required for AC ('evidence upload cannot be skipped')")
else:
    needs = evidence.get("needs") or []
    if isinstance(needs, str):
        needs = [needs]
    for dep in ("preflight", "build", "deploy", "validate"):
        if dep not in needs:
            fail(f"job.evidence.needs must include {dep!r}")
    if "if" not in evidence or "always()" not in str(evidence["if"]):
        fail(
            "job.evidence.if must include always() so failed deploys "
            "still produce an audit record"
        )
    # The evidence step must include an actions/upload-artifact step.
    steps = evidence.get("steps") or []
    has_upload = any(
        isinstance(s, dict) and "upload-artifact" in str(s.get("uses") or "")
        for s in steps
    )
    if not has_upload:
        fail("job.evidence must include an actions/upload-artifact step")

if errors:
    print("contract validation FAILED:", file=sys.stderr)
    for err in errors:
        print(f"  - {err}", file=sys.stderr)
    sys.exit(1)

print("contract validation OK: deploy.yml conforms to the qwickapps/ci-workflows#6 contract")
PY
