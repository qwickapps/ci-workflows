#!/usr/bin/env python3
"""Write a conservative closed-unmerged-PR branch-cleanup report to a job summary."""
import json
import os
import sys

report_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/hygiene-report.json"
summary_path = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("GITHUB_STEP_SUMMARY", "/dev/stdout")

if not os.path.exists(report_path):
    print(f"No report file found at {report_path}")
    raise SystemExit(0)

with open(report_path) as source:
    report = json.load(source)
records = report.get("records", [])
summary = report.get("summary", {})

with open(summary_path, "a") as out:
    out.write("# Merged PR Branch Cleanup\n\n")
    out.write(f"**Mode:** {'targeted enforcement' if report.get('enforce') else 'audit only'}  \n")
    out.write(f"**Deleted:** {summary.get('deleted', 0)}  \n")
    out.write(f"**Candidates (not deleted):** {summary.get('candidate', 0)}  \n")
    out.write(f"**Skipped:** {summary.get('skipped', 0)}\n\n")
    out.write("> A deletion requires one closed, unmerged same-repository PR; a matching current head SHA; "
              "a non-default unprotected branch; no open PR head; no allowlist match; and a second SHA check immediately before deletion.\n\n")
    out.write("| Repository | PR | Branch | Result | Reason |\n")
    out.write("|---|---:|---|---|---|\n")
    for item in records[:100]:
        out.write(f"| `{item.get('repo', '')}` | {item.get('pr', '') or ''} | `{item.get('branch', '')}` | {item.get('action', '')} | {item.get('reason', '')} |\n")
    if len(records) > 100:
        out.write(f"\n_Only the first 100 of {len(records)} records are shown; see the artifact for the complete audit._\n")

print(f"Summary written to {summary_path}")
