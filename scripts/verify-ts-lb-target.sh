#!/usr/bin/env bash
set -euo pipefail

# verify-ts-lb-target.sh — Deploy-pipeline guard (qwickapps/infrastructure#101).
#
# Fails the deploy if, post-promotion, the LB/qwickway target for this service
# does not structurally resolve to the node that was JUST deployed.
#
# Root cause this guards against (infra#101): qwickway's TARGET_APP is often a
# bare Tailscale MagicDNS hostname (e.g. http://qwickapps-mcp-build.<tailnet>.ts.net).
# That hostname is resolved by the OS/container DNS resolver against whatever
# the Tailscale coordinator currently maps it to. When duplicate/corpse
# registrations exist for the same logical service, that mapping can point at
# a dead node while the live container holds a numeric-suffixed name
# (qwickapps-mcp-build-3) — the deploy reports success, the container is
# healthy, but traffic goes to a corpse. This script makes "the LB cannot
# resolve to a dead node" a checked, structural property of every deploy
# instead of an assumption:
#
#   1. Query the Tailscale Admin API for every device matching the canonical
#      hostname (exact, or a "-N" numeric-suffix variant — the same pattern
#      qwick-ts-entrypoint uses to find its own stale siblings).
#   2. Require EXACTLY ONE of those devices to currently be connected
#      (connectedToControl=true, authorized=true). Zero -> nothing live to
#      route to. More than one -> the identity is ambiguous and the LB target
#      is not structurally guaranteed, regardless of which one DNS currently
#      happens to prefer.
#   3. Require that device's hostname to be the EXACT canonical name (no "-N"
#      suffix) — a live device sitting on a suffixed name means the canonical
#      slot was not reclaimed and the LB may be pointed at something else.
#   4. Require that device's `created` timestamp to be at or after this
#      deploy's start time (minus a small grace window) — proves the live
#      registration was made BY THIS deploy, not a leftover from a previous
#      one that happens to still be connected. Skippable with
#      --skip-freshness-check (see below) when CANONICAL_HOSTNAME is not the
#      node this deploy run itself produced.
#   5. Optionally cross-check qwickway's own /gateway/status: the backend URL
#      this deploy just configured must be reported healthy and active there.
#
# --skip-freshness-check (ci-workflows#189): rule 4 assumes CANONICAL_HOSTNAME
# is the node THIS run just deployed, so a stale `created` timestamp means a
# leftover corpse. That assumption doesn't hold when this script is used to
# check a DIFFERENT, independently-deployed service as a fallback-health
# sanity check (e.g. deploy-app.yml's live-stage call checks the stable
# slot's device, not live's own) — a long-lived, persistent-identity service
# being checked from an unrelated run is EXPECTED to have an old `created`
# timestamp; that is not evidence of staleness there. Pass this flag to skip
# rule 4 and rely on rules 1-3 alone (exactly one connected, authorized,
# correctly-named device) as sufficient proof of a real, unambiguous,
# currently-live backend. --deploy-start-epoch becomes optional when this
# flag is set (rule 4 is the only rule that uses it).
#
# Usage:
#   verify-ts-lb-target.sh \
#     --ts-api-key KEY \
#     --canonical-hostname qwickapps-mcp-build \
#     --deploy-start-epoch 1755500000 \
#     [--tailnet -] \
#     [--grace-seconds 120] \
#     [--skip-freshness-check] \
#     [--gateway-status-url https://qwickapps-mcp.app.qwickforge.com/gateway/status] \
#     [--expect-target-url http://qwickapps-mcp-build.taile324e7.ts.net:8080]
#
# Exit codes: 0 = LB target verified live (and fresh, unless
# --skip-freshness-check). 1 = guard failed (deploy must be treated as
# failed even if the container itself is healthy).

