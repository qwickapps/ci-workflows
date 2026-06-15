#!/bin/bash
set -euo pipefail

# Canonical configure-caprover-app.sh — centralised in ci-workflows so every
# caller gets the same fix without requiring per-repo changes.
#
# Configures a CapRover app: instance count, container port, SSL, env vars.
#
# KEY INVARIANT (anti-wipe guarantee):
#   On every invocation, env vars are MERGED into the existing CapRover state
#   in a SINGLE atomic update (config + SSL + envVars together).
#
#   Merge semantics: existing CapRover vars are preserved; canonical vars
#   (from --env-file) override matching keys; vars present in CapRover but
#   absent from the env file are NOT removed.  This prevents pipeline deploys
#   from wiping vars set outside the canonical pipeline (hot-patches,
#   per-host overrides, vars managed by other workflows).
#
#   The original two-update pattern (config, then SSL re-fetch + update) silently
#   wiped envVars when Step 3's re-fetch returned stale/null envVars.  This
#   version consolidates both updates so envVars are never clobbered.
#
# Usage:
#   configure-caprover-app.sh \
#     --app-name <name> \
#     --caprover-url <url> \
#     --caprover-password <password> \
#     [--instance-count <count>]   (default 1)
#     [--container-port <port>]    (default 3300)
#     [--force-ssl true|false]     (default true)
#     [--enable-ssl true|false]    (default true)
#     [--websocket-support true|false] (default true)
#     [--not-expose-as-web-app true|false]
#     [--has-persistent-data true|false]
#     [--volumes-json <json>]
#     [--ports-json <json>]
#     [--description <text>]
#     [--env-file <path>]
#     [--domains <comma-separated>]
#     [--cmd <binary>]             (sets serviceUpdateOverride CMD)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/caprover-api.sh
source "${SCRIPT_DIR}/lib/caprover-api.sh"

APP_NAME=""
CAPROVER_URL=""
CAPROVER_PASSWORD=""
INSTANCE_COUNT=1
CONTAINER_PORT=3300
FORCE_SSL="true"
ENABLE_SSL="true"
WEBSOCKET_SUPPORT="true"
NOT_EXPOSE_AS_WEB_APP="false"
HAS_PERSISTENT_DATA=""
VOLUMES_JSON=""
PORTS_JSON=""
DESCRIPTION=""
ENV_FILE=""
DOMAINS=""
CMD=""
CMD_SET="false"

while [[ $# -gt 0 ]]; do
  case $1 in
    --app-name)            APP_NAME="$2";            shift 2 ;;
    --caprover-url)        CAPROVER_URL="$2";        shift 2 ;;
    --caprover-password)   CAPROVER_PASSWORD="$2";   shift 2 ;;
    --instance-count)      INSTANCE_COUNT="$2";      shift 2 ;;
    --container-port)      CONTAINER_PORT="$2";      shift 2 ;;
    --force-ssl)           FORCE_SSL="$2";           shift 2 ;;
    --enable-ssl)          ENABLE_SSL="$2";          shift 2 ;;
    --websocket-support)   WEBSOCKET_SUPPORT="$2";   shift 2 ;;
    --not-expose-as-web-app) NOT_EXPOSE_AS_WEB_APP="$2"; shift 2 ;;
    --has-persistent-data) HAS_PERSISTENT_DATA="$2"; shift 2 ;;
    --volumes-json)        VOLUMES_JSON="$2";        shift 2 ;;
    --ports-json)          PORTS_JSON="$2";          shift 2 ;;
    --description)         DESCRIPTION="$2";         shift 2 ;;
    --env-file)            ENV_FILE="$2";            shift 2 ;;
    --domains)             DOMAINS="$2";             shift 2 ;;
    --cmd)                 CMD="$2"; CMD_SET="true"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ -z "$APP_NAME" ] || [ -z "$CAPROVER_URL" ] || [ -z "$CAPROVER_PASSWORD" ]; then
  echo "Error: --app-name, --caprover-url, and --caprover-password are required"
  exit 1
fi

echo "========================================="
echo "Configure CapRover App"
echo "  app:            $APP_NAME"
echo "  instance-count: $INSTANCE_COUNT"
echo "  container-port: $CONTAINER_PORT"
echo "  force-ssl:      $FORCE_SSL"
[[ "$NOT_EXPOSE_AS_WEB_APP" == "true" ]] && echo "  internal-only:  true"
[[ "$CMD_SET" == "true" ]] && echo "  cmd:            ${CMD:-<clear>}"
echo "========================================="

