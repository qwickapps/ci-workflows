# Coolify registry hostname analysis

Snapshot generated: `2026-10-29T04:01:38+00:00` (UTC)

## Scope

The inventory scan inspected the Coolify resources available in the snapshot:

- 32 applications
- 2 databases
- 5 services

It compared resource images and matching environment data with the canonical
registry-hostname and QwickWay-image criteria used by the deploy preflight.

## Findings

- 10 `TS_HOSTNAME` environment entries matched across 5 application resources.
- The matches represented five distinct, non-canonical scanner values.
- Canonical registry-hostname conflicts: 0.
- QwickWay-image matches: 0.

Result: `NO_MATCH`.

The observed `TS_HOSTNAME` values are scanner matches only; none is a
canonical registry hostname claimant. This is a point-in-time inventory result
and does not replace the deploy preflight's live, fail-closed inspection.
