#!/usr/bin/env python3
"""org-branch-hygiene-summary.py — Write job summary from hygiene report JSON."""
import json, sys, os

report_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/hygiene-report.json"
summary_path = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("GITHUB_STEP_SUMMARY", "/dev/stdout")

if not os.path.exists(report_path):
    print("No report file found at", report_path)
    sys.exit(0)

with open(report_path) as f:
    r = json.load(f)

with open(summary_path, "a") as out:
    out.write("# Org-Wide Branch Hygiene Report\n\n")
    out.write(f"**Run date:** {r.get('run_date', 'unknown')}  \n")
    out.write(f"**Dry run:** {r.get('dry_run', False)}  \n")
    out.write(f"**Repos scanned:** {r.get('repos_scanned', 0)}  \n")
    out.write(f"**Branches scanned:** {r.get('branches_scanned', 0)}  \n\n")
    out.write("---\n\n")

    deleted = r.get("deleted", [])
    out.write(f"## Deleted (provably merged into default): {len(deleted)}\n\n")
    out.write("> Safety predicate: `compare/{default}...{branch}` returned `behind` or `identical` ")
    out.write("(zero unmerged commits). Open PR heads were never touched.\n\n")
    if deleted:
        by_repo = {}
        for item in deleted:
            by_repo.setdefault(item["repo"], []).append(item["branch"])
        out.write("| Repo | Branches Deleted |\n|------|------------------|\n")
        for repo, branches in sorted(by_repo.items(), key=lambda x: -len(x[1])):
            out.write(f"| `{repo}` | {', '.join(f'`{b}`' for b in branches)} |\n")
    else:
        out.write("_None — no provably-merged branches found._\n")
    out.write("\n")

    flagged = r.get("flagged_for_review", [])
    stale_days = r.get("stale_days", 21)
    out.write(f"## Flagged for human review (>{stale_days}d old, unmerged — NOT deleted): {len(flagged)}\n\n")
    out.write("> These branches have commits not in the default branch. They are listed here for review only.\n\n")
    if flagged:
        out.write("| Repo | Branch | Last Commit | Days Old | Ahead | Compare Status |\n")
        out.write("|------|--------|-------------|----------|-------|----------------|\n")
        for item in sorted(flagged, key=lambda x: x.get("days_old", 0), reverse=True)[:60]:
            out.write(
                f"| `{item['repo']}` | `{item['branch']}` | {item.get('last_commit','?')} "
                f"| {item.get('days_old','?')} | {item.get('ahead','?')} | {item.get('status','?')} |\n"
            )
        if len(flagged) > 60:
            out.write(f"\n_...and {len(flagged)-60} more — see the full report artifact._\n")
    else:
        out.write("_None._\n")
    out.write("\n")

    stale_prs = r.get("stale_prs", [])
    out.write(f"## Stale open PRs (>{stale_days}d no update — NOT closed): {len(stale_prs)}\n\n")
    if stale_prs:
        out.write("| Repo | PR | Days Stale | Author | Title |\n")
        out.write("|------|-----|------------|--------|-------|\n")
        for pr in sorted(stale_prs, key=lambda x: -x.get("days_stale", 0)):
            out.write(
                f"| `{pr['repo']}` | #{pr['number']} | {pr['days_stale']}d "
                f"| {pr.get('author','')} | {pr.get('title','')[:55]} |\n"
            )
    else:
        out.write("_None._\n")

print(f"Summary written to {summary_path}")
