#!/usr/bin/env bash
# Enforce the per-app stable-slot host policy. Unlisted apps are allowed.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <app_name> <environment> <resolved_caprover_url>" >&2
  exit 64
fi

APP="$1"
ENVIRONMENT="$2"
URL="$3"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY_FILE="$ROOT_DIR/config/stable-host-policy.json"

case "$APP" in
  *[!a-zA-Z0-9-]*|""|-*|*-) echo "ERROR: app_name must be a slug" >&2; exit 64 ;;
esac
APP="$(printf '%s' "$APP" | tr '[:upper:]' '[:lower:]')"
while :; do
  case "$APP" in
    *-live) APP="${APP%-live}" ;;
    *-uat) APP="${APP%-uat}" ;;
    *-stable) APP="${APP%-stable}" ;;
    *) break ;;
  esac
done

normalize_host() {
  printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://##' | sed -E 's#[:/].*$##' | tr '[:upper:]' '[:lower:]'
}
HOST="$(normalize_host "$URL")"
OCI_MAIN_HOST="$(normalize_host "${OCI_MAIN_CAPROVER_URL:-captain.app.qwickforge.com}")"
case "$HOST" in
  "$OCI_MAIN_HOST") HOST_KEY=OCI_MAIN ;;
  macmini-devserver) HOST_KEY=MACMINI_DEVSERVER ;;
  *) HOST_KEY=UNKNOWN ;;
esac

ALLOWED="$(python3 - "$POLICY_FILE" "$APP" "$ENVIRONMENT" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    policy = json.load(f)
print(','.join(policy.get(sys.argv[2], {}).get(sys.argv[3], [])))
PY
)"
[ -z "$ALLOWED" ] && exit 0
case ",$ALLOWED," in
  *",$HOST_KEY,"*) exit 0 ;;
  *)
    if [ "$HOST_KEY" = "OCI_MAIN" ]; then
      echo "::error::infra#41: ${APP}-stable must run on macmini-devserver, not oci-main" >&2
    else
      echo "::error::infra#41: ${APP}-stable must run on ${ALLOWED}; resolved: ${HOST_KEY}" >&2
    fi
    exit 1
    ;;
esac
