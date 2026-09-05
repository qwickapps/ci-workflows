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

# Idempotent app registration. $4 = "true"|"false" for hasPersistentData.
caprover_ensure_app() {
  local caprover_url="$1" token="$2" app_name="$3" has_persistent_data="${4:-false}"
  local curl_args=()
  caprover_populate_curl_args "$caprover_url" curl_args

  local response status desc
  response=$(curl "${curl_args[@]}" -s -X POST "${caprover_url}/api/v2/user/apps/appDefinitions/register" \
    -H "Content-Type: application/json" \
    -H "x-captain-auth: ${token}" \
    -d "{\"appName\":\"${app_name}\",\"hasPersistentData\":${has_persistent_data}}")
  status=$(echo "$response" | jq -r '.status // "null"')
  case "$status" in
    100)  echo "  App '${app_name}' registered" ;;
    1901) echo "  App '${app_name}' already exists" ;;
    *)
      desc=$(echo "$response" | jq -r '.description // ""')
      if echo "$desc" | grep -qi "already exists"; then
        echo "  App '${app_name}' already exists"
      else
        echo "  Error registering '${app_name}' (status ${status}): ${desc}" >&2
        return 1
      fi ;;
  esac
}

# Upsert GHCR registry credentials on the target CapRover instance.
# $3 = GitHub personal access token with packages:read.
caprover_sync_ghcr_registry() {
  local caprover_url="$1" token="$2" ghcr_token="$3"
  local curl_args=()
  caprover_populate_curl_args "$caprover_url" curl_args

  local ids
  ids=$(curl "${curl_args[@]}" -s -X GET "${caprover_url}/api/v2/user/registries" \
    -H "x-captain-auth: ${token}" \
    | jq -r '(.data.registries // [])[] | select(.registryDomain == "ghcr.io") | .id // empty' 2>/dev/null || true)

  if [ -z "$ids" ]; then
    echo "  Inserting ghcr.io registry entry..."
    curl "${curl_args[@]}" -s -X POST "${caprover_url}/api/v2/user/registries/insert" \
      -H "Content-Type: application/json" \
      -H "x-captain-auth: ${token}" \
      -d "$(jq -n --arg t "$ghcr_token" \
        '{registryUser:"x-access-token",registryPassword:$t,registryDomain:"ghcr.io",registryImagePrefix:""}')" >/dev/null
    echo "  ghcr.io registry inserted"
    return 0
  fi

  echo "$ids" | while IFS= read -r reg_id; do
    [ -z "$reg_id" ] && continue
    echo "  Updating ghcr.io registry entry ${reg_id}..."
    curl "${curl_args[@]}" -s -X POST "${caprover_url}/api/v2/user/registries/update" \
      -H "Content-Type: application/json" \
      -H "x-captain-auth: ${token}" \
      -d "$(jq -n --arg id "$reg_id" --arg t "$ghcr_token" \
        '{id:$id,registryUser:"x-access-token",registryPassword:$t,registryDomain:"ghcr.io",registryImagePrefix:""}')" >/dev/null
    echo "  ghcr.io registry ${reg_id} updated"
  done
}

# Trigger a registry-image deploy via captainDefinitionContent.
# Handles build-lock responses and 504 proxy timeouts (both indicate the pull
# is in progress, not a failure). Use caprover_poll_deployed_image to confirm.
caprover_deploy_registry_image() {
  local caprover_url="$1" token="$2" app_name="$3" image_ref="$4"
  local curl_args=()
  caprover_populate_curl_args "$caprover_url" curl_args

  local captain_def payload response status desc
  captain_def=$(jq -nc --arg img "$image_ref" '{schemaVersion:2,imageName:$img}')
  payload=$(jq -nc --arg c "$captain_def" '{captainDefinitionContent:$c,gitHash:""}')

  echo "  Deploying ${image_ref} to ${app_name}..."
  response=$(curl "${curl_args[@]}" -s --max-time 300 \
    -X POST "${caprover_url}/api/v2/user/apps/appData/${app_name}" \
    -H "Content-Type: application/json" \
    -H "x-captain-auth: ${token}" \
    -d "$payload" || true)

  if [ -z "$response" ]; then
    echo "  Deploy POST timed out (image pull in progress — expected for large images)"
    return 0
  fi

  status=$(echo "$response" | jq -r '.status // "null"' 2>/dev/null || echo "null")
  desc=$(echo "$response" | jq -r '.description // ""' 2>/dev/null || echo "$response")
  case "$status" in
    100|1000) echo "  Deploy request accepted (status ${status})" ;;
    *)
      if echo "${desc}${response}" | grep -qi "build.*progress\|please wait\|operation.*in progress"; then
        echo "  Deploy accepted (build-lock/1108 — poll will confirm)"
      elif echo "${response}" | grep -qi "504\|gateway timeout"; then
        echo "  Deploy POST returned 504 (image pull in progress — expected)"
      else
        echo "  Error: CapRover rejected deploy (status ${status}): ${desc}" >&2
        return 1
      fi ;;
  esac
}