echo ""
echo "Authenticating with CapRover..."
TOKEN="$(caprover_login "$CAPROVER_URL" "$CAPROVER_PASSWORD")"
echo "  Authenticated"

CURL_ARGS=()
caprover_populate_curl_args "$CAPROVER_URL" CURL_ARGS

# Ensure app exists (idempotent register)
echo ""
echo "Ensuring app exists..."
CREATE_RESPONSE=$(curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/register" \
  -H "Content-Type: application/json" \
  -H "x-captain-auth: $TOKEN" \
  -d "{\"appName\":\"$APP_NAME\",\"hasPersistentData\":false}")

if ! echo "$CREATE_RESPONSE" | jq -e . >/dev/null 2>&1; then
  echo "  Error: Invalid JSON from register endpoint"
  echo "$CREATE_RESPONSE"
  exit 1
fi

CREATE_STATUS=$(echo "$CREATE_RESPONSE" | jq -r '.status')
APP_ALREADY_EXISTS=false
if [ "$CREATE_STATUS" = "100" ]; then
  echo "  App created"
elif [ "$CREATE_STATUS" = "1901" ]; then
  echo "  App already exists"
  APP_ALREADY_EXISTS=true
else
  DESC=$(echo "$CREATE_RESPONSE" | jq -r '.description')
  if echo "$DESC" | grep -q "already exists"; then
    echo "  App already exists"
    APP_ALREADY_EXISTS=true
  else
    echo "  Warning: Unexpected register response: $DESC"
  fi
fi

# Fetch current app definition (read-then-write preserves existing fields)
echo ""
echo "Fetching current app definition..."
ALL_DEFS=$(curl "${CURL_ARGS[@]}" -X GET "$CAPROVER_URL/api/v2/user/apps/appDefinitions" \
  -H "x-captain-auth: $TOKEN")

CURRENT_DEF=$(echo "$ALL_DEFS" | jq --arg name "$APP_NAME" '.data.appDefinitions[] | select(.appName == $name)')

if [ -z "$CURRENT_DEF" ] || [ "$CURRENT_DEF" = "null" ]; then
  echo "  Error: Could not fetch app definition for $APP_NAME"
  exit 1
fi
echo "  Fetched app definition"

# Enable SSL on base domain BEFORE building the merged definition.
# This ensures hasDefaultSubDomainSsl is accurate when we do the
# single atomic update below.
echo ""
echo "Ensuring SSL is provisioned on base domain..."
if [ "$ENABLE_SSL" = "true" ] && [ "${NOT_EXPOSE_AS_WEB_APP:-false}" != "true" ]; then
  APP_DATA=$(curl "${CURL_ARGS[@]}" -X GET "$CAPROVER_URL/api/v2/user/apps/appData/$APP_NAME" \
    -H "x-captain-auth: $TOKEN")
  HAS_SSL=$(echo "$APP_DATA" | jq -r '.data.appDefinition.hasDefaultSubDomainSsl // false')

  if [ "$HAS_SSL" = "true" ]; then
    echo "  SSL already provisioned, skipping"
  else
    SSL_RESPONSE=$(caprover_api_call "Enable base domain SSL" \
      curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/enablebasedomainssl" \
      -H "Content-Type: application/json" \
      -H "x-captain-auth: $TOKEN" \
      -d "$(jq -n --arg app "$APP_NAME" '{appName: $app}')")

    SSL_STATUS=$(echo "$SSL_RESPONSE" | jq -r '.status')
    SSL_DESC=$(echo "$SSL_RESPONSE" | jq -r '.description // ""')
    if [ "$SSL_STATUS" = "100" ]; then
      echo "  SSL enabled on base domain"
    elif echo "$SSL_DESC" | grep -iq "already\|enabled"; then
      echo "  SSL already enabled on base domain"
    else
      echo "  Warning: SSL enable response: $SSL_DESC (status: $SSL_STATUS)"
    fi
  fi
else
  if [ "${NOT_EXPOSE_AS_WEB_APP:-false}" = "true" ]; then
    echo "  Internal-only app, skipping base-domain SSL"
  else
    echo "  Base-domain SSL disabled"
  fi
fi

# Re-fetch after SSL step so the merged definition carries the accurate
# hasDefaultSubDomainSsl value.  The re-fetched envVars serve as the base
# for the merge below — canonical vars are applied on top, not in place of.
echo ""
echo "Re-fetching app definition (post-SSL)..."
ALL_DEFS_POST_SSL=$(curl "${CURL_ARGS[@]}" -X GET "$CAPROVER_URL/api/v2/user/apps/appDefinitions" \
  -H "x-captain-auth: $TOKEN")
CURRENT_DEF_POST_SSL=$(echo "$ALL_DEFS_POST_SSL" | jq --arg name "$APP_NAME" '.data.appDefinitions[] | select(.appName == $name)')
if [ -z "$CURRENT_DEF_POST_SSL" ] || [ "$CURRENT_DEF_POST_SSL" = "null" ]; then
  echo "  Warning: re-fetch failed, continuing with pre-SSL definition"
  CURRENT_DEF_POST_SSL="$CURRENT_DEF"
fi

# Build the single atomic merged definition.
# Start from the post-SSL definition (accurate meta-fields), then apply
# all config + env vars in one step so there is no window where a second
# update can clobber envVars.
echo ""
echo "Building atomic update payload..."
MERGED=$(echo "$CURRENT_DEF_POST_SSL" | jq \
  --argjson count "$INSTANCE_COUNT" \
  --argjson port "$CONTAINER_PORT" \
  --argjson ssl "$FORCE_SSL" \
  --argjson websocket "$WEBSOCKET_SUPPORT" \
  '.instanceCount = $count | .containerHttpPort = $port |
   .forceSsl = $ssl | .websocketSupport = $websocket |
   .appDeployTokenConfig = (.appDeployTokenConfig // {} | .enabled = true)')

if [ -n "$NOT_EXPOSE_AS_WEB_APP" ]; then
  MERGED=$(echo "$MERGED" | jq --argjson v "$NOT_EXPOSE_AS_WEB_APP" '.notExposeAsWebApp = $v')
fi
if [ -n "$HAS_PERSISTENT_DATA" ]; then
  MERGED=$(echo "$MERGED" | jq --argjson v "$HAS_PERSISTENT_DATA" '.hasPersistentData = $v')
fi
if [ -n "$DESCRIPTION" ]; then
  MERGED=$(echo "$MERGED" | jq --arg v "$DESCRIPTION" '.description = $v')
fi
if [ -n "$VOLUMES_JSON" ]; then
  MERGED=$(echo "$MERGED" | jq --argjson v "$VOLUMES_JSON" '.volumes = $v')
fi
if [ -n "$PORTS_JSON" ]; then
  MERGED=$(echo "$MERGED" | jq --argjson v "$PORTS_JSON" '.ports = $v')
fi

if [ "$CMD_SET" = "true" ]; then
  if [ -z "$CMD" ]; then
    echo "  Clearing serviceUpdateOverride (--cmd \"\")"
    MERGED=$(echo "$MERGED" | jq '.serviceUpdateOverride = ""')
  else
    echo "  Setting CMD override: $CMD"
    CMD_YAML=$(printf 'TaskTemplate:\n  ContainerSpec:\n    Command:\n      - %s\n' "$CMD")
    MERGED=$(echo "$MERGED" | jq --arg yaml "$CMD_YAML" '.serviceUpdateOverride = $yaml')
  fi
fi

# Apply env vars — merge canonical set into existing CapRover state.
# Existing vars NOT in the env file are preserved (not wiped).
# Canonical vars override existing values for matching keys.
# This prevents deploys from wiping vars set outside the pipeline
# (e.g. per-host overrides, vars managed by other workflows like mcp-lead).
if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
  echo ""
  echo "Applying environment variables from $ENV_FILE..."

  CANONICAL_VARS="[]"
  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line="${raw_line%%$'\r'}"   # strip CR (Windows line endings)
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in \#*) continue ;; esac
    case "$trimmed" in *=*) ;; *) continue ;; esac
    key="${trimmed%%=*}"
    value="${trimmed#*=}"
    [ -n "$key" ] || continue
    CANONICAL_VARS=$(echo "$CANONICAL_VARS" | jq --arg k "$key" --arg v "$value" '. += [{key: $k, value: $v}]')
  done < "$ENV_FILE"

  CANONICAL_COUNT=$(echo "$CANONICAL_VARS" | jq 'length')
  if [ "$CANONICAL_COUNT" -eq 0 ]; then
    echo "  Warning: env file parsed to zero vars — skipping env application"
  else
    # Merge: start with existing CapRover vars, strip keys canonical will override,
    # append canonical. Canonical wins on conflicts; existing-only vars survive.
    EXISTING_ENV=$(echo "$CURRENT_DEF_POST_SSL" | jq '.envVars // []')
    EXISTING_COUNT=$(echo "$EXISTING_ENV" | jq 'length')
    CANONICAL_KEYS=$(echo "$CANONICAL_VARS" | jq '[.[].key]')
    FINAL_ENV=$(echo "$EXISTING_ENV" | jq \
      --argjson ck "$CANONICAL_KEYS" \
      --argjson cv "$CANONICAL_VARS" \
      '([.[] | select(.key as $k | ($ck | any(. == $k)) | not)] + $cv) | sort_by(.key)')
    FINAL_COUNT=$(echo "$FINAL_ENV" | jq 'length')

    MERGED=$(echo "$MERGED" | jq --argjson env "$FINAL_ENV" '.envVars = $env')
    echo "  Merged $CANONICAL_COUNT canonical vars with $EXISTING_COUNT existing = $FINAL_COUNT total"
  fi
else
  echo ""
  echo "No --env-file provided — env vars unchanged"
fi

# Single atomic update: config + SSL + envVars in one call.
# This eliminates the race window where a two-step approach allowed a
# re-fetched null envVars to overwrite the Step 1 result.
echo ""
echo "Applying atomic update to CapRover..."
UPDATE_RESPONSE=$(caprover_api_call "Atomic update (config + SSL + envVars)" \
  curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/update" \
  -H "Content-Type: application/json" \
  -H "x-captain-auth: $TOKEN" \
  -d "$MERGED")

UPDATE_STATUS=$(echo "$UPDATE_RESPONSE" | jq -r '.status')
if [ "$UPDATE_STATUS" = "100" ] || [ "$UPDATE_STATUS" = "1000" ]; then
  echo "  Update applied (status: $UPDATE_STATUS)"
else
  echo "  Error: Unexpected update response (status: $UPDATE_STATUS): $(echo "$UPDATE_RESPONSE" | jq -r '.description')"
  exit 1
fi

# Post-apply verification: re-read CapRover state and assert all canonical
# env vars are present with correct values.
if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
  echo ""
  echo "Verifying env vars were applied correctly..."
  VERIFY_DEFS=$(curl "${CURL_ARGS[@]}" -X GET "$CAPROVER_URL/api/v2/user/apps/appDefinitions" \
    -H "x-captain-auth: $TOKEN")
  VERIFY_DEF=$(echo "$VERIFY_DEFS" | jq --arg name "$APP_NAME" '.data.appDefinitions[] | select(.appName == $name)')
  VERIFY_ENV=$(echo "$VERIFY_DEF" | jq '.envVars // []')

  VERIFY_FAILED=0
  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line="${raw_line%%$'\r'}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in \#*) continue ;; esac
    case "$trimmed" in *=*) ;; *) continue ;; esac
    key="${trimmed%%=*}"
    expected="${trimmed#*=}"
    [ -n "$key" ] || continue
    actual=$(echo "$VERIFY_ENV" | jq -r --arg k "$key" '.[] | select(.key == $k) | .value // "__MISSING__"')
    if [ "$actual" = "__MISSING__" ]; then
      echo "  FAIL: $key — NOT FOUND in CapRover after update"
      VERIFY_FAILED=1
    elif [ "$actual" != "$expected" ]; then
      echo "  FAIL: $key — value mismatch after update"
      VERIFY_FAILED=1
    fi
  done < "$ENV_FILE"

  if [ "$VERIFY_FAILED" -ne 0 ]; then
    echo "  ERROR: env var verification failed — CapRover state does not match env file"
    echo "  This indicates CapRover rejected or silently dropped the update."
    exit 1
  fi
  echo "  All canonical env vars verified in CapRover"
fi

# Configure custom domains (new apps only)
if [ "${NOT_EXPOSE_AS_WEB_APP:-false}" = "true" ]; then
  : # internal app — no domains
elif [ "$APP_ALREADY_EXISTS" = "false" ] && [ -n "$DOMAINS" ]; then
  echo ""
  echo "Configuring custom domains..."
  IFS=',' read -ra DOMAIN_ARRAY <<< "$DOMAINS"
  for domain in "${DOMAIN_ARRAY[@]}"; do
    domain=$(echo "$domain" | xargs)
    echo "  Adding domain: $domain"
    DOMAIN_RESPONSE=$(curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/customdomain" \
      -H "Content-Type: application/json" \
      -H "x-captain-auth: $TOKEN" \
      -d "{\"appName\": \"$APP_NAME\", \"customDomain\": \"$domain\"}")
    DOMAIN_STATUS=$(echo "$DOMAIN_RESPONSE" | jq -r '.status')
    [ "$DOMAIN_STATUS" = "100" ] && echo "    Domain added" || echo "    $(echo "$DOMAIN_RESPONSE" | jq -r '.description')"

    echo "  Enabling SSL for $domain..."
    DOMAIN_APP_DATA=$(curl "${CURL_ARGS[@]}" -X GET "$CAPROVER_URL/api/v2/user/apps/appData/$APP_NAME" \
      -H "x-captain-auth: $TOKEN")
    HAS_CUSTOM_SSL=$(echo "$DOMAIN_APP_DATA" | jq -r --arg dom "$domain" \
      '.data.appDefinition.customDomain[] | select(.publicDomain == $dom) | .hasSsl // false' 2>/dev/null || echo "false")
    if [ "$HAS_CUSTOM_SSL" = "true" ]; then
      echo "    SSL already provisioned for $domain, skipping"
    else
      CUSTOM_SSL_RESPONSE=$(curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/enablecustomdomainssl" \
        -H "Content-Type: application/json" \
        -H "x-captain-auth: $TOKEN" \
        -d "$(jq -n --arg app "$APP_NAME" --arg dom "$domain" '{appName: $app, customDomain: $dom}')")
      CUSTOM_SSL_STATUS=$(echo "$CUSTOM_SSL_RESPONSE" | jq -r '.status')
      [ "$CUSTOM_SSL_STATUS" = "100" ] && echo "    SSL enabled for $domain" || echo "    $(echo "$CUSTOM_SSL_RESPONSE" | jq -r '.description')"
    fi
  done
fi

# Post-update: force TS_HOSTNAME for build slots to prevent orphan values from
# surviving across blue-green restore cycles.  swap-instances.sh only
# force-overrides live/stable, not build — so a restore that restores stale
# envVars onto the build slot would carry the orphan TS_HOSTNAME forward.
if [[ "$APP_NAME" == *-build ]]; then
  echo ""
  echo "Build slot detected: forcing TS_HOSTNAME to app name..."
  FORCE_DEFS=$(curl "${CURL_ARGS[@]}" -X GET "$CAPROVER_URL/api/v2/user/apps/appDefinitions" \
    -H "x-captain-auth: $TOKEN")
  FORCE_DEF=$(echo "$FORCE_DEFS" | jq --arg name "$APP_NAME" '.data.appDefinitions[] | select(.appName == $name)')
  if [ -n "$FORCE_DEF" ] && [ "$FORCE_DEF" != "null" ]; then
    FORCE_MERGED=$(echo "$FORCE_DEF" | jq --arg name "$APP_NAME" \
      '.envVars = (((.envVars // []) | map(select(.key != "TS_HOSTNAME"))) + [{key: "TS_HOSTNAME", value: $name}])')
    FORCE_RESPONSE=$(caprover_api_call "Force TS_HOSTNAME for build slot" \
      curl "${CURL_ARGS[@]}" -X POST "$CAPROVER_URL/api/v2/user/apps/appDefinitions/update" \
      -H "Content-Type: application/json" \
      -H "x-captain-auth: $TOKEN" \
      -d "$FORCE_MERGED")
    FORCE_STATUS=$(echo "$FORCE_RESPONSE" | jq -r '.status')
    if [ "$FORCE_STATUS" = "100" ] || [ "$FORCE_STATUS" = "1000" ]; then
      echo "  TS_HOSTNAME=$APP_NAME"
    else
      echo "  Warning: TS_HOSTNAME force failed: $(echo "$FORCE_RESPONSE" | jq -r '.description')"
    fi
  else
    echo "  Warning: could not fetch app definition for TS_HOSTNAME force"
  fi
fi

echo ""
echo "========================================="
echo "Configuration complete: $APP_NAME"
echo "========================================="
