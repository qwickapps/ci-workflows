# merge-gate: status check + post-merge bypass audit (design S2)

Design: `Projects/merge-gates-design-2026-11-27.md` (read sections 2-7).
This document covers only step **S2** of that rollout.

## What this ships

Two reusable workflows:

- `.github/workflows/merge-gate.yml` — called from a consumer repo's
  `on: pull_request` workflow. Computes the gates it can check without the
  merge-gate CLI or Kanban DB access (G1 CI green, G5 secret scan via
  gitleaks, G6 linked-to-work, G7 blast radius, G8 protected paths
  (advisory), G9 migration flag), posts a `merge-gate` commit status at the
  PR's exact head SHA, and upserts a PR comment with the full per-gate
  report.
- `.github/workflows/merge-gate-audit.yml` — called from a consumer repo's
  `on: push: branches: [main]` workflow. For every commit that landed on
  main, checks for audit evidence (a `merge-gate/audit` commit status, or a
  matching line in `.merge-gate/audit.jsonl` at that commit) and opens a P0
  Kanban card (`hermes kanban create`, idempotent by commit SHA; falls back
  to a GitHub issue labeled `P0` if the `hermes` CLI isn't on PATH) when
  neither is found.

Both jobs run on the `[self-hosted, macmini, macmini-fast]` pool regardless
of which repo calls them (same convention as `validation-evidence-gate.yml`)
— choco's runners are repo-scoped to aos/ci-workflows and never serve
callers. That also means every bypass card created by the audit workflow
lands on macmini's own Kanban board, not the calling repo's.

## Known, deliberate gap: this will flag every merge right now

Design step **S1** (the `merge-gate` CLI that runs G1-G9 and writes the
`merge-gate/audit` status / `.merge-gate/audit.jsonl` line on a gated merge)
has not been built as of this PR. Step **S3** (the guard rule that forces
every merge through S1) has not landed either, and explicitly needs its own
recorded SDLC exception (owner: @raaj, 2026-11-27 directive; Prime approves
only that one change — see design section 6-7).

Until S1 ships and is adopted, **no merge anywhere produces the evidence
this audit job looks for**, so it will open a P0 card for every single merge
on every repo that has adopted `merge-gate-audit.yml`. That is the correct,
honest signal for this phase — it is literally true that nothing is routing
through merge-gate yet — not a bug. Expect noise until S1 lands; don't
suppress or weaken the audit job to quiet it down.

## What is NOT verified by `merge-gate.yml`

G2 (independent Kanban-recorded review), G3 (tests-present) and G4 (design
conformance) need either the S1 CLI or a read path into the Kanban DB that
this reusable workflow does not have. The status/comment explicitly reports
these as "not evaluated here." A green `merge-gate` status is **not** full
G1-G9 coverage — don't read it that way, and don't let a future change
silently start claiming otherwise without actually implementing the check.

## Why this can't block a merge

qwickapps is on the GitHub Free plan. Private repos return 403 on both
`rulesets` and `branches/main/protection` ("Upgrade to GitHub Pro or make
this repository public"), `allow_auto_merge` is `false`, and there is no
required-checks mechanism. This status is visible, not blocking (design
section 4): "a bypass leaves a visible red mark." The only way to make it a
hard control is GitHub Team (~$4/user/month) or going public — @raaj's call,
tracked in the design doc, out of scope here.

## Rollout

Caller snippets were added in this PR's wave to `ci-workflows` itself. A
full org rollout touches `.github/workflows/` in every repo with open PRs
(37 repos as of 2026-11-27) — see the follow-up Kanban card for the staged
rollout to the rest; spraying workflow-file changes across ~30 product
repos with no Hermes/aos context in a single pass was judged out of
proportion for this task's blast radius, and `.github/workflows/` is itself
a G8 protected path in the design's own terms.

### Caller example

```yaml
# .github/workflows/merge-gate.yml in a consumer repo
name: merge-gate
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
jobs:
  status:
    uses: qwickapps/ci-workflows/.github/workflows/merge-gate.yml@main

---
# .github/workflows/merge-gate-audit.yml in a consumer repo
name: merge-gate-audit
on:
  push:
    branches: [main]
jobs:
  audit:
    uses: qwickapps/ci-workflows/.github/workflows/merge-gate-audit.yml@main
```

## Tests

`scripts/tests/merge-gate-status.test.sh` and
`scripts/tests/merge-gate-audit.test.sh` exercise the pure decision logic
(blast radius, protected paths, migration flag, link-to-work, audit-evidence
matching) outside of GitHub Actions. They mirror the workflow's embedded
bash — update both together.
