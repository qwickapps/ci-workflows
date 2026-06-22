#!/bin/bash
set -euo pipefail

# Local validation command for service contract dry-run
#
# Usage:
#   validate-service-contract.sh [--app-name <name>] [--env-label <label>]
#
# If no args provided, validates all services in manifest.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/.ci-workflows/manifests/service-contracts.yml"
PREFLIGHT_SCRIPT="$SCRIPT_DIR/preflight-service-contract.sh"

APP_FILTER=""
ENV_FILTER=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --app-name)  APP_FILTER="$2"; shift 2 ;;
    --env-label) ENV_FILTER="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ ! -f "$MANIFEST" ]; then
  echo "Error: manifest not found at $MANIFEST"
  exit 1
fi

if [ ! -f "$PREFLIGHT_SCRIPT" ]; then
  echo "Error: preflight script not found at $PREFLIGHT_SCRIPT"
  exit 1
fi

echo "Service Contract Validator (Dry-Run)"
echo "===================================="
echo ""

# Check if yq is available
if ! command -v yq &> /dev/null; then
  echo "Installing yq..."
  if [ "$(uname)" = "Darwin" ]; then
    brew install yq >/dev/null 2>&1 || true
  else
    # For Linux, download latest release
    curl -sL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
  fi
fi

# Load manifest and iterate through services
MANIFEST_JSON=$(yq -o=json "$MANIFEST" 2>/dev/null)

echo "$MANIFEST_JSON" | jq -r '.services | keys[]' | while read -r app_name; do
  if [ -n "$APP_FILTER" ] && [ "$app_name" != "$APP_FILTER" ]; then
    continue
  fi

  echo "$MANIFEST_JSON" | jq -r --arg svc "$app_name" '.services[$svc] | keys[]' | while read -r env_label; do
    if [ -n "$ENV_FILTER" ] && [ "$env_label" != "$ENV_FILTER" ]; then
      continue
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Service: $app_name / Environment: $env_label"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    SERVICE_CONTRACT=$(echo "$MANIFEST_JSON" | jq --arg svc "$app_name" --arg env "$env_label" '.services[$svc][$env]')

    CRITICAL=$(echo "$SERVICE_CONTRACT" | jq '.critical // false')
    REQUIRED_SECRETS=$(echo "$SERVICE_CONTRACT" | jq '.required_secrets // []')
    REQUIRED_ENV=$(echo "$SERVICE_CONTRACT" | jq '.required_env // []')
    PRESERVE_PATTERNS=$(echo "$SERVICE_CONTRACT" | jq '.preserve_patterns // []')
    NOTES=$(echo "$SERVICE_CONTRACT" | jq '.notes // ""')

    echo "Critical:          $CRITICAL"
    echo "Required secrets:  $(echo "$REQUIRED_SECRETS" | jq 'length')"
    echo "Required env vars: $(echo "$REQUIRED_ENV" | jq 'length')"
    echo "Preserve patterns: $(echo "$PRESERVE_PATTERNS" | jq 'length')"

    if [ "$(echo "$NOTES" | jq -r 'length')" -gt 0 ]; then
      echo ""
      echo "Notes:"
      echo "$NOTES" | jq -r . | sed 's/^/  /'
    fi

    echo ""
    echo "Required secrets:"
    echo "$REQUIRED_SECRETS" | jq -r '.[] | "  - \(.)"'

    echo ""
    echo "Required env vars:"
    echo "$REQUIRED_ENV" | jq -r '.[] | "  - \(.)"'

    echo ""
    echo "Preserve patterns:"
    echo "$PRESERVE_PATTERNS" | jq -r '.[] | "  - \(.)"'

    echo ""
  done
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Manifest validation complete"
echo ""
echo "To test a specific service deployment:"
echo "  $PREFLIGHT_SCRIPT --app-name <app> --env-label <label> \\"
echo "    --env-file <path> --contract-file $MANIFEST --dry-run true"