# select_live_target DEVICES_JSON CANONICAL_HOSTNAME
#
# Pure filter, factored out (and defined before arg-parsing/main so it can be
# `source`d) so it can be unit-tested against fixture JSON without hitting the
# real Tailscale API (see scripts/tests/verify-ts-lb-target.test.sh).
#
# Prints one of:
#   OK <hostname> <id> <created>          — exactly one live, canonical-named match
#   FAIL_NONE_LIVE
#   FAIL_AMBIGUOUS <n>
#   FAIL_SUFFIXED <hostname> <id> <created>
select_live_target() {
  local devices_json="$1" hostname="$2"
  # Tailscale hostnames are matched case-insensitively here (MagicDNS itself
  # is case-insensitive; the API's `hostname` field is a display value that
  # is not guaranteed to be lowercased, e.g. "MacMini-DevServer"). Downcase
  # both sides of every comparison so callers don't have to guess casing.
  echo "$devices_json" | jq -r --arg h_raw "$hostname" '
    ($h_raw | ascii_downcase) as $h
    | [ .devices[]
      | select(
          (((.hostname // "") | ascii_downcase) == $h) or
          (((.hostname // "") | ascii_downcase) | test("^" + $h + "-[0-9]+$"))
        )
      | select((.authorized // false) == true and (.connectedToControl // false) == true)
    ] as $live
    | if ($live | length) == 0 then
        "FAIL_NONE_LIVE"
      elif ($live | length) > 1 then
        "FAIL_AMBIGUOUS \($live | length)"
      else
        ($live[0]) as $d
        | if ($d.hostname | ascii_downcase) == $h then
            "OK \($d.hostname) \($d.id) \($d.created)"
          else
            "FAIL_SUFFIXED \($d.hostname) \($d.id) \($d.created)"
          end
      end
  '
}

# parse_created_epoch ISO8601_UTC_TIMESTAMP
#
# Prints the Unix epoch for a Tailscale `created`/timestamp string (always
# UTC, "Z"-suffixed) on stdout, or nothing (empty) if unparseable. Factored
# out (and defined before main so it can be `source`d for unit tests) —
# infra#101 found this parsing silently wrong on macOS/BSD `date`: `-j -f`
# parses the input as LOCAL time even though it ends in literal "Z" (BSD
# `date` does not treat "Z" as a UTC marker the way GNU `date -d` does), so
# every parsed epoch was inflated by the host's UTC offset on this org's
# America/New_York runners. That silently defeated the freshness check
# (a deliberately-future --deploy-start-epoch, which must always fail,
# instead passed). `-u` forces BSD `date` to interpret input and output as
# UTC. GNU `date -d` (tried first, for Linux runners) already handles the
# "Z" suffix correctly and needs no change.
parse_created_epoch() {
  local iso_ts="$1"
  date -d "$iso_ts" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso_ts" +%s 2>/dev/null || true
}

# check_freshness CREATED_ISO8601 DEPLOY_START_EPOCH GRACE_SECONDS
#
# Rule 4's decision, factored out (and defined before main so it can be
# `source`d for unit tests, ci-workflows#189) so it's directly testable
# without stubbing curl or running main(). Prints one of:
#   OK
#   FAIL_UNPARSEABLE
#   FAIL_STALE
check_freshness() {
  local created_iso="$1" deploy_start_epoch="$2" grace_seconds="$3"
  local created_epoch
  created_epoch=$(parse_created_epoch "$created_iso")
  if [[ -z "$created_epoch" ]]; then
    echo "FAIL_UNPARSEABLE"
    return
  fi
  local threshold=$(( deploy_start_epoch - grace_seconds ))
  if [[ "$created_epoch" -lt "$threshold" ]]; then
    echo "FAIL_STALE"
  else
    echo "OK"
  fi
}

main() {

TS_API_KEY=""
CANONICAL_HOSTNAME=""
DEPLOY_START_EPOCH=""
TAILNET="-"
GRACE_SECONDS=120
GATEWAY_STATUS_URL=""
EXPECT_TARGET_URL=""
SKIP_FRESHNESS_CHECK="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ts-api-key) TS_API_KEY="$2"; shift 2 ;;
    --canonical-hostname) CANONICAL_HOSTNAME="$2"; shift 2 ;;
    --deploy-start-epoch) DEPLOY_START_EPOCH="$2"; shift 2 ;;
    --tailnet) TAILNET="$2"; shift 2 ;;
    --grace-seconds) GRACE_SECONDS="$2"; shift 2 ;;
    --skip-freshness-check) SKIP_FRESHNESS_CHECK="true"; shift 1 ;;
    --gateway-status-url) GATEWAY_STATUS_URL="$2"; shift 2 ;;
    --expect-target-url) EXPECT_TARGET_URL="$2"; shift 2 ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TS_API_KEY" || -z "$CANONICAL_HOSTNAME" ]]; then
  echo "Usage: verify-ts-lb-target.sh --ts-api-key KEY --canonical-hostname NAME (--deploy-start-epoch EPOCH | --skip-freshness-check) [options]" >&2
  exit 1
fi

if [[ "$SKIP_FRESHNESS_CHECK" != "true" && -z "$DEPLOY_START_EPOCH" ]]; then
  echo "Usage: verify-ts-lb-target.sh --ts-api-key KEY --canonical-hostname NAME (--deploy-start-epoch EPOCH | --skip-freshness-check) [options]" >&2
  echo "  --deploy-start-epoch is required unless --skip-freshness-check is set" >&2
  exit 1
fi

echo "[verify-ts-lb-target] Querying Tailscale API for tailnet=${TAILNET} hostname=${CANONICAL_HOSTNAME}..."
DEVICES_JSON=$(curl -sS -H "Authorization: Bearer ${TS_API_KEY}" \
  "https://api.tailscale.com/api/v2/tailnet/${TAILNET}/devices?fields=all")

if ! echo "$DEVICES_JSON" | jq -e '.devices' >/dev/null 2>&1; then
  echo "[verify-ts-lb-target] FAIL: Tailscale API did not return a device list" >&2
  echo "  Response: $DEVICES_JSON" >&2
  exit 1
fi

RESULT=$(select_live_target "$DEVICES_JSON" "$CANONICAL_HOSTNAME")
READ_KIND="$(echo "$RESULT" | awk '{print $1}')"

case "$READ_KIND" in
  OK)
    LIVE_HOSTNAME=$(echo "$RESULT" | awk '{print $2}')
    LIVE_ID=$(echo "$RESULT" | awk '{print $3}')
    LIVE_CREATED=$(echo "$RESULT" | awk '{print $4}')
    ;;
  FAIL_NONE_LIVE)
    echo "[verify-ts-lb-target] FAIL: no connected/authorized Tailscale device found for hostname '${CANONICAL_HOSTNAME}' (or its -N variants). The LB has nothing live to target." >&2
    exit 1
    ;;
  FAIL_AMBIGUOUS)
    N=$(echo "$RESULT" | awk '{print $2}')
    echo "[verify-ts-lb-target] FAIL: ${N} devices are simultaneously connected for hostname '${CANONICAL_HOSTNAME}'. LB target is ambiguous — cannot structurally guarantee it resolves to the node this deploy just started. Reap the stale registrations before retrying." >&2
    exit 1
    ;;
  FAIL_SUFFIXED)
    SUFFIXED_HOSTNAME=$(echo "$RESULT" | awk '{print $2}')
    echo "[verify-ts-lb-target] FAIL: the only live device for this service is registered as '${SUFFIXED_HOSTNAME}', not the canonical '${CANONICAL_HOSTNAME}'. The canonical name was not reclaimed (a stale device is likely still holding it) — MagicDNS lookups of '${CANONICAL_HOSTNAME}' will NOT reach this deploy." >&2
    exit 1
    ;;
  *)
    echo "[verify-ts-lb-target] FAIL: unexpected result from device selection: ${RESULT}" >&2
    exit 1
    ;;
