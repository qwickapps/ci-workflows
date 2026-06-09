#!/usr/bin/env python3
"""org-branch-hygiene.py — Org-wide branch and PR hygiene sweeper.

Safety predicate:
  A branch is PROVABLY MERGED (safe to delete) if and only if:
    GET /repos/{org}/{repo}/compare/{default}...{branch}
    returns status == "behind" OR status == "identical"
  (i.e. the branch has ZERO commits that are not already in the default branch)

  We additionally skip:
    - The repo's default branch
    - Any branch whose name is in PROTECTED_NAMES
    - Any branch that is the HEAD of an open PR (never delete open PR branches)

  When in doubt — any other compare status — we FLAG, never delete.
"""

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone, timedelta

PROTECTED_NAMES = {
    "main", "master", "dev", "staging", "production", "develop",
    "v5-stable", "docs/readme", "aal-1-bash-intercept",
}


def gh(endpoint, method="GET", accept_not_found=False):
    """Call `gh api <endpoint>`, return parsed JSON or None on 404."""
    r = subprocess.run(
        ["gh", "api", "--paginate", endpoint],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        if accept_not_found and "404" in r.stderr:
            return None
        return None
    try:
        # gh --paginate can emit multiple JSON arrays; merge them
        text = r.stdout.strip()
        if text.startswith("["):
            # Could be multiple arrays concatenated by --paginate
            merged = []
            decoder = json.JSONDecoder()
            pos = 0
            while pos < len(text):
                text_from = text[pos:].lstrip()
                if not text_from:
                    break
                obj, idx = decoder.raw_decode(text_from)
                pos += len(text) - len(text_from) + idx
                if isinstance(obj, list):
                    merged.extend(obj)
                else:
                    merged.append(obj)
            return merged
        return json.loads(text)
    except Exception:
        return None


def gh_single(endpoint, jq_filter=None):
    """Call gh api without --paginate, optionally with --jq."""
    args = ["gh", "api", endpoint]
    if jq_filter:
        args += ["--jq", jq_filter]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        return None
    text = r.stdout.strip()
    if not text:
        return None
    if jq_filter:
        return text  # raw string output from jq
    try:
        return json.loads(text)
    except Exception:
        return text


def compare_branch(org, repo, default, branch):
    """Return (status, ahead_by) or (None, None) on error."""
    r = subprocess.run(
        ["gh", "api", f"repos/{org}/{repo}/compare/{default}...{branch}",
         "--jq", "{status:.status,ahead:.ahead_by}"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return None, None
    try:
        data = json.loads(r.stdout.strip())
        return data.get("status"), data.get("ahead", -1)
    except Exception:
        return None, None


def get_open_pr_heads(org, repo):
    """Return set of branch names that are heads of open PRs."""
    prs = gh(f"repos/{org}/{repo}/pulls?state=open&per_page=100")
    if not prs:
        return set()
    return {pr["head"]["ref"] for pr in prs if isinstance(pr, dict)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--org", default="qwickapps")
    parser.add_argument("--stale-days", type=int, default=21)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--output", default="/tmp/hygiene-report.json")
    args = parser.parse_args()

    org = args.org
    stale_days = args.stale_days
    dry_run = args.dry_run or os.environ.get("DRY_RUN", "false").lower() == "true"
    cutoff = datetime.now(timezone.utc) - timedelta(days=stale_days)

    print(f"[hygiene] org={org} stale_days={stale_days} dry_run={dry_run}")

    # --- Enumerate repos ---
    repos_raw = gh(f"orgs/{org}/repos?type=all&per_page=100")
    if not repos_raw:
        print("[hygiene] ERROR: could not list repos", file=sys.stderr)
        sys.exit(1)

    active_repos = []
    for r in repos_raw:
        if r.get("archived"):
            continue
        name = r.get("name", "")
        default = r.get("default_branch", "")
        if name and default:
            active_repos.append((name, default))

    print(f"[hygiene] {len(active_repos)} active repos")

    deleted = []
    flagged_for_review = []
    stale_prs = []
    branches_scanned = 0

    for repo_name, default_branch in active_repos:
        # Get all open PR heads (to never delete)
        open_heads = get_open_pr_heads(org, repo_name)

        # Get all branches
        branches_raw = gh(f"repos/{org}/{repo_name}/branches?per_page=100")
        if not branches_raw:
            continue

        for br_obj in branches_raw:
            if not isinstance(br_obj, dict):
                continue
            branch = br_obj.get("name", "")
            if not branch:
                continue
            if branch == default_branch:
                continue
            if branch in PROTECTED_NAMES:
                continue
            if branch in open_heads:
                continue

            branches_scanned += 1

            # --- Safety predicate ---
            cmp_status, ahead_by = compare_branch(org, repo_name, default_branch, branch)

            if cmp_status in ("behind", "identical"):
                # PROVABLY MERGED — safe to delete
                if not dry_run:
                    del_r = subprocess.run(
                        ["gh", "api", f"repos/{org}/{repo_name}/git/refs/heads/{branch}",
                         "-X", "DELETE"],
                        capture_output=True, text=True,
                    )
                    success = del_r.returncode == 0
                else:
                    success = True  # dry run

                deleted.append({
                    "repo": repo_name,
                    "branch": branch,
                    "default": default_branch,
                    "status": cmp_status,
                    "dry_run": dry_run,
                    "deleted": success,
                })
                verb = "[DRY-RUN would delete]" if dry_run else "[DELETED]"
                print(f"  {verb} {repo_name}/{branch} (compare={cmp_status})")
            else:
                # Check last commit date for staleness
                last_commit_r = subprocess.run(
                    ["gh", "api",
                     f"repos/{org}/{repo_name}/commits?sha={branch}&per_page=1",
                     "--jq", ".[0].commit.committer.date"],
                    capture_output=True, text=True,
                )
                last_date_str = last_commit_r.stdout.strip().strip('"')
                try:
                    last_date = datetime.fromisoformat(last_date_str.replace("Z", "+00:00"))
                    days_old = (datetime.now(timezone.utc) - last_date).days
                    last_date_short = last_date_str[:10]
                except Exception:
                    days_old = 0
                    last_date_short = "unknown"

                if days_old >= stale_days:
                    flagged_for_review.append({
                        "repo": repo_name,
                        "branch": branch,
                        "default": default_branch,
                        "status": cmp_status,
                        "ahead": ahead_by,
                        "last_commit": last_date_short,
                        "days_old": days_old,
                    })

        # --- Stale open PRs ---
        prs_raw = gh(f"repos/{org}/{repo_name}/pulls?state=open&per_page=100")
        if prs_raw:
            for pr in prs_raw:
                if not isinstance(pr, dict):
                    continue
                updated_str = pr.get("updated_at", "")
                try:
                    updated = datetime.fromisoformat(updated_str.replace("Z", "+00:00"))
                    if updated < cutoff:
                        days_stale = (datetime.now(timezone.utc) - updated).days
                        stale_prs.append({
                            "repo": repo_name,
                            "number": pr["number"],
                            "title": pr.get("title", "")[:80],
                            "author": pr.get("user", {}).get("login", ""),
                            "head": pr.get("head", {}).get("ref", ""),
                            "days_stale": days_stale,
                            "updated_at": updated_str[:10],
                        })
                except Exception:
                    pass

    # --- Write report ---
    report = {
        "run_date": datetime.now(timezone.utc).isoformat(),
        "org": org,
        "dry_run": dry_run,
        "stale_days": stale_days,
        "repos_scanned": len(active_repos),
        "branches_scanned": branches_scanned,
        "deleted": deleted,
        "flagged_for_review": flagged_for_review,
        "stale_prs": stale_prs,
        "summary": {
            "deleted_count": len(deleted),
            "flagged_count": len(flagged_for_review),
            "stale_pr_count": len(stale_prs),
        },
    }

    with open(args.output, "w") as f:
        json.dump(report, f, indent=2)

    print(f"\n[hygiene] SUMMARY: deleted={len(deleted)} flagged={len(flagged_for_review)} stale_prs={len(stale_prs)}")
    print(f"[hygiene] Report written to {args.output}")


if __name__ == "__main__":
    main()
