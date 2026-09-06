#!/usr/bin/env bash

# Tailscale env-var preserve-on-partial-write resolution, shared by scripts
# that update a CapRover app definition's envVars without wiping unrelated
# Tailscale config on a deploy that doesn't pass the corresponding --ts-*
# flag (qwickapps/ci-workflows#22, #131, #132).
#
# Resolution order for each TS var:
#   1. Explicit --ts-* flag passed to the calling script  (caller override)
#   2. Existing value in the CapRover app definition        (preserve)
#   3. Empty string                                         (not set)
#
# TS_EPHEMERAL_AUTHKEY has a CLI flag as of brain#34 (--ts-ephemeral-authkey
# in setup-qwickway-route.sh) and follows the same three-case resolution as
# the others.
#
# Extracted so a test harness can exercise the resolution logic directly
# (qwickapps/ci-workflows#133) instead of only being caught by whichever
# TS_* var happens to be the one someone forgets to wire up next.

set -euo pipefail

# resolve_ts_env_vars <current_def_json> <env_vars_json> <ts_authkey> <ts_hostname> <ts_tags> <ts_api_key> [ts_ephemeral_authkey]
#
# Prints the updated env_vars json array (env_vars_json with any non-empty
# effective TS_* entries appended) to stdout. Human-readable logging goes to
# stderr so it never contaminates the captured stdout.
#
# ts_ephemeral_authkey (7th, optional) was preserve-only until brain#34: a
# caller with no way to pass it could never opt an app INTO an ephemeral
# Tailscale identity, only keep whatever it already had. That mattered for
# qwickway LB apps specifically -- appDefinitions/update restarts the
# container on every run, and a non-ephemeral TS_AUTHKEY-only identity does
# not get cleaned up by Tailscale on disconnect, so repeated re-runs
# accumulate duplicate devices under the same hostname. An explicit flag
# lets a caller (setup-qwickway-route.sh's --ts-ephemeral-authkey) opt an app
# into ephemeral identity so restarts self-clean instead of accumulating.
resolve_ts_env_vars() {
  local current_def="$1"
  local env_vars="$2"
  local ts_authkey="$3"
  local ts_hostname="$4"
  local ts_tags="$5"
  local ts_api_key="$6"
  local ts_ephemeral_authkey="${7:-}"

  local existing_ts_authkey existing_ts_eph_authkey existing_ts_hostname existing_ts_tags existing_ts_api_key
  existing_ts_authkey=$(echo "$current_def" | jq -r '.envVars[] | select(.key == "TS_AUTHKEY") | .value // ""' 2>/dev/null || echo "")
  existing_ts_eph_authkey=$(echo "$current_def" | jq -r '.envVars[] | select(.key == "TS_EPHEMERAL_AUTHKEY") | .value // ""' 2>/dev/null || echo "")
  existing_ts_hostname=$(echo "$current_def" | jq -r '.envVars[] | select(.key == "TS_HOSTNAME") | .value // ""' 2>/dev/null || echo "")
  existing_ts_tags=$(echo "$current_def" | jq -r '.envVars[] | select(.key == "TS_TAGS") | .value // ""' 2>/dev/null || echo "")
  existing_ts_api_key=$(echo "$current_def" | jq -r '.envVars[] | select(.key == "TS_API_KEY") | .value // ""' 2>/dev/null || echo "")

  local effective_ts_authkey effective_ts_eph_authkey effective_ts_hostname effective_ts_tags effective_ts_api_key
  effective_ts_authkey="${ts_authkey:-$existing_ts_authkey}"
  effective_ts_eph_authkey="${ts_ephemeral_authkey:-$existing_ts_eph_authkey}"
  effective_ts_hostname="${ts_hostname:-$existing_ts_hostname}"
  effective_ts_tags="${ts_tags:-$existing_ts_tags}"
  effective_ts_api_key="${ts_api_key:-$existing_ts_api_key}"

  if [ -n "$effective_ts_authkey" ]; then
    env_vars=$(echo "$env_vars" | jq --arg v "$effective_ts_authkey" '. + [{key: "TS_AUTHKEY", value: $v}]')
  fi
  if [ -n "$effective_ts_eph_authkey" ]; then
    env_vars=$(echo "$env_vars" | jq --arg v "$effective_ts_eph_authkey" '. + [{key: "TS_EPHEMERAL_AUTHKEY", value: $v}]')
  fi
  if [ -n "$effective_ts_hostname" ]; then
    env_vars=$(echo "$env_vars" | jq --arg v "$effective_ts_hostname" '. + [{key: "TS_HOSTNAME", value: $v}]')
    echo "  TS_HOSTNAME=$effective_ts_hostname" >&2
  fi
  if [ -n "$effective_ts_tags" ]; then
    env_vars=$(echo "$env_vars" | jq --arg v "$effective_ts_tags" '. + [{key: "TS_TAGS", value: $v}]')
  fi
  if [ -n "$effective_ts_api_key" ]; then
    env_vars=$(echo "$env_vars" | jq --arg v "$effective_ts_api_key" '. + [{key: "TS_API_KEY", value: $v}]')
  fi

  echo "$env_vars"
}
