#!/usr/bin/env bash
#
# Guards against the ci-workflows#175 incident class: a PR silently changed
# an existing reusable workflow's callable signature -- its
# `on.workflow_call.inputs` / `.outputs` / `.secrets` key names -- and
# nothing compared the interface before vs after, so 6 dependent repos'
# build pipelines broke for hours before anyone noticed.
#
# Concretely: commit 90e0adf9 rewrote main-push-guard.yml from a reusable
# workflow (on.workflow_call, with inputs like `image_name` and secrets like
# `GHCR_PUSH_TOKEN`) into a plain `on.push` thin wrapper -- dropping its
# entire callable interface -- while every consuming repo was still calling
# it with `uses: .../main-push-guard.yml@main` plus `with:`/`secrets:`
# blocks written for the OLD signature. Nothing caught it because nothing
# diffed a reusable workflow's interface across the PR.
#
# This script does that diff for every reusable workflow in the repo:
#
#   - Finds every .github/workflows/*.yml|*.yaml file that declares
#     `on.workflow_call:` at HEAD_REF (a "reusable workflow").
#   - For each one that ALSO existed (as a file) at BASE_REF, compares the
#     KEY SETS under on.workflow_call.inputs / .outputs / .secrets between
#     BASE_REF and HEAD_REF.
#   - FAILS LOUDLY if any section's key set differs at all -- added,
#     removed, OR renamed. This is deliberately a hard stop on ANY
#     signature change, not just removals: an added-looking key can really
#     be a rename that silently orphans callers still passing the old name,
#     and the point is forcing a human to consciously notice and review the
#     change, not to wave additive-looking diffs through.
#   - Also FAILS if a file that WAS a reusable workflow at BASE_REF is no
#     longer one at HEAD_REF (workflow_call block removed, or the file was
#     deleted outright) -- the more extreme version of the same failure
#     mode, and exactly what the ci-workflows#175 incident did.
#   - A brand-new reusable workflow (no workflow_call at BASE_REF, present
#     at HEAD_REF) is fine -- there is nothing to compare it against.
#
# Requires PyYAML (python3 -c 'import yaml').
#
# Usage -- CI / PR gate (compares BASE_REF against the current working
# tree, i.e. the PR head checkout):
#
#   BASE_REF=<pr-base-sha-or-ref> bash scripts/check-reusable-workflow-signatures.sh
#
# Usage -- local / standalone, comparing two arbitrary refs or commits
# (this is also how this script's own regression test drives it against
# fixture commits, without needing to check either one out):
#
#   BASE_REF=<ref> HEAD_REF=<ref> bash scripts/check-reusable-workflow-signatures.sh
#
# Must be run from inside the git checkout to validate (any subdirectory is
# fine; git plumbing resolves paths relative to the repo root).

set -euo pipefail

BASE_REF="${BASE_REF:-}"
HEAD_REF="${HEAD_REF:-}"

if [ -z "$BASE_REF" ]; then
  echo "::error::BASE_REF is required (git ref/sha to diff reusable-workflow signatures against)" >&2
  echo "Usage: BASE_REF=<ref> [HEAD_REF=<ref>] bash scripts/check-reusable-workflow-signatures.sh" >&2
  exit 2
fi

if ! git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null; then
  echo "::error::BASE_REF '$BASE_REF' does not resolve to a commit in this checkout (fetch it first, e.g. \`git fetch origin \$BASE_REF\`, or use a full-history checkout)" >&2
  exit 2
fi

if [ -n "$HEAD_REF" ] && ! git rev-parse --verify --quiet "${HEAD_REF}^{commit}" >/dev/null; then
  echo "::error::HEAD_REF '$HEAD_REF' does not resolve to a commit in this checkout" >&2
  exit 2
fi

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "::error::PyYAML is required for this script; install with \`pip install PyYAML\`" >&2
  exit 2
fi

python3 - "$BASE_REF" "$HEAD_REF" <<'PY'
import os
import subprocess
import sys

import yaml

base_ref = sys.argv[1]
head_ref = sys.argv[2] or None  # empty string -> working tree

WORKFLOWS_DIR = ".github/workflows"


def git_ls_workflow_files(ref):
    """Sorted list of workflow yml/yaml paths at `ref`, or on disk if ref is None."""
    if ref is None:
        if not os.path.isdir(WORKFLOWS_DIR):
            return []
        return sorted(
            f"{WORKFLOWS_DIR}/{name}"
            for name in os.listdir(WORKFLOWS_DIR)
            if name.endswith(".yml") or name.endswith(".yaml")
        )
    proc = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", ref, "--", WORKFLOWS_DIR],
        capture_output=True, text=True, check=True,
    )
    return sorted(
        line for line in proc.stdout.splitlines()
        if line.endswith(".yml") or line.endswith(".yaml")
    )


