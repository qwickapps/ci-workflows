#!/usr/bin/env python3
"""Safely clean up head branches of closed, unmerged pull requests.

Deletion is deliberately narrow: a closed, unmerged, same-repository PR must
identify a branch whose current ref still equals the PR head SHA. Protected,
open-PR, allowlisted, ambiguous, and API-error cases always skip deletion.
"""
import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote


@dataclass
class Result:
    ok: bool
    value: object = None
    error: str = ""
    not_found: bool = False


class GitHub:
    def request(self, endpoint, method="GET", paginate=False):
        args = ["gh", "api", endpoint]
        if method != "GET":
            args.extend(["-X", method])
        if paginate:
            args.append("--paginate")
        completed = subprocess.run(args, capture_output=True, text=True)
        if completed.returncode:
            message = completed.stderr.strip()
            return Result(False, error=message, not_found=bool(re.search(r"\b404\b", message)))
        text = completed.stdout.strip()
        if not text:
            return Result(True, None)
        try:
            if paginate:
                decoder, offset, values = json.JSONDecoder(), 0, []
                while offset < len(text):
                    stripped = text[offset:].lstrip()
                    if not stripped:
                        break
                    offset += len(text[offset:]) - len(stripped)
                    item, consumed = decoder.raw_decode(stripped)
                    offset += consumed
                    # gh --paginate emits one JSON array per page.  Accepting
                    # another shape would make an API/proxy error look like a
                    # safe empty/single-item page, so reject it fail-closed.
                    if not isinstance(item, list):
                        return Result(False, error="paginated GitHub API response contains a non-array page")
                    values.extend(item)
                return Result(True, values)
            return Result(True, json.loads(text))
        except json.JSONDecodeError as exc:
            return Result(False, error=f"invalid GitHub API JSON: {exc}")


def endpoint_ref(branch):
    return "git/ref/heads/" + quote(branch, safe="")


def load_allowlist(path):
    try:
        raw = json.loads(Path(path).read_text())
        # bool is a subclass of int in Python, so equality alone would accept
        # JSON true as version 1.  Only the integer literal 1 is supported.
        if not isinstance(raw, dict) or type(raw.get("version")) is not int or raw["version"] != 1:
            raise ValueError("allowlist version must be exactly 1")
        entries = raw.get("allow")
        error = validate_allow_entries(entries)
        if error:
            raise ValueError(error)
        return entries, ""
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return [], f"allowlist unavailable or invalid: {exc}"


def validate_allow_entries(entries):
    if not isinstance(entries, list):
        return "allow must be a list of objects"
    for item in entries:
        if not isinstance(item, dict):
            return "allow entries must be objects"
        for field in ("repository", "branch"):
            pattern = item.get(field)
            if not isinstance(pattern, str) or not pattern:
                return f"allow entry {field} must be a nonempty string"
    return ""


def allowlisted(entries, repo, branch):
    return any(
        fnmatch.fnmatchcase(repo, item.get("repository", ""))
        and fnmatch.fnmatchcase(branch, item.get("branch", ""))
        for item in entries
    )


def valid_open_pr_head(open_pr):
    """Open-PR race guards must be complete; ambiguity prevents deletion."""
    if not isinstance(open_pr, dict):
        return False
    head = open_pr.get("head")
    if not isinstance(head, dict):
        return False
    ref = head.get("ref")
    head_repo = head.get("repo")
    return (
        isinstance(ref, str)
        and bool(ref)
        and isinstance(head_repo, dict)
        and isinstance(head_repo.get("full_name"), str)
        and bool(head_repo["full_name"])
    )


def skip(repo, pr_number, branch, reason):
    return {"repo": repo, "pr": pr_number, "branch": branch, "action": "skipped", "reason": reason}