esac

echo "[verify-ts-lb-target] Found exactly one live device: hostname=${LIVE_HOSTNAME} id=${LIVE_ID} created=${LIVE_CREATED}"

if [[ "$SKIP_FRESHNESS_CHECK" == "true" ]]; then
  echo "[verify-ts-lb-target] Skipping freshness check (--skip-freshness-check): rules 1-3 (exactly one connected, authorized, correctly-named device) are treated as sufficient here."
else
  # Freshness check (rule 4): the live device must have been created at/after
  # this deploy started (minus grace), i.e. it is the node THIS deploy
  # produced. See check_freshness()/parse_created_epoch() above.
  FRESHNESS_RESULT="$(check_freshness "$LIVE_CREATED" "$DEPLOY_START_EPOCH" "$GRACE_SECONDS")"
  if [[ "$FRESHNESS_RESULT" == "FAIL_UNPARSEABLE" ]]; then
    echo "[verify-ts-lb-target] FAIL: could not parse created timestamp '${LIVE_CREATED}' for device ${LIVE_ID}" >&2
    exit 1
  fi
  if [[ "$FRESHNESS_RESULT" == "FAIL_STALE" ]]; then
    CREATED_EPOCH=$(parse_created_epoch "$LIVE_CREATED")
    echo "[verify-ts-lb-target] FAIL: live device for '${CANONICAL_HOSTNAME}' was created at ${LIVE_CREATED} (epoch ${CREATED_EPOCH}), which is before this deploy started (epoch ${DEPLOY_START_EPOCH}, grace ${GRACE_SECONDS}s). This is a leftover registration from a previous deploy, not the node this deploy just started — the LB may still be pointing at the old revision." >&2
    exit 1
  fi

  echo "[verify-ts-lb-target] Freshness OK: device created at ${LIVE_CREATED} is at/after deploy start (grace ${GRACE_SECONDS}s)."
