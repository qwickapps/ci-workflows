#!/usr/bin/env python3
"""Weekly, fail-closed branch sweep for the qwickapps organization.

Default mode is dry-run.  Live mode is intentionally narrow and only runs after
an explicit workflow dispatch with dry_run=false.
"""
import argparse
import json
import os
import re
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote

MARKER = "<!-- qwickapps-branch-sweep-stale-warning:v1 -->"
PROTECTED_PATTERNS = ("main", "master", "dev", "develop")


class ApiError(RuntimeError):
    pass


class GitHub:
    def request(self, endpoint, method="GET", fields=None, paginate=False):
        args = ["gh", "api", endpoint, "-X", method]
        if paginate:
            args.append("--paginate")
        for key, value in (fields or {}).items():
            args += ["-f", f"{key}={value}"]
        completed = subprocess.run(args, capture_output=True, text=True)
        if completed.returncode:
            return None, completed.stderr.strip()
        text = completed.stdout.strip()
        if not text:
            return None, ""
        try:
            if not paginate:
                return json.loads(text), ""
            decoder, offset, result = json.JSONDecoder(), 0, []
            while offset < len(text):
                rest = text[offset:].lstrip()
                if not rest:
                    break
                offset += len(text[offset:]) - len(rest)
                value, used = decoder.raw_decode(rest)
                offset += used
                if not isinstance(value, list):
                    return None, "pagination response was not a list"
                result.extend(value)
            return result, ""
        except json.JSONDecodeError as exc:
            return None, f"invalid JSON: {exc}"


def stamp(value):
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def protected_name(name):
    return name in PROTECTED_PATTERNS or name.startswith("release/") or re.fullmatch(r"v.*-stable", name) is not None


def action(repo, branch, kind, reason, **extra):
    return {"repo": repo, "branch": branch, "action": kind, "reason": reason, **extra}


def api_ok(api, endpoint):
    value, error = api.request(endpoint)
    return value, error


def branch_has_protection_or_ruleset(api, repo, branch):
    encoded = quote(branch, safe="")
    protection, err = api_ok(api, f"repos/{repo}/branches/{encoded}/protection")
    if not err:
        return True, "branch protection"
    if "404" not in err:
        return None, "could not determine branch protection"
    rules, err = api_ok(api, f"repos/{repo}/rules/branches/{encoded}")
    if not err:
        return bool(rules), "matching repository ruleset" if rules else ""
    if "404" not in err:
        return None, "could not determine branch rulesets"
    return False, ""


def has_marker(api, repo, pr_number):
    comments, err = api.request(f"repos/{repo}/issues/{pr_number}/comments?per_page=100", paginate=True)
    if err or not isinstance(comments, list):
        return None
    return any(MARKER in str(comment.get("body", "")) for comment in comments if isinstance(comment, dict))


def associated_pr(branch, prs):
    matches = [pr for pr in prs if isinstance(pr, dict) and isinstance(pr.get("head"), dict) and pr["head"].get("ref") == branch]
    open_prs = [pr for pr in matches if pr.get("state") == "open"]
    if open_prs:
        return open_prs[0]
    merged = [pr for pr in matches if pr.get("merged_at")]
    if merged:
        return merged[0]
    closed = [pr for pr in matches if pr.get("state") == "closed"]
    return closed[0] if closed else None


def compare_ahead(api, repo, base, head):
    value, err = api_ok(api, f"repos/{repo}/compare/{quote(base, safe='')}...{quote(head, safe='')}")
    if err or not isinstance(value, dict) or not isinstance(value.get("ahead_by"), int):
        return None
    return value["ahead_by"]


def branch_commit_date(api, repo, sha):
    """Branch-list API payloads include only sha/url; fetch the dated commit."""
    commit, err = api_ok(api, f"repos/{repo}/commits/{sha}")
    if err or not isinstance(commit, dict):
        return None
    return stamp((((commit.get("commit") or {}).get("author") or {}).get("date")))


def classify(api, repo, default_branch, branch, prs, now):
    name = branch.get("name") if isinstance(branch, dict) else None
    sha = ((branch.get("commit") or {}).get("sha")) if isinstance(branch, dict) else None
    if not isinstance(name, str) or not isinstance(sha, str):
        return action(repo, name or "", "skipped", "branch metadata is incomplete")
    if name == default_branch or protected_name(name):
        return action(repo, name, "skipped", "protected branch name")
    commit_date = branch_commit_date(api, repo, sha)
    if not commit_date:
        return action(repo, name, "skipped", "branch tip could not be read")
    protected, why = branch_has_protection_or_ruleset(api, repo, name)
    if protected is None:
        return action(repo, name, "skipped", why)
    if protected:
        return action(repo, name, "skipped", why)
    age = now - commit_date
    if age < timedelta(days=14):
        return action(repo, name, "skipped", "commit is newer than 14 days")
    pr = associated_pr(name, prs)
    if pr and pr.get("state") == "open":
        if age >= timedelta(days=30):
            marked = has_marker(api, repo, pr.get("number"))
            if marked is None:
                return action(repo, name, "skipped", "could not inspect existing PR comments")
            return action(repo, name, "warn" if not marked else "skipped", "open PR is stale" if not marked else "stale warning already exists", pr=pr.get("number"))
        return action(repo, name, "skipped", "open PR is not stale", pr=pr.get("number"))
    ancestor = compare_ahead(api, repo, default_branch, sha)
    if ancestor is None:
        return action(repo, name, "skipped", "could not compare branch with default")
    if ancestor == 0:
        return action(repo, name, "delete", "branch tip is an ancestor of default", sha=sha)
    if pr and pr.get("merged_at"):
        merged_sha = pr.get("merge_commit_sha")
        after_merge = compare_ahead(api, repo, merged_sha, sha) if isinstance(merged_sha, str) else None
        if after_merge == 0:
            return action(repo, name, "delete", "merged PR has no branch commits after merge head", sha=sha, pr=pr.get("number"))
        return action(repo, name, "skipped", "merged PR branch has commits after merge head", pr=pr.get("number"))
    if age >= timedelta(days=90):
        return action(repo, name, "archive_delete", "closed-unmerged or no-PR branch is older than 90 days", sha=sha, pr=pr.get("number") if pr else None)
    return action(repo, name, "skipped", "closed-unmerged or no-PR branch is younger than 90 days", pr=pr.get("number") if pr else None)


