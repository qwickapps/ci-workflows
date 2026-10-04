# Promotion consolidation: inventory and migration plan

Status: **proposal, nothing built** (ci-workflows#199). This document records
the inventory, the decision to make, and the migration order. It changes no
workflow behavior.

Related: qwickapps/memories#144, qwickapps/memories#145,
qwickapps/documents#44, ci-workflows#198.

## Problem

`deploy-app.yml` is the one shared, reusable deploy path in the org. Live and
stable promotion is not: each repo either vendors its own
`promote-to-live.yml`/`promote-to-stable.yml` plus a `swap-instances.sh`, or
writes the logic inline. A fix in one copy (memories#145, source/target
CapRover host split) reaches no other copy.

## Inventory

### Other repos (from ci-workflows#199, not re-verified here)

This session can only read `qwickapps/ci-workflows`, so the rows below are
carried over from the issue as written. Anything marked "unverified" is still
unverified.

| Repo | Promote mechanism | Vendors `swap-instances.sh` | Called by a workflow | Cross-host CapRover-cred bug |
|---|---|---|---|---|
| memories | own `promote-to-live.yml`/`promote-to-stable.yml` + script | yes | yes | fixed (memories#145) |
| documents | own `promote-to-live.yml` + script | yes | yes | unverified (documents#44) |
| environments | own `promote-to-live.yml` + script | yes | yes | unverified |
| forge | none | yes | no | dead code |
| mcp | own `deploy.yml` stage machinery | yes | no | dead code |
| hermind | none | yes | no | dead code |
| backup | own promote workflows, custom scripts | no | n/a | n/a (prod-only, single host) |
| billing | own `promote-to-live.yml`, fully inline | no | n/a | not assessed |

### ci-workflows (verified against `main` at 733d8b5)

| File | What it is | Findings |
|---|---|---|
| `.github/workflows/promote-to-live.yml` | reusable (`workflow_call`), unused by any caller per #199 | Runs the **caller's** `.github/scripts/swap-instances.sh`, so the logic is still vendored. Takes one `caprover_url`/password per environment, with no source/target split. That is the same shape memories#145 fixed. `environment: dev` still resolves `OCI_DEV_CAPROVER_URL`, a host that was retired on 2026-09-27 (see below). Health URL hardcodes tailnet port `:8080`. |
| `.github/workflows/promote-to-stable.yml` | reusable, unused | Runs the caller's `.github/scripts/deploy-from-ghcr.sh` and also `scripts/rescope-ts-hostname.sh` and `scripts/verify-multiarch-manifest.sh` **relative to the caller's checkout**. These two scripts exist only in ci-workflows, so any external caller would fail at those steps. That is consistent with nobody having called it. |
| `.github/workflows/promote.yml` | reusable, header says `DEPRECATED` | Points readers at `deploy-app.yml` stages. |
| `.github/workflows/deploy-app.yml` | the canonical reusable deploy | Already models `build`/`uat`/`live`/`stable` through one `stage` input, with a fail-closed stage-to-host gate (`resolve-stage`, ci-workflows#153/#187), `health_path` and `container_port` as inputs, provenance and retag-forward (never rebuild) for non-build stages, live routing via qwickway, and an optional stable approval gate (aos#193). |
| `README.md` "Manual Promotion" | docs | Still tells callers to use `promote-to-live.yml@main`. |

### Facts that change the picture in #199

1. **Host topology has collapsed onto a single host.** Since 2026-09-27, the
   oci-dev CapRover has been scaled to zero and the host has been reused as
   gateway-2. `deploy-app.yml` now maps **every** stage, build included, to
   `captain.app.qwickforge.com` (oci-main) and renamed the build slot from
   `<app>-build` to `<app>-dev`. On the `deploy-app.yml` path, the cross-host
   build→live bug class therefore cannot happen right now. The single-host
   bug can still bite through any vendored promote path that hardcodes
   oci-dev for the source slot, or that sends oci-main creds to an oci-dev
   URL. `deploy-app.yml` keeps `CANONICAL_DEV_HOST` and `CANONICAL_MAIN_HOST`
   as separate constants so the hosts can be split again later. Any shared
   promote path must still carry an explicit source/target host split for
   that day.
2. **`deploy-app.yml` is not free of vendored scripts either.** It runs these
   from the caller's `.github/scripts/`: `deploy-from-ghcr.sh`,
   `validate-deployment-health.sh`, `deep-health-check.sh`,
   `setup-qwickway-route.sh`, `build-workspace-package.sh`,
   `resolve-docker-endpoint.sh`, and `check-migrations.sh`/`run-migrations.sh`.
   ci-workflows already has a central, tested `scripts/setup-qwickway-route.sh`
   (three test workflows cover it), but `deploy-app.yml` runs the caller's
   copy, not that one. So the drift problem #199 describes for
   `swap-instances.sh` also exists for every script `deploy-app.yml` runs.
3. **ci-workflows#198 needs re-triage before it blocks anything.** The job
   names it cites (`build-once`, `resolve-image`) do not exist in
   `deploy-app.yml` on `main`, and `deploy-app.yml` has no
   `workflow_dispatch` trigger of its own. The skip-cascade is most likely in
   memories' own `deploy.yml` wrapper, which is outside this repo. In
   `deploy-app.yml`, the jobs downstream of the conditional `build` job
   already guard with `always() && needs.X.result == 'success'`.

## Decision: option 1 (deploy-app stages) or option 2 (fix the promote family)

**Recommendation: option 1. Make `deploy-app.yml` `stage: live` and
`stage: stable` the only promotion path, and retire `promote-to-live.yml`,
`promote-to-stable.yml` and `promote.yml`.** Fold option 2's central-script
idea into it as phase 0, because finding 2 shows option 1 has the same
vendoring problem.

Why not option 2:

- The promote family has no callers today, so "fixing" it means building a
  second shared path and migrating repos onto it. That is the same migration
  cost as option 1, and it leaves two paths in place.
- It duplicates what `deploy-app.yml` already enforces: the stage/host gate,
  provenance, retag-forward, the stable approval gate, and qwickway routing.
  Every gate would have to be implemented twice and kept in sync, which
  recreates the drift we are trying to remove.
- `promote-to-stable.yml` is already broken for external callers (it runs
  `scripts/*` from the caller's checkout).

Option 2's real merit is speed. If a repo needs a safe manual live promotion
before its migration lands, the stopgap is to dispatch its existing
`deploy-app.yml` caller with `stage: live`, not to revive the promote family.

## Migration plan

### Phase 0: centralize the scripts `deploy-app.yml` runs (ci-workflows only)

For each caller-vendored script listed in finding 2, in order of risk
(`deploy-from-ghcr.sh` and `setup-qwickway-route.sh` first):

1. Land the canonical copy in `scripts/` with a `scripts/tests/*.test.sh`
   suite and a test workflow. For `setup-qwickway-route.sh` both already
   exist.
2. Switch `deploy-app.yml` to `.ci-workflows/scripts/<name>.sh`. The
   `.ci-workflows` checkout already exists in the relevant jobs. Make the
   switch fail-closed: no silent fallback to the caller's copy, otherwise a
   stale vendored copy keeps running unnoticed.
3. Treat caller-specific steps (`build-workspace-package.sh`, migrations) as
   explicit, optional caller hooks rather than implicit file lookups.

Exit criterion: `deploy-app.yml` runs no `.github/scripts/*` except declared
caller hooks.

### Phase 1: close the remaining gaps for live/stable through deploy-app

- **Notification:** add an optional Telegram notify step, enabled when
  `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` are passed, so documents and
  billing lose nothing by migrating.
- **Runtime drift check:** the promote family runs
  `check-runtime-drift.sh` before promoting. `deploy-app.yml` does not run it
  today. Add it as an opt-in input for `live`/`stable`.
- **Health URL:** the tailnet fallback in `resolve-stage` hardcodes `:8080`,
  while memories validates on `:7009`. Derive the fallback port from
  `container_port`, or require callers to pass the URL explicitly.
- **Manual dispatch:** document the caller pattern (a `workflow_dispatch`
  wrapper with `stage` and `image_ref` inputs that calls `deploy-app.yml`),
  and add a contract test for "dispatch with explicit `image_ref` at
  `stage: live` does not skip the deploy". This covers the scenario #198
  worries about, whatever the triage result.
- **Prod-only callers (backup):** confirm that a caller can use only
  `stage: live`/`stable` without ever deploying `build`/`uat`. The provenance
  gate currently requires a prior-stage tag. Decide whether backup is
  exempted explicitly or brought onto the 4-stage model.

### Phase 2: migrate repos (one PR per repo, in this order)

| # | Repo | Work | Pre-req / proof |
|---|---|---|---|
| 1 | memories | Replace `promote-to-live.yml`/`promote-to-stable.yml` with `deploy-app.yml` `stage: live`/`stable` dispatch, delete vendored `swap-instances.sh` | One real live and one real stable promotion through deploy-app, with health and e2e evidence. Re-check that memories#145's assumption (build on oci-dev) still matches the post-2026-09-27 topology. |
| 2 | documents | Same | Answer documents#44 (real slot topology) first. |
| 3 | environments | Same | Same open topology question as documents. |
| 4 | forge, mcp, hermind | Delete dead `swap-instances.sh` copies | None. Removing them prevents someone later wiring a new caller to a stale, unfixed copy. |
| 5 | billing | Replace the inline promote with deploy-app stages | Read the inline logic first. It is currently `blue-green-exempt`-scoped by the guard. |
| 6 | backup | Per the phase 1 prod-only decision | Lowest shared-bug payoff. |

### Phase 3: retire the promote family (ci-workflows)

Only after phase 2 rows 1–3 are done and a code search shows no `uses:` of
the files below:

- Delete `promote-to-live.yml`, `promote-to-stable.yml`, `promote.yml`.
- Replace the README "Manual Promotion" section with the deploy-app dispatch
  pattern.
- Consider extending `blue-green-workflow-guard.sh` so a caller workflow that
  runs `swap-instances.sh` fails the guard even with an exemption comment.

## Open questions for the owner

1. Do you agree with option 1 plus phase 0 over option 2?
2. Should ci-workflows#198 be re-triaged against memories' `deploy.yml`, given
   the job names it cites are not in `deploy-app.yml`?
3. Backup: should it be exempted from the 4-stage model, or brought onto it?
