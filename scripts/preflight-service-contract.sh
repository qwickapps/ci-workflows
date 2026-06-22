#!/bin/bash
set -euo pipefail

# Preflight Service Contract Validation
#
# Compares required deploy secrets and runtime env vars against the service
# contract manifest before mutation. Ensures no secrets/env vars are lost
# during deployment.
#
# Usage:
#   preflight-service-contract.sh \
#     --app-name <name> \
#     --env-label <dev|uat|live|stable> \
#     --env-file <path> \
#     --contract-file <path> \
#     [--caprover-url <url>] \
#     [--caprover-password <password>] \
#     [--github-secrets-json <json>] \
#     [--dry-run <true|false>]
#
# Exit codes:
#   0 = all checks passed
#   1 = critical failure (missing required vars for critical app)
#   2 = warning (missing optional vars or orphaned vars)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/caprover-api.sh
source "${SCRIPT_DIR}/lib/caprover-api.sh"

APP_NAME=""
ENV_LABEL=""
ENV_FILE=""
CONTRACT_FILE=""
CAPROVER_URL=""
CAPROVER_PASSWORD=""
GITHUB_SECRETS_JSON="{}"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case $1 in
    --app-name)            APP_NAME="$2";            shift 2 ;;
    --env-label)           ENV_LABEL="$2";           shift 2 ;;
    --env-file)            ENV_FILE="$2";            shift 2 ;;
    --contract-file)       CONTRACT_FILE="$2";       shift 2 ;;
    --caprover-url)        CAPROVER_URL="$2";        shift 2 ;;
    --caprover-password)   CAPROVER_PASSWORD="$2";   shift 2 ;;
    --github-secrets-json) GITHUB_SECRETS_JSON="$2"; shift 2 ;;
    --dry-run)             DRY_RUN="$2";             shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ -z "$APP_NAME" ] || [ -z "$ENV_LABEL" ] || [ -z "$CONTRACT_FILE" ]; then
  echo "Error: --app-name, --env-label, and --contract-file are required"
  exit 1
fi

if [ ! -f "$CONTRACT_FILE" ]; then
  echo "Error: Contract file not found: $CONTRACT_FILE"
  exit 1
fi

echo "========================================="
echo "Preflight Service Contract Validation"
echo "  app:            $APP_NAME"
echo "  env-label:      $ENV_LABEL"
echo "  contract:       $CONTRACT_FILE"
echo "  dry-run:        $DRY_RUN"
echo "========================================="
echo ""

# Load contract YAML and convert to JSON for jq processing
echo "Loading service contract..."
if ! CONTRACT_JSON=$(yq -o=json "$CONTRACT_FILE" 2>/dev/null); then
  echo "Error: Failed to parse contract file. Ensure yq is installed."
  exit 1
fi

# Get service entry from contract
SERVICE_CONTRACT=$(echo "$CONTRACT_JSON" | jq --arg svc "$APP_NAME" --arg env "$ENV_LABEL" \
  '.services[$svc][$env] // empty')

if [ -z "$SERVICE_CONTRACT" ] || [ "$SERVICE_CONTRACT" = "null" ]; then
  echo "⚠️  No contract found for $APP_NAME/$ENV_LABEL — skipping validation"
  echo "   (Tip: add entry to manifests/service-contracts.yml to enable checks)"
  exit 0
fi

REQUIRED_SECRETS=$(echo "$SERVICE_CONTRACT" | jq '.required_secrets // []')
REQUIRED_ENV=$(echo "$SERVICE_CONTRACT" | jq '.required_env // []')
PRESERVE_PATTERNS=$(echo "$SERVICE_CONTRACT" | jq '.preserve_patterns // []')
CRITICAL=$(echo "$SERVICE_CONTRACT" | jq '.critical // false')

REQUIRED_SECRETS_COUNT=$(echo "$REQUIRED_SECRETS" | jq 'length')
REQUIRED_ENV_COUNT=$(echo "$REQUIRED_ENV" | jq 'length')
PRESERVE_COUNT=$(echo "$PRESERVE_PATTERNS" | jq 'length')

echo "Contract details:"
echo "  Critical app:           $CRITICAL"
echo "  Required secrets:       $REQUIRED_SECRETS_COUNT"
echo "  Required env vars:      $REQUIRED_ENV_COUNT"
echo "  Preserve patterns:      $PRESERVE_COUNT"
echo ""

# Parse env file
echo "Loading environment file..."
CANONICAL_VARS="[]"
if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line="${raw_line%%$'\r'}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in \#*) continue ;; esac
    case "$trimmed" in *=*) ;; *) continue ;; esac
    key="${trimmed%%=*}"
    value="${trimmed#*=}"
    [ -n "$key" ] || continue
    CANONICAL_VARS=$(echo "$CANONICAL_VARS" | jq --arg k "$key" --arg v "$value" '. += [{key: $k, value: $v}]')
  done < "$ENV_FILE"
fi
CANONICAL_COUNT=$(echo "$CANONICAL_VARS" | jq 'length')
echo "  Env vars in file:       $CANONICAL_COUNT"
echo ""

# Check required secrets (from GitHub secrets)
echo "Checking required GitHub secrets..."
MISSING_SECRETS=0
while IFS= read -r secret_name; do
  SECRET_VALUE=$(echo "$GITHUB_SECRETS_JSON" | jq -r --arg k "$secret_name" '.[$k] // empty')
  if [ -z "$SECRET_VALUE" ]; then
    echo "  ✗ $secret_name — NOT FOUND in GitHub secrets"
    MISSING_SECRETS=$((MISSING_SECRETS + 1))
  else
    echo "  ✓ $secret_name"
  fi
