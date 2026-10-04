#!/usr/bin/env python3
"""Fail closed on vague preserved-branch handoff reports.

The checker is deliberately report-only: it verifies that a completed branch
lane records fresh, internally consistent coverage and that every preserved
branch names a concrete accountable follow-up. It never changes GitHub state.
"""
import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path


GENERIC_PHRASES = (
    "pending owner decision",
    "repo maintainer must triage",
    "create pr if useful",
)
TASK_OR_AGENT = re.compile(
    r"\b(?:task|kanban task)\s+t_[0-9a-f]{8}\b|\bagent\s+@[a-z][a-z0-9_-]*\b",
    re.IGNORECASE,
)
PR_DECISION = re.compile(
    r"\bpr\s+#\d+\b.*\b(?:open|reopen|close|merge|verify|check|decide|decision)\b"
    r"|\b(?:open|reopen|close|merge|verify|check|decide|decision)\b.*\bpr\s+#\d+\b",
    re.IGNORECASE,
)
UNIQUE_COMMIT_DECISION = re.compile(
    r"\bunique\s+commits?\b.*\b(?:preserve|check|verify|decide|decision)\b"
    r"|\b(?:preserve|check|verify|decide|decision)\b.*\bunique\s+commits?\b",
    re.IGNORECASE,
)
SHA = re.compile(r"^[0-9a-f]{40}$")


def fail(errors, message):
    errors.append(message)


def branch_rows(report, errors):
    repositories = report.get("repositories")
    if not isinstance(repositories, list) or not repositories:
        fail(errors, "repositories must be a non-empty list")
        return []
    rows = []
    for repository in repositories:
        if not isinstance(repository, dict):
            fail(errors, "repository entry must be an object")
            continue
        name = repository.get("repository")
        branches = repository.get("branches")
        if not isinstance(name, str) or not name:
            fail(errors, "repository entry lacks repository name")
            continue
        if not isinstance(branches, list):
            fail(errors, f"{name}: branches must be a list")
            continue
        rows.extend((name, branch) for branch in branches)
    return rows


def handoff_is_specific(branch, action):
    cited_branch_or_sha = branch["branch"] in action or branch["observed_sha"] in action
    decision = PR_DECISION.search(action) or UNIQUE_COMMIT_DECISION.search(action)
    return bool(TASK_OR_AGENT.search(action) and cited_branch_or_sha and decision)


def validate(report):
    """Return a list of contract violations; an empty list is a valid report."""
    errors = []
    if not isinstance(report, dict):
        return ["report must be an object"]
    if report.get("schema_version") != 1:
        fail(errors, "schema_version must be exactly 1")
    if not isinstance(report.get("generated_at"), str) or not report["generated_at"]:
        fail(errors, "generated_at must be present")

    rows = branch_rows(report, errors)
    actual_coverage = Counter()
    for repository, branch in rows:
        actual_coverage[repository] += 1
        if not isinstance(branch, dict):
            fail(errors, f"{repository}: branch entry must be an object")
            continue
        required = ("branch", "observed_sha", "disposition", "ownership_evidence", "next_action")
        missing = [field for field in required if field not in branch]
        if missing:
            fail(errors, f"{repository}: missing branch fields: {', '.join(missing)}")
            continue
        if not isinstance(branch["branch"], str) or not branch["branch"]:
            fail(errors, f"{repository}: branch name must be non-empty")
            continue
        if not isinstance(branch["observed_sha"], str) or not SHA.fullmatch(branch["observed_sha"]):
            fail(errors, f"{repository}/{branch['branch']}: observed_sha must be a 40-character SHA")
        if branch["disposition"] != "preserve":
            fail(errors, f"{repository}/{branch['branch']}: disposition must be preserve")
        if not isinstance(branch["ownership_evidence"], dict):
            fail(errors, f"{repository}/{branch['branch']}: ownership_evidence must be an object")
        action = branch["next_action"]
        if not isinstance(action, str) or not action.strip():
            fail(errors, f"{repository}/{branch['branch']}: next_action must be non-empty")
            continue
        normalized = action.casefold()
        generic = next((phrase for phrase in GENERIC_PHRASES if phrase in normalized), None)
        if generic:
            fail(errors, f"{repository}/{branch['branch']}: generic next_action phrase: {generic}")
        if not handoff_is_specific(branch, action):
            fail(errors, f"{repository}/{branch['branch']}: next_action must name task t_<8 hex> or agent @name, cite this branch or SHA, and state a PR or unique-commit decision/check")

    coverage = report.get("coverage")
    if not isinstance(coverage, dict) or any(not isinstance(value, int) or value < 0 for value in coverage.values()):
        fail(errors, "coverage must be a mapping of repository names to non-negative integer totals")
    elif dict(actual_coverage) != coverage:
        fail(errors, f"coverage does not match branch rows: expected {dict(actual_coverage)}, got {coverage}")
    total = report.get("total_non_default_branches")
    if not isinstance(total, int) or total != len(rows):
        fail(errors, f"total_non_default_branches must equal branch-row total {len(rows)}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    try:
        report = json.loads(args.report.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"invalid report: {exc}")
    errors = validate(report)
    if errors:
        print("[branch-handoff] FAILED", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        raise SystemExit(1)
    print(f"[branch-handoff] PASS total={report['total_non_default_branches']} coverage={report['coverage']}")


if __name__ == "__main__":
    main()
