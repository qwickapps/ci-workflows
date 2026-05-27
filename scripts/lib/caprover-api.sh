#!/usr/bin/env bash

# Shared CapRover API helpers for GitHub workflows.
# Canonical source: qwickapps/ci-workflows scripts/lib/caprover-api.sh
# Mirrors mcp/.github/scripts/lib/caprover-api.sh — keep in sync.

set -euo pipefail

caprover_require_bin() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Error: required command not found: $bin" >&2
    exit 1
  fi
}

caprover_require_bin curl
caprover_require_bin jq

caprover_populate_curl_args() {
  # $1 = caprover_url, $2 = name of the array variable to populate in the caller's scope.
  # Uses eval for bash 3.2 compatibility (macOS ships bash 3.2; local -n requires 4.3+).
  local caprover_url="$1"
  local _out_name="$2"
  local override_ip="${CAPROVER_HOST_OVERRIDE_IP:-}"

  if [[ -z "$override_ip" ]]; then
    eval "${_out_name}=(-s -k)"
    return 0
  fi

  local host_with_port="${caprover_url#*://}"
  host_with_port="${host_with_port%%/*}"

  if [[ -z "$host_with_port" ]]; then
    eval "${_out_name}=(-s -k)"
    return 0
  fi

  local host="${host_with_port%%:*}"
  local port=""
  if [[ "$host_with_port" == *:* ]]; then
    port="${host_with_port##*:}"
  fi

  if [[ -z "$port" ]]; then
    case "$caprover_url" in
      https://*) port="443" ;;
      http://*)  port="80"  ;;
      *)         port="443" ;;
    esac
  fi

  # shellcheck disable=SC2086
  eval "${_out_name}=(-s -k --resolve \"${host}:${port}:${override_ip}\")"
}

caprover_login() {
  local caprover_url="$1"
  local caprover_pass="$2"
  local curl_args=()

  caprover_url="$(printf '%s' "$caprover_url" | tr -d '\r\n')"
  caprover_pass="$(printf '%s' "$caprover_pass" | tr -d '\r\n')"
  caprover_populate_curl_args "$caprover_url" curl_args

  local response token
  response=$(curl "${curl_args[@]}" -X POST --url "${caprover_url}/api/v2/login" \
    -H "Content-Type: application/json" \
    -d "{\"password\":\"${caprover_pass}\"}")

  if ! echo "$response" | jq -e . >/dev/null 2>&1; then
    echo "Error: CapRover login returned non-JSON response" >&2
    echo "$response" | sed -n '1,10p' >&2
    return 1
  fi

  token=$(echo "$response" | jq -r '.data.token')

  if [[ -z "${token}" || "${token}" == "null" ]]; then
    echo "Error: failed to authenticate with CapRover" >&2
    return 1
  fi

  printf '%s\n' "$token"
}

caprover_api_call() {
  local description="$1"
  shift

  local max_retries="${CAPROVER_API_MAX_RETRIES:-5}"
  local retry_delay="${CAPROVER_API_INITIAL_RETRY_DELAY:-10}"
  local attempt=1

  while [[ $attempt -le $max_retries ]]; do
    echo "  Attempt ${attempt}/${max_retries}: ${description}" >&2

    local response
    response=$("$@")

    if echo "$response" | grep -Eiq "another operation.*in progress|operation.*still in progress|please wait"; then
      if [[ $attempt -lt $max_retries ]]; then
        echo "  CapRover is busy; retrying in ${retry_delay}s..." >&2
        sleep "$retry_delay"
        retry_delay=$((retry_delay * 2))
        if [[ $retry_delay -gt 60 ]]; then
          retry_delay=60
        fi
        attempt=$((attempt + 1))
        continue
      fi

      echo "  CapRover still busy after ${max_retries} attempts" >&2
      echo "  Response: $response" >&2
      return 1
    fi

    printf '%s\n' "$response"
    return 0
  done

  return 1
}

caprover_get_app_definitions() {
  local caprover_url="$1"
  local token="$2"
  local curl_args=()

  caprover_populate_curl_args "$caprover_url" curl_args

  curl "${curl_args[@]}" -X GET "${caprover_url}/api/v2/user/apps/appDefinitions" \
    -H "x-captain-auth: ${token}"
}