def evaluate_candidate(api, repo, pr_number, allow_entries, enforce):
    """Evaluate exactly one PR. Every failed/uncertain check is a skip."""
    allow_error = validate_allow_entries(allow_entries)
    if allow_error:
        return skip(repo, pr_number, "", f"allowlist unavailable or invalid: {allow_error}")
    pr_result = api.request(f"repos/{repo}/pulls/{pr_number}")
    if not pr_result.ok or not isinstance(pr_result.value, dict):
        return skip(repo, pr_number, "", "could not read PR")
    pr = pr_result.value
    head = pr.get("head") or {}
    base = pr.get("base") or {}
    branch = head.get("ref", "")
    head_sha = head.get("sha", "")
    head_repo = (head.get("repo") or {}).get("full_name")
    base_repo = (base.get("repo") or {}).get("full_name")
    if pr.get("state") != "closed" or pr.get("merged") is not False:
        return skip(repo, pr_number, branch, "PR is not closed and unmerged")
    if head_repo != repo or base_repo != repo:
        return skip(repo, pr_number, branch, "PR head/base is not the target repository")
    if not branch or not head_sha:
        return skip(repo, pr_number, branch, "PR head ref or SHA is missing")
    if allowlisted(allow_entries, repo, branch):
        return skip(repo, pr_number, branch, "branch is explicitly allowlisted")

    repo_result = api.request(f"repos/{repo}")
    default_branch = repo_result.value.get("default_branch") if repo_result.ok and isinstance(repo_result.value, dict) else None
    if not isinstance(default_branch, str) or not default_branch:
        return skip(repo, pr_number, branch, "could not read repository default branch")
    if branch == default_branch:
        return skip(repo, pr_number, branch, "branch is the default branch")

    first_ref = api.request(f"repos/{repo}/{endpoint_ref(branch)}")
    current_sha = ((first_ref.value or {}).get("object") or {}).get("sha") if first_ref.ok and isinstance(first_ref.value, dict) else None
    if current_sha != head_sha:
        return skip(repo, pr_number, branch, "branch ref is missing or differs from merged PR head SHA")

    protection = api.request(f"repos/{repo}/branches/{quote(branch, safe='')}/protection")
    if protection.ok:
        return skip(repo, pr_number, branch, "branch is protected")
    if not protection.not_found:
        return skip(repo, pr_number, branch, "could not determine branch protection")

    open_prs = api.request(f"repos/{repo}/pulls?state=open&per_page=100", paginate=True)
    if not open_prs.ok or not isinstance(open_prs.value, list):
        return skip(repo, pr_number, branch, "could not determine whether branch heads an open PR")
    for open_pr in open_prs.value:
        if not valid_open_pr_head(open_pr):
            return skip(repo, pr_number, branch, "open PR metadata is incomplete")
        open_head = open_pr["head"]
        if open_head["ref"] == branch and open_head["repo"]["full_name"] == repo:
            return skip(repo, pr_number, branch, "branch heads an open PR")

    # Refetch immediately before deletion to close the branch-recreation race.
    final_ref = api.request(f"repos/{repo}/{endpoint_ref(branch)}")
    final_sha = ((final_ref.value or {}).get("object") or {}).get("sha") if final_ref.ok and isinstance(final_ref.value, dict) else None
    if final_sha != head_sha:
        return skip(repo, pr_number, branch, "branch changed before deletion")
    if not enforce:
        return {"repo": repo, "pr": pr_number, "branch": branch, "action": "candidate", "reason": "all deletion predicates passed; audit only"}

    deletion = api.request(f"repos/{repo}/git/refs/heads/{quote(branch, safe='')}", method="DELETE")
    if not deletion.ok:
        return skip(repo, pr_number, branch, "delete request failed")
    return {"repo": repo, "pr": pr_number, "branch": branch, "action": "deleted", "reason": "all deletion predicates passed"}


def recently_closed(pr, cutoff):
    closed_at = pr.get("closed_at", "") if isinstance(pr, dict) else ""
    try:
        return datetime.fromisoformat(closed_at.replace("Z", "+00:00")) >= cutoff
    except (TypeError, ValueError):
        return False


def audit_org(api, org, allow_entries, since_days):
    repos = api.request(f"orgs/{org}/repos?type=all&per_page=100", paginate=True)
    if not repos.ok or not isinstance(repos.value, list):
        raise RuntimeError("could not list organization repositories")
    cutoff = datetime.now(timezone.utc) - timedelta(days=since_days)
    records = []
    for repo_info in repos.value:
        if not isinstance(repo_info, dict) or repo_info.get("archived"):
            continue
        repo = repo_info.get("full_name")
        if not repo:
            continue
        prs = api.request(f"repos/{repo}/pulls?state=closed&per_page=100", paginate=True)
        if not prs.ok or not isinstance(prs.value, list):
            records.append(skip(repo, None, "", "could not list closed PRs"))
            continue
        for pr in prs.value:
            if recently_closed(pr, cutoff) and not pr.get("merged_at"):
                records.append(evaluate_candidate(api, repo, pr.get("number"), allow_entries, enforce=False))
    return records


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--org", default="qwickapps")
    parser.add_argument("--repo", help="Target repository as owner/name")
    parser.add_argument("--pr-number", type=int, help="Closed, unmerged PR number in --repo")
    parser.add_argument("--enforce", action="store_true", help="Delete only after all safety predicates pass")
    parser.add_argument("--dry-run", action="store_true", help="Audit only (the default for org-wide scans)")
    parser.add_argument("--since-days", type=int, default=2)
    parser.add_argument("--allowlist", default=".github/branch-hygiene-allowlist.json")
    parser.add_argument("--output", default="/tmp/hygiene-report.json")
    args = parser.parse_args()
    if bool(args.repo) != bool(args.pr_number):
        parser.error("--repo and --pr-number must be supplied together")
    if args.enforce and not (args.repo and args.pr_number):
        parser.error("--enforce requires one explicit --repo and --pr-number target")
    if args.repo and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
        parser.error("--repo must be owner/name")

    allow_entries, allow_error = load_allowlist(args.allowlist)
    api = GitHub()
    if args.repo:
        records = [skip(args.repo, args.pr_number, "", allow_error)] if allow_error else [evaluate_candidate(api, args.repo, args.pr_number, allow_entries, args.enforce and not args.dry_run)]
    else:
        if allow_error:
            raise SystemExit(allow_error)
        try:
            records = audit_org(api, args.org, allow_entries, args.since_days)
        except RuntimeError as exc:
            raise SystemExit(str(exc))

    summary = {key: sum(item["action"] == key for item in records) for key in ("deleted", "candidate", "skipped")}
    report = {"run_date": datetime.now(timezone.utc).isoformat(), "org": args.org, "enforce": args.enforce and not args.dry_run, "targeted": bool(args.repo), "records": records, "summary": summary}
    Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
    print(f"[hygiene] deleted={summary['deleted']} candidates={summary['candidate']} skipped={summary['skipped']}")


if __name__ == "__main__":
    main()