def current_branch_sha(api, repo, branch):
    value, err = api_ok(api, f"repos/{repo}/git/ref/heads/{quote(branch, safe='')}")
    sha = ((value or {}).get("object") or {}).get("sha") if isinstance(value, dict) else None
    return sha if not err and isinstance(sha, str) else None


def execute(api, record, dry_run):
    if dry_run:
        record["action"] = "would_" + record["action"]
        return record
    repo, branch = record["repo"], record["branch"]
    if record["action"] == "warn":
        body = f"{MARKER}\nThis pull request's branch has had no commits for 30 days. This is an automated reminder only; the PR has not been modified or closed."
        _, err = api.request(f"repos/{repo}/issues/{record['pr']}/comments", "POST", {"body": body})
        record["action"] = "warned" if not err else "skipped"
        record["reason"] = record["reason"] if not err else "failed to create stale warning"
        return record
    if record["action"] == "delete":
        if current_branch_sha(api, repo, branch) != record["sha"]:
            record.update(action="skipped", reason="branch changed or could not be read before deletion")
            return record
        _, err = api.request(f"repos/{repo}/git/refs/heads/{quote(branch, safe='')}", "DELETE")
        record["action"] = "deleted" if not err else "skipped"
        record["reason"] = record["reason"] if not err else "branch deletion failed"
        return record
    if record["action"] == "archive_delete":
        if current_branch_sha(api, repo, branch) != record["sha"]:
            record.update(action="skipped", reason="branch changed or could not be read before archival")
            return record
        tag = "archive/" + branch
        _, err = api.request(f"repos/{repo}/git/refs", "POST", {"ref": "refs/tags/" + tag, "sha": record["sha"]})
        if err:
            record.update(action="skipped", reason="archive tag creation failed")
            return record
        verify, err = api_ok(api, f"repos/{repo}/git/ref/tags/{quote(tag, safe='')}")
        if err or not isinstance(verify, dict) or ((verify.get("object") or {}).get("sha") != record["sha"]):
            record.update(action="skipped", reason="archive tag verification failed")
            return record
        if current_branch_sha(api, repo, branch) != record["sha"]:
            record.update(action="skipped", reason="branch changed or could not be read before deletion")
            return record
        _, err = api.request(f"repos/{repo}/git/refs/heads/{quote(branch, safe='')}", "DELETE")
        record.update(action="archived_deleted" if not err else "skipped", reason=record["reason"] if not err else "branch deletion after archive failed", tag=tag)
    return record


def sweep_repo(api, repo, now, dry_run):
    metadata, err = api_ok(api, f"repos/{repo}")
    if err or not isinstance(metadata, dict) or not isinstance(metadata.get("default_branch"), str):
        return [action(repo, "", "skipped", "could not read repository metadata")]
    branches, err = api.request(f"repos/{repo}/branches?per_page=100", paginate=True)
    prs, pr_err = api.request(f"repos/{repo}/pulls?state=all&per_page=100", paginate=True)
    if err or pr_err or not isinstance(branches, list) or not isinstance(prs, list):
        return [action(repo, "", "skipped", "could not list branches or pull requests")]
    return [execute(api, classify(api, repo, metadata["default_branch"], branch, prs, now), dry_run) for branch in branches]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--org", default="qwickapps")
    parser.add_argument("--dry-run", choices=("true", "false"), default="true")
    parser.add_argument("--output", default="/tmp/weekly-branch-sweep.json")
    args = parser.parse_args()
    api, now, dry_run = GitHub(), datetime.now(timezone.utc), args.dry_run == "true"
    repos, err = api.request(f"orgs/{args.org}/repos?type=all&per_page=100", paginate=True)
    if err or not isinstance(repos, list):
        raise SystemExit("could not list organization repositories")
    records = []
    for item in repos:
        if isinstance(item, dict) and not item.get("archived") and isinstance(item.get("full_name"), str):
            records.extend(sweep_repo(api, item["full_name"], now, dry_run))
    report = {"org": args.org, "dry_run": dry_run, "run_date": now.isoformat(), "records": records}
    report["summary"] = {key: sum(row["action"] == key for row in records) for key in sorted({row["action"] for row in records})}
    Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["summary"], sort_keys=True))


if __name__ == "__main__":
    main()