def read_file(ref, path):
    """Content of `path` at `ref` (git show), or from disk if ref is None.
    Returns None if the file doesn't exist there."""
    if ref is None:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                return fh.read()
        except FileNotFoundError:
            return None
    proc = subprocess.run(
        ["git", "show", f"{ref}:{path}"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout


def extract_signature(content):
    """(is_reusable, {section: set(keys)}) for workflow YAML text.
    (False, {}) for missing/unparseable/non-reusable content."""
    if content is None:
        return False, {}
    try:
        doc = yaml.safe_load(content)
    except yaml.YAMLError as e:
        print(f"::warning::could not parse YAML ({e}); treating as non-reusable")
        return False, {}
    if not isinstance(doc, dict):
        return False, {}
    # YAML 1.1 quirk (also relied on elsewhere in this repo, e.g.
    # main-push-guard-outputs.test.sh): the bare key `on` parses as True.
    on_block = doc.get(True, doc.get("on"))
    if not isinstance(on_block, dict):
        return False, {}
    workflow_call = on_block.get("workflow_call")
    if not isinstance(workflow_call, dict):
        return False, {}
    sig = {}
    for section in ("inputs", "outputs", "secrets"):
        block = workflow_call.get(section) or {}
        sig[section] = set(block.keys()) if isinstance(block, dict) else set()
    return True, sig


base_files = set(git_ls_workflow_files(base_ref))
head_files = set(git_ls_workflow_files(head_ref))
all_files = sorted(base_files | head_files)

failures = []
checked = 0
new_count = 0

for path in all_files:
    base_content = read_file(base_ref, path)
    head_content = read_file(head_ref, path)

    base_reusable, base_sig = extract_signature(base_content)
    head_reusable, head_sig = extract_signature(head_content)

    if not base_reusable and not head_reusable:
        continue

    if not base_reusable and head_reusable:
        print(f"NEW reusable workflow: {path} (nothing to compare against, OK)")
        new_count += 1
        continue

    checked += 1

    if base_reusable and not head_reusable:
        reason = "file deleted" if path not in head_files else "on.workflow_call removed"
        failures.append(
            f"{path}: reusable-workflow interface REMOVED ({reason}).\n"
            f"    was callable at {base_ref} with:\n"
            f"      inputs:  {sorted(base_sig['inputs'])}\n"
            f"      outputs: {sorted(base_sig['outputs'])}\n"
            f"      secrets: {sorted(base_sig['secrets'])}\n"
            f"    Dependent repos still calling this workflow with `uses:` "
            f"plus `with:`/`secrets:` for the old signature will break."
        )
        continue

    section_diffs = []
    for section in ("inputs", "outputs", "secrets"):
        before = base_sig.get(section, set())
        after = head_sig.get(section, set())
        if before != after:
            added = sorted(after - before)
            removed = sorted(before - after)
            section_diffs.append(
                f"      [{section}] before={sorted(before)}\n"
                f"      [{section}] after= {sorted(after)}\n"
                f"      [{section}] added={added} removed={removed}"
            )

    if section_diffs:
        failures.append(
            f"{path}: on.workflow_call signature CHANGED between {base_ref} and "
            f"{head_ref or 'working tree'}:\n" + "\n".join(section_diffs)
        )
    else:
        print(f"OK: {path} (signature unchanged)")

print("")
print(
    f"Checked {checked} reusable workflow(s) present at both base ({base_ref}) "
    f"and head ({head_ref or 'working tree'}); {new_count} new reusable workflow(s) skipped."
)

if failures:
    print("")
    print(f"FAIL: {len(failures)} reusable-workflow signature change(s) detected:")
    for f in failures:
        print(f"\n- {f}")
    print("")
    print(
        "A reusable workflow's on.workflow_call.inputs/outputs/secrets keys "
        "changed. This is treated as a breaking change regardless of whether "
        "it looks additive, because an added-looking key can be a silent "
        "rename that orphans callers still using the old name. If this is "
        "intentional: update every consuming repo in the same change (or "
        "keep both old and new keys during a migration window), then have a "
        "human consciously approve this diff."
    )
    sys.exit(1)

print("PASS: no reusable-workflow signature changes detected.")
sys.exit(0)
PY
