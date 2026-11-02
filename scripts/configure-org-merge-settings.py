#!/usr/bin/env python3
"""Idempotently apply the approved qwickapps merge settings and read them back."""
import argparse
import json
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

class GitHub:
    def request(self, endpoint, method="GET", fields=None, paginate=False):
        args = ["gh", "api", endpoint, "-X", method]
        if paginate: args.append("--paginate")
        for key, value in (fields or {}).items(): args += ["-F", f"{key}={str(value).lower() if isinstance(value, bool) else value}"]
        done = subprocess.run(args, capture_output=True, text=True)
        if done.returncode: return None, done.stderr.strip()
        text = done.stdout.strip()
        if not text: return None, ""
        try:
            if not paginate: return json.loads(text), ""
            decoder, offset, rows = json.JSONDecoder(), 0, []
            while offset < len(text):
                rest = text[offset:].lstrip()
                if not rest: break
                offset += len(text[offset:]) - len(rest)
                value, used = decoder.raw_decode(rest); offset += used
                if not isinstance(value, list): return None, "non-list paginated response"
                rows.extend(value)
            return rows, ""
        except json.JSONDecodeError as exc: return None, str(exc)

def has_recent_true_merge(api, repo, default_branch, cutoff):
    prs, err = api.request(f"repos/{repo}/pulls?state=closed&per_page=100", paginate=True)
    if err or not isinstance(prs, list): return None
    for pr in prs:
        if ((pr.get("base") or {}).get("ref")) != default_branch: continue
        merged_at, sha = pr.get("merged_at"), pr.get("merge_commit_sha")
        if not isinstance(merged_at, str) or not isinstance(sha, str):
            continue
        try: merged = datetime.fromisoformat(merged_at.replace("Z", "+00:00"))
        except (TypeError, ValueError): continue
        if merged < cutoff or not isinstance(sha, str): continue
        commit, err = api.request(f"repos/{repo}/git/commits/{sha}")
        if err or not isinstance(commit, dict): return None
        if isinstance(commit.get("parents"), list) and len(commit["parents"]) == 2: return pr.get("number")
    return False

def public_settings(repo):
    return {key: repo.get(key) for key in ("delete_branch_on_merge", "allow_squash_merge", "allow_merge_commit", "allow_rebase_merge")}

def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--org", default="qwickapps"); parser.add_argument("--output", required=True); args = parser.parse_args()
    api, cutoff = GitHub(), datetime.now(timezone.utc) - timedelta(days=90)
    repos, err = api.request(f"orgs/{args.org}/repos?type=all&per_page=100", paginate=True)
    if err or not isinstance(repos, list): raise SystemExit("could not list organization repositories")
    report = {"org": args.org, "cutoff": cutoff.isoformat(), "repos": []}
    for listed in repos:
        if listed.get("archived") or not isinstance(listed.get("full_name"), str): continue
        name = listed["full_name"]
        before, err = api.request(f"repos/{name}")
        if err or not isinstance(before, dict):
            report["repos"].append({"repo": name, "error": "could not read before settings"}); continue
        exception = "explicit faabzi exception" if name == "qwickapps/faabzi" else None
        if not exception:
            number = has_recent_true_merge(api, name, before.get("default_branch"), cutoff) if isinstance(before.get("default_branch"), str) else None
            if number is None:
                report["repos"].append({"repo": name, "before": public_settings(before), "error": "could not determine 90-day merge-commit exception"}); continue
            if number: exception = f"PR #{number} merged with a two-parent commit within 90 days"
        desired = {"delete_branch_on_merge": True, "allow_squash_merge": True, "allow_merge_commit": bool(exception)}
        _, err = api.request(f"repos/{name}", "PATCH", desired)
        after, read_err = api.request(f"repos/{name}")
        entry = {"repo": name, "before": public_settings(before), "desired": desired, "exception": exception, "after": public_settings(after) if isinstance(after, dict) else None}
        if err or read_err or entry["after"] is None: entry["error"] = "PATCH or readback failed"
        elif any(entry["after"].get(k) != v for k, v in desired.items()): entry["error"] = "readback did not match desired settings"
        report["repos"].append(entry)
    Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
    failures = sum("error" in row for row in report["repos"])
    print(f"repos={len(report['repos'])} failures={failures}")
    if failures: raise SystemExit(1)
if __name__ == "__main__": main()
