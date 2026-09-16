#!/usr/bin/env bash
#
# rescope-ts-hostname.sh -- protocols#299, ported into the shared
# promote-to-stable.yml with one deliberate deviation from the original
# fix (documents' own .github/scripts/swap-instances.sh set_ts_hostname()),
# documented here rather than left silent.
#
# The original fix is UNCONDITIONAL: every promoted slot gets its
# TS_HOSTNAME forced to its own app name, full stop, because every one of
# swap-instances.sh's callers is a Tailscale-fronted app. This shared
# workflow has a much wider caller set -- ide, forge, and crew never set
# TS_HOSTNAME at all -- so an unconditional port would INTRODUCE a
# TS_HOSTNAME env var into apps that never had one, which is arguably
# worse than the collision bug being fixed. This version only rescopes
# when the copied env already carries a TS_HOSTNAME key (any value,
# including empty or whitespace-only -- presence is what's checked, not
# content), and is a no-op when the key is genuinely absent.
#
# Usage:
#   rescope-ts-hostname.sh <stable-app-json> <env-vars-json> <app-name>
#
# stable-app-json: the target (stable) CapRover app definition object.
# env-vars-json:   the source (live) app's .envVars array, already
#                   extracted by the caller.
# app-name:        the stable slot's own app name to rescope onto.
#
# Prints the stable app definition with .envVars replaced by env-vars-json,
# with any TS_HOSTNAME entry in it re-pointed to app-name -- UNLESS no
# TS_HOSTNAME key is present in env-vars-json at all, in which case
# .envVars is set to env-vars-json unchanged (no key is introduced).

set -euo pipefail

rescope_ts_hostname() {
  local stable_def="$1" env_vars="$2" app_name="$3"

  local merged
  merged=$(printf '%s' "$stable_def" | jq --argjson vars "$env_vars" '.envVars = $vars')

  if printf '%s' "$env_vars" | jq -e 'any(.[]; .key == "TS_HOSTNAME")' >/dev/null 2>&1; then
    merged=$(printf '%s' "$merged" | jq --arg name "$app_name" \
      '.envVars = (((.envVars // []) | map(select(.key != "TS_HOSTNAME"))) + [{key: "TS_HOSTNAME", value: $name}])')
  fi

  printf '%s' "$merged"
}

main() {
  if [ "$#" -ne 3 ]; then
    echo "Usage: rescope-ts-hostname.sh <stable-app-json> <env-vars-json> <app-name>" >&2
    exit 2
  fi
  rescope_ts_hostname "$1" "$2" "$3"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
