#!/usr/bin/env python3
"""Validate a fresh preserved-branch handoff report against a lane inventory.

The report and the independently collected inventory each contain a UTC timestamp.
Both must be no more than one hour old when validated; the report may not predate
its inventory.  The checker is read-only and never changes GitHub state.
"""
import argparse
import json
import re
import sys
from collections import Counter
from datetime import datetime, timezone
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
# Citation grammar: a `branch` or `sha` label, ASCII space/tab, then the identity
# token.  The token ends ONLY at a byte Git forbids inside every ref name: ASCII
# control characters (U+0000-U+001F), space (U+0020) or DEL (U+007F).  Regex
# word boundaries and Unicode-aware `\S`/`\s` are NOT Git ref token boundaries:
# Git refs may legally contain `+`, `@`, `=`, letters such as `é`, and Unicode
# whitespace such as U+00A0 or U+2028, so any of those would truncate a longer,
# different ref into an apparent exact citation.  The whole token must then
# equal the observed identity exactly.
GIT_REF_DELIMITER = r"\x00-\x20\x7f"
IDENTITY_TOKEN = rf"(?P<identity>[^{GIT_REF_DELIMITER}]+)(?=[{GIT_REF_DELIMITER}]|\Z)"
BRANCH_CITATION = re.compile(rf"\bbranch[ \t]+{IDENTITY_TOKEN}", re.IGNORECASE)
SHA_CITATION = re.compile(rf"\bsha[ \t]+{IDENTITY_TOKEN}", re.IGNORECASE)
MAX_FRESHNESS_SECONDS = 60 * 60


def fail(errors, message):
    errors.append(message)


def parse_timestamp(value, field, errors):
    """Return an aware UTC datetime, or None after recording a clean error."""
    if not isinstance(value, str) or not value:
        fail(errors, f"{field} must be a non-empty ISO-8601 timestamp")
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        fail(errors, f"{field} must be a valid ISO-8601 timestamp")
        return None
    if parsed.tzinfo is None:
        fail(errors, f"{field} must include a timezone")
        return None
    try:
        return parsed.astimezone(timezone.utc)
    except (OverflowError, OSError, ValueError):
        fail(errors, f"{field} must be a valid ISO-8601 timestamp within the supported range")
        return None


def require_fresh(timestamp, field, now, errors):
    if timestamp is None:
        return
    age = (now - timestamp).total_seconds()
    if age < 0:
        fail(errors, f"{field} must not be in the future")
    elif age > MAX_FRESHNESS_SECONDS:
        fail(errors, f"{field} exceeds {MAX_FRESHNESS_SECONDS}-second freshness window")


def exact_identity_cited(pattern, value, action):
    """Require a Git-delimited identity token after a label to equal value exactly."""
    return any(match.group("identity") == value for match in pattern.finditer(action))


def handoff_is_specific(branch, action):
    cited_branch_or_sha = (
        exact_identity_cited(BRANCH_CITATION, branch["branch"], action)
        or exact_identity_cited(SHA_CITATION, branch["observed_sha"], action)
    )
    decision = PR_DECISION.search(action) or UNIQUE_COMMIT_DECISION.search(action)
    return bool(TASK_OR_AGENT.search(action) and cited_branch_or_sha and decision)