done <<< "$(echo "$REQUIRED_SECRETS" | jq -r '.[]')"
echo ""

# Check required env vars (in env file)
echo "Checking required environment variables..."
MISSING_ENV=0
while IFS= read -r env_name; do
  ENV_VALUE=$(echo "$CANONICAL_VARS" | jq -r --arg k "$env_name" '.[] | select(.key == $k) | .value // empty')
  if [ -z "$ENV_VALUE" ]; then
    echo "  ✗ $env_name — NOT FOUND in env file"
    MISSING_ENV=$((MISSING_ENV + 1))
  else
    echo "  ✓ $env_name"
  fi
done <<< "$(echo "$REQUIRED_ENV" | jq -r '.[]')"
echo ""

# Fetch existing CapRover env vars (if credentials provided)
EXISTING_CAPROVER_ENV="[]"
if [ -n "$CAPROVER_URL" ] && [ -n "$CAPROVER_PASSWORD" ] && [ "$DRY_RUN" = "false" ]; then
  echo "Checking existing CapRover state..."
  TARGET_APP="${APP_NAME}-${ENV_LABEL}"

  TOKEN=$(caprover_login "$CAPROVER_URL" "$CAPROVER_PASSWORD" 2>/dev/null || echo "")
  if [ -n "$TOKEN" ]; then
    CURL_ARGS=()
    caprover_populate_curl_args "$CAPROVER_URL" CURL_ARGS

    ALL_DEFS=$(curl "${CURL_ARGS[@]}" -X GET "$CAPROVER_URL/api/v2/user/apps/appDefinitions" \
      -H "x-captain-auth: $TOKEN" 2>/dev/null || echo "{}")
    CAPROVER_DEF=$(echo "$ALL_DEFS" | jq --arg name "$TARGET_APP" '.data.appDefinitions[] | select(.appName == $name) // empty' 2>/dev/null || echo "")

    if [ -n "$CAPROVER_DEF" ] && [ "$CAPROVER_DEF" != "null" ]; then
      EXISTING_CAPROVER_ENV=$(echo "$CAPROVER_DEF" | jq '.envVars // []')
      echo "  Found $TARGET_APP in CapRover"
      echo "  Existing env vars: $(echo "$EXISTING_CAPROVER_ENV" | jq 'length')"
    else
      echo "  Note: $TARGET_APP not yet deployed to CapRover (new app)"
    fi
  fi
  echo ""
fi

# Check for vars that will be preserved (matching patterns from CapRover)
if [ "$(echo "$EXISTING_CAPROVER_ENV" | jq 'length')" -gt 0 ]; then
  echo "Checking for vars that will be preserved (pattern match)..."
  echo "$PRESERVE_PATTERNS" | jq -r '.[]' | while read -r pattern; do
    # Convert glob pattern to regex (e.g., 'TS_*' -> 'TS_.*')
    regex_pattern=$(echo "$pattern" | sed 's/\*/.*/g')
    matched=$(echo "$EXISTING_CAPROVER_ENV" | jq -r --arg pat "$regex_pattern" '.[] | select(.key | test($pat)) | .key')
    if [ -n "$matched" ]; then
      echo "  Pattern '$pattern':"
      echo "$matched" | sed 's/^/    ✓ /'
    fi
  done
  echo ""
fi

# Analyze and report findings
FAILED=0
WARNED=0

echo "Analysis:"
CANONICAL_KEYS=$(echo "$CANONICAL_VARS" | jq '[.[].key]')
CAPROVER_KEYS=$(echo "$EXISTING_CAPROVER_ENV" | jq '[.[].key]')
ORPHAN_VARS=$(echo "$EXISTING_CAPROVER_ENV" | jq --argjson ck "$CANONICAL_KEYS" '.[] | select(.key as $k | ($ck | any(. == $k)) | not) | .key' 2>/dev/null || echo "")

# Check if any orphaned vars exist (not in env file but in CapRover)
if [ -n "$ORPHAN_VARS" ]; then
  ORPHAN_COUNT=$(echo "$ORPHAN_VARS" | wc -l)
  echo "  ⚠️  $ORPHAN_COUNT vars exist in CapRover but not in env file (will be preserved):"
  echo "$ORPHAN_VARS" | sed 's/^/     - /'
  WARNED=1
fi

# Final verdict
echo ""
echo "========================================="
if [ "$MISSING_SECRETS" -gt 0 ] || [ "$MISSING_ENV" -gt 0 ]; then
  if [ "$CRITICAL" = "true" ]; then
    echo "❌ CRITICAL FAILURE: Missing required vars for critical app"
    echo "   Missing secrets: $MISSING_SECRETS"
    echo "   Missing env vars: $MISSING_ENV"
    echo ""
    echo "Action: Fix missing vars before retry"
    FAILED=1
  else
    echo "⚠️  WARNING: Missing optional vars"
    echo "   Missing secrets: $MISSING_SECRETS"
    echo "   Missing env vars: $MISSING_ENV"
    echo ""
    WARNED=1
  fi
else
  echo "✅ All required vars present"
fi

if [ "$WARNED" -eq 1 ] && [ "$FAILED" -eq 0 ]; then
  echo "⚠️  Warnings detected but deployment can proceed"
fi

echo "========================================="

exit $FAILED