fi

# Optional cross-check against qwickway's own /gateway/status.
if [[ -n "$GATEWAY_STATUS_URL" && -n "$EXPECT_TARGET_URL" ]]; then
  echo "[verify-ts-lb-target] Cross-checking qwickway status at ${GATEWAY_STATUS_URL}..."
  STATUS_JSON=$(curl -sS --max-time 15 "$GATEWAY_STATUS_URL" || echo "")
  if [[ -z "$STATUS_JSON" ]]; then
    echo "[verify-ts-lb-target] FAIL: could not reach gateway status endpoint ${GATEWAY_STATUS_URL}" >&2
    exit 1
  fi
  IS_ACTIVE=$(echo "$STATUS_JSON" | jq -r --arg u "$EXPECT_TARGET_URL" '
    [.. | objects | select(has("url") or has("URL"))] as $backends
    | ($backends[] | select((.url // .URL) == $u) | (.is_green // .IsGreen // false)) // false
  ' 2>/dev/null || echo "false")
  if [[ "$IS_ACTIVE" != "true" ]]; then
    echo "[verify-ts-lb-target] FAIL: qwickway/gateway status does not report ${EXPECT_TARGET_URL} as the active backend." >&2
    echo "  Status response: $STATUS_JSON" >&2
    exit 1
  fi
  echo "[verify-ts-lb-target] Gateway status confirms ${EXPECT_TARGET_URL} is the active backend."
fi

if [[ "$SKIP_FRESHNESS_CHECK" == "true" ]]; then
  echo "[verify-ts-lb-target] PASS: LB target for '${CANONICAL_HOSTNAME}' structurally resolves to exactly one live, correctly-named device (${LIVE_ID})."
else
  echo "[verify-ts-lb-target] PASS: LB target for '${CANONICAL_HOSTNAME}' structurally resolves to the node this deploy just started (device ${LIVE_ID})."
fi
}

# Only run main when executed directly, not when sourced for unit testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
