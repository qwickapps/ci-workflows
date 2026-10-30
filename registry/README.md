# Registry deploy preflight review

This record preserves the `NO_MATCH` result from the registry preflight
hostname-usage review. It is evidence about the current `ci-workflows` tree,
not a requirement to add a hostname input to registry operations.

## Preflight Hostname Usage: None Detected

Analysis snapshot: `2026-10-29T04:01:38+00:00` (UTC)

The upstream Coolify inventory analysis is recorded in
[`analysis.md`](analysis.md). It inspected 32 applications, 2 databases, and
5 services. The scanner found 10 matching `TS_HOSTNAME` environment entries
across 5 application resources. Those entries represent five distinct,
non-canonical scanner matches; they do not claim a canonical registry
hostname.

Result: `NO_MATCH`.

The snapshot found zero canonical-hostname conflicts and zero QwickWay-image
matches across the inspected resources. This result is deliberately scoped to
the recorded Coolify inventory snapshot; it does not assert that
`TS_HOSTNAME` is unused elsewhere in `ci-workflows` or in runtime
configuration.

## Operational implication

Registry preflight behavior has no detected canonical-hostname claimant or
QwickWay image reference to configure from this snapshot. A future inventory
scan that finds either condition should update this record and add the
corresponding preflight coverage.