def validate_inventory(inventory, now, errors):
    """Return {repository: {default_branch, branches}} and whether identities are sound."""
    result = {}
    identities_valid = True
    if not isinstance(inventory, dict):
        fail(errors, "inventory must be an object")
        return result, False, None
    if inventory.get("schema_version") != 1:
        fail(errors, "inventory schema_version must be exactly 1")
    observed_at = parse_timestamp(inventory.get("observed_at"), "inventory observed_at", errors)
    require_fresh(observed_at, "inventory observed_at", now, errors)
    repositories = inventory.get("repositories")
    if not isinstance(repositories, list) or not repositories:
        fail(errors, "inventory repositories must be a non-empty list")
        return result, False, observed_at
    for entry in repositories:
        if not isinstance(entry, dict):
            fail(errors, "inventory repository entry must be an object")
            identities_valid = False
            continue
        repository = entry.get("repository")
        default_branch = entry.get("default_branch")
        branches = entry.get("branches")
        if not isinstance(repository, str) or not repository:
            fail(errors, "inventory repository entry lacks repository name")
            identities_valid = False
            continue
        if repository in result:
            fail(errors, f"inventory duplicate repository: {repository}")
            identities_valid = False
            continue
        if not isinstance(default_branch, str) or not default_branch:
            fail(errors, f"{repository}: inventory default_branch must be non-empty")
            identities_valid = False
            continue
        if not isinstance(branches, list):
            fail(errors, f"{repository}: inventory branches must be a list")
            identities_valid = False
            continue
        seen = set()
        exact = {}
        for branch in branches:
            if not isinstance(branch, dict):
                fail(errors, f"{repository}: inventory branch entry must be an object")
                identities_valid = False
                continue
            name = branch.get("branch")
            sha = branch.get("observed_sha")
            if not isinstance(name, str) or not name:
                fail(errors, f"{repository}: inventory branch name must be non-empty")
                identities_valid = False
                continue
            if name == default_branch:
                fail(errors, f"{repository}/{name}: inventory must exclude default branch")
                identities_valid = False
                continue
            if not isinstance(sha, str) or not SHA.fullmatch(sha):
                fail(errors, f"{repository}/{name}: inventory observed_sha must be a 40-character SHA")
                identities_valid = False
                continue
            if name in seen:
                fail(errors, f"{repository}/{name}: duplicate inventory branch identity")
                identities_valid = False
                continue
            seen.add(name)
            exact[name] = sha
        result[repository] = {"default_branch": default_branch, "branches": exact}
    return result, identities_valid, observed_at


