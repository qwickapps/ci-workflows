#!/usr/bin/env bash
# Env renderer for .github/workflows/topology-canary-proof.yml (t_cf80e6ab).
#
# Invoked by deploy-app.yml as: <script> <environment> <app_name> <output_path>
# Writes only non-secret values. The REJECTED canary declares the canonical
# qwickapps-mcp Tailscale hostname so deploy-app.yml's "Topology admission
# before mutation" step must deny the tuple (qwickway image on oci-main for a
# hostname the registry pins to oci-gateway) before any CapRover write.
set -euo pipefail

ENVIRONMENT="${1:?environment required}"
APP_NAME="${2:?app_name required}"
OUT="${3:?output path required}"

case "$APP_NAME" in
  topology-canary-reject)
    {
      echo "TS_HOSTNAME=qwickapps-mcp"
      echo "CANARY_KIND=topology-reject"
      echo "CANARY_ENVIRONMENT=${ENVIRONMENT}"
    } > "$OUT"
    ;;
  *)
    echo "::error::topology-canary-env.sh: unknown canary app '${APP_NAME}'; refusing to render" >&2
    exit 1
    ;;
esac