# Poll until the app's deployedImageName matches image_ref.
# $5 = max poll attempts (default 60), $6 = seconds between polls (default 20).
caprover_poll_deployed_image() {
  local caprover_url="$1" token="$2" app_name="$3" image_ref="$4"
  local max_attempts="${5:-60}" poll_delay="${6:-20}"
  local curl_args=()
  caprover_populate_curl_args "$caprover_url" curl_args

  echo "  Polling deployedImageName = ${image_ref} (max ${max_attempts}×${poll_delay}s)..."
  local attempt=0 deployed=""
  while [ "$attempt" -lt "$max_attempts" ]; do
    deployed=$(curl "${curl_args[@]}" -s \
      "${caprover_url}/api/v2/user/apps/appDefinitions" \
      -H "x-captain-auth: ${token}" \
      | jq -r --arg app "$app_name" '
          .data.appDefinitions[]?
          | select(.appName == $app)
          | (.deployedVersion) as $dv
          | ([.versions[]? | select(.version == $dv) | .deployedImageName] | first) // ""' \
      2>/dev/null || true)
    attempt=$((attempt + 1))
    if [ "$deployed" = "$image_ref" ]; then
      echo "  Image confirmed after ${attempt} poll(s): ${deployed}"
      return 0
    fi
    if [ $((attempt % 3)) -eq 0 ]; then
      echo "  poll ${attempt}/${max_attempts}: deployedImage=${deployed:-<none>}"
    fi
    sleep "$poll_delay"
  done
  echo "  Error: deployedImageName did not reach '${image_ref}' within poll window" >&2
  return 1
}

# Remove an app by name (idempotent — no-op if the app does not exist).
# Does NOT delete persistent volumes.
caprover_remove_app() {
  local caprover_url="$1" token="$2" app_name="$3"
  local curl_args=()
  caprover_populate_curl_args "$caprover_url" curl_args

  local exists
  exists=$(curl "${curl_args[@]}" -s \
    "${caprover_url}/api/v2/user/apps/appDefinitions" \
    -H "x-captain-auth: ${token}" \
    | jq -r --arg app "$app_name" '.data.appDefinitions[]? | select(.appName == $app) | .appName' \
    2>/dev/null || true)

  if [ -z "$exists" ]; then
    echo "  App '${app_name}' not found on ${caprover_url} — nothing to remove"
    return 0
  fi

  echo "  Removing app '${app_name}' from ${caprover_url}..."
  local del_resp del_status del_desc
  del_resp=$(curl "${curl_args[@]}" -s -X POST \
    "${caprover_url}/api/v2/user/apps/appDefinitions/delete" \
    -H "Content-Type: application/json" \
    -H "x-captain-auth: ${token}" \
    -d "$(jq -n --arg app "$app_name" '{appName:$app,volumes:[]}')" 2>/dev/null || true)
  del_status=$(echo "$del_resp" | jq -r '.status // "null"' 2>/dev/null || echo "null")
  del_desc=$(echo "$del_resp" | jq -r '.description // ""' 2>/dev/null || echo "$del_resp")
  if [ "$del_status" = "100" ] || [ "$del_status" = "1000" ]; then
    echo "  App '${app_name}' removed"
  else
    echo "  Warning: remove app '${app_name}' returned (status ${del_status}): ${del_desc}" >&2
  fi
}