def validate(report, inventory, now=None):
    """Return contract violations; an empty list means report matches fresh inventory."""
    errors = []
    now = now or datetime.now(timezone.utc)
    if not isinstance(now, datetime):
        return ["now must be a datetime"]
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    else:
        now = now.astimezone(timezone.utc)
    if not isinstance(report, dict):
        return ["report must be an object"]
    if report.get("schema_version") != 1:
        fail(errors, "schema_version must be exactly 1")
    generated_at = parse_timestamp(report.get("generated_at"), "generated_at", errors)
    require_fresh(generated_at, "generated_at", now, errors)
    inventory_by_repo, inventory_identities_valid, observed_at = validate_inventory(inventory, now, errors)
    if generated_at is not None and observed_at is not None and generated_at < observed_at:
        fail(errors, "generated_at must not predate inventory observed_at")

    repositories = report.get("repositories")
    report_identities_valid = True
    report_by_repo = {}
    if not isinstance(repositories, list) or not repositories:
        fail(errors, "repositories must be a non-empty list")
        report_identities_valid = False
    else:
        for entry in repositories:
            if not isinstance(entry, dict):
                fail(errors, "repository entry must be an object")
                report_identities_valid = False
                continue
            repository = entry.get("repository")
            branches = entry.get("branches")
            if not isinstance(repository, str) or not repository:
                fail(errors, "repository entry lacks repository name")
                report_identities_valid = False
                continue
            if repository in report_by_repo:
                fail(errors, f"duplicate report repository: {repository}")
                report_identities_valid = False
                continue
            if not isinstance(branches, list):
                fail(errors, f"{repository}: branches must be a list")
                report_identities_valid = False
                continue
            report_by_repo[repository] = branches

    actual_coverage = Counter({repository: 0 for repository in report_by_repo})
    report_identities = {}
    for repository, branches in report_by_repo.items():
        seen = set()
        identities = {}
        for branch in branches:
            if not isinstance(branch, dict):
                fail(errors, f"{repository}: branch entry must be an object")
                report_identities_valid = False
                continue
            required = ("branch", "observed_sha", "disposition", "ownership_evidence", "next_action")
            missing = [field for field in required if field not in branch]
            if missing:
                fail(errors, f"{repository}: missing branch fields: {', '.join(missing)}")
                report_identities_valid = False
                continue
            name = branch.get("branch")
            sha = branch.get("observed_sha")
            if not isinstance(name, str) or not name:
                fail(errors, f"{repository}: branch name must be non-empty")
                report_identities_valid = False
                continue
            if not isinstance(sha, str) or not SHA.fullmatch(sha):
                fail(errors, f"{repository}/{name}: observed_sha must be a 40-character SHA")
                report_identities_valid = False
                continue
            if name in seen:
                fail(errors, f"{repository}/{name}: duplicate report branch identity")
                report_identities_valid = False
                continue
            seen.add(name)
            identities[name] = sha
            actual_coverage[repository] += 1
            if branch["disposition"] != "preserve":
                fail(errors, f"{repository}/{name}: disposition must be preserve")
            if not isinstance(branch["ownership_evidence"], dict):
                fail(errors, f"{repository}/{name}: ownership_evidence must be an object")
            action = branch["next_action"]
            if not isinstance(action, str) or not action.strip():
                fail(errors, f"{repository}/{name}: next_action must be non-empty")
                continue
            normalized = action.casefold()
            generic = next((phrase for phrase in GENERIC_PHRASES if phrase in normalized), None)
            if generic:
                fail(errors, f"{repository}/{name}: generic next_action phrase: {generic}")
            # Identity validation above deliberately gates this specificity check.
            if not handoff_is_specific(branch, action):
                fail(errors, f"{repository}/{name}: next_action must name task t_<8 hex> or agent @name, cite this exact branch or SHA, and state a PR or unique-commit decision/check")
        report_identities[repository] = identities

    coverage = report.get("coverage")
    if not isinstance(coverage, dict) or any(
        not isinstance(key, str) or not key or not isinstance(value, int) or isinstance(value, bool) or value < 0
        for key, value in coverage.items()
    ):
        fail(errors, "coverage must be a mapping of repository names to non-negative integer totals")
    elif dict(actual_coverage) != coverage:
        fail(errors, f"coverage does not match unique branch identities: expected {dict(actual_coverage)}, got {coverage}")
    total = report.get("total_non_default_branches")
    unique_total = sum(actual_coverage.values())
    if not isinstance(total, int) or isinstance(total, bool) or total != unique_total:
        fail(errors, f"total_non_default_branches must equal unique branch total {unique_total}")

    if report_identities_valid and inventory_identities_valid:
        if set(report_by_repo) != set(inventory_by_repo):
            fail(errors, "report repositories do not exactly match inventory repositories")
        for repository in sorted(set(report_by_repo) & set(inventory_by_repo)):
            default_branch = inventory_by_repo[repository]["default_branch"]
            report_branches = report_identities[repository]
            inventory_branches = inventory_by_repo[repository]["branches"]
            if default_branch in report_branches:
                fail(errors, f"{repository}/{default_branch}: report must exclude default branch")
            if set(report_branches) != set(inventory_branches):
                fail(errors, f"{repository}: report branch identities do not exactly match inventory")
            for branch in sorted(set(report_branches) & set(inventory_branches)):
                if report_branches[branch] != inventory_branches[branch]:
                    fail(errors, f"{repository}/{branch}: report observed_sha does not match inventory")
    return errors


def load_json(path, label):
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"invalid {label}: {exc}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("inventory", type=Path, help="independently collected lane inventory")
    args = parser.parse_args()
    report = load_json(args.report, "report")
    inventory = load_json(args.inventory, "inventory")
    errors = validate(report, inventory)
    if errors:
        print("[branch-handoff] FAILED", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        raise SystemExit(1)
    print(f"[branch-handoff] PASS total={report['total_non_default_branches']} coverage={report['coverage']}")


if __name__ == "__main__":
    main()
