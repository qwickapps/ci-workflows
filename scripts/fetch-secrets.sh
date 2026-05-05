#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: fetch-secrets.sh --base-url URL --token TOKEN --project PROJECT --env ENV --keys KEY[,KEY...] --env-file FILE

Fetches deploy-allowlisted secrets from QwickSecrets and writes KEY=value lines
to FILE. Secret values are masked for GitHub Actions logs and are never printed.
USAGE
}

BASE_URL="${QWICKSECRETS_URL:-}"
TOKEN="${QWICKSECRETS_DEPLOY_READ_TOKEN:-}"
PROJECT=""
ENVIRONMENT=""
KEYS_CSV=""
ENV_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)
      BASE_URL="${2:-}"
      shift 2
      ;;
    --token)
      TOKEN="${2:-}"
      shift 2
      ;;
    --project)
      PROJECT="${2:-}"
      shift 2
      ;;
    --env)
      ENVIRONMENT="${2:-}"
      shift 2
      ;;
    --keys)
      KEYS_CSV="${2:-}"
      shift 2
      ;;
    --env-file)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$BASE_URL" || -z "$TOKEN" || -z "$PROJECT" || -z "$ENVIRONMENT" || -z "$KEYS_CSV" || -z "$ENV_FILE" ]]; then
  usage
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to fetch deploy secrets" >&2
  exit 2
fi

TMP_RESPONSE="$(mktemp)"
TMP_BODY="$(mktemp)"
trap 'rm -f "$TMP_RESPONSE" "$TMP_BODY"' EXIT

jq -n \
  --arg project "$PROJECT" \
  --arg env "$ENVIRONMENT" \
  --arg keys "$KEYS_CSV" \
  '{project: $project, env: $env, keys: ($keys | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))}' \
  > "$TMP_BODY"

HTTP_STATUS="$(curl -sS \
  -o "$TMP_RESPONSE" \
  -w '%{http_code}' \
  -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -H 'Cache-Control: no-store' \
  --data-binary "@${TMP_BODY}" \
  "${BASE_URL%/}/v1/deploy/secrets")"

if [[ "$HTTP_STATUS" != "200" ]]; then
  ERROR_MESSAGE="$(jq -r '.error // empty' "$TMP_RESPONSE" 2>/dev/null || true)"
  if [[ -n "$ERROR_MESSAGE" ]]; then
    echo "QwickSecrets deploy fetch failed with HTTP ${HTTP_STATUS}: ${ERROR_MESSAGE}" >&2
  else
    echo "QwickSecrets deploy fetch failed with HTTP ${HTTP_STATUS}" >&2
  fi
  exit 1
fi

mkdir -p "$(dirname "$ENV_FILE")"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE"

IFS=',' read -r -a REQUESTED_KEYS <<< "$KEYS_CSV"
for raw_key in "${REQUESTED_KEYS[@]}"; do
  key="$(printf '%s' "$raw_key" | xargs)"
  [[ -z "$key" ]] && continue

  value="$(jq -r --arg key "$key" '.secrets[$key].value // empty' "$TMP_RESPONSE")"
  if [[ -z "$value" ]]; then
    echo "QwickSecrets response did not include ${key}" >&2
    exit 1
  fi

  echo "::add-mask::${value}"
  printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
done

echo "Fetched deploy secrets for ${PROJECT}/${ENVIRONMENT}: ${KEYS_CSV}"
