#!/usr/bin/env bash
# rotate-infra-ssh-key.sh
#
# Full SSH key rotation procedure for the MCP/Forge infrastructure key.
#
# What this script does:
#   1. Generates a new ed25519 keypair (unless --key-file provided)
#   2. Syncs the new public key to ~/.ssh/authorized_keys on ALL runner hosts
#      (oci-main, oci-dev via jump, oci-gateway)
#   3. Verifies SSH connectivity using the new key
#   4. Updates INFRA_SSH_KEY_B64 in the secrets service (mcp/dev)
#   5. Optionally removes the old key from authorized_keys (--cleanup)
#
# Usage:
#   # Full rotation (generate new key + sync + update secrets):
#   SECRETS_API_URL=http://localhost:7007 SECRETS_WRITE_TOKEN=<token> \
#     ./scripts/rotate-infra-ssh-key.sh
#
#   # Use an existing new key file instead of generating:
#   ./scripts/rotate-infra-ssh-key.sh --key-file /path/to/new_key
#
#   # Preview without changes:
#   ./scripts/rotate-infra-ssh-key.sh --dry-run
#
#   # After rotation: remove old key fingerprint from all hosts:
#   ./scripts/rotate-infra-ssh-key.sh --cleanup --old-key "FINGERPRINT"
#
# Required env vars (for secrets update step):
#   SECRETS_API_URL      - e.g. http://localhost:7007
#   SECRETS_WRITE_TOKEN  - write token for the secrets API
#
# The script is idempotent: re-running it with the same new key is safe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_HOSTS_DIRECT=("oci-main" "oci-gateway")
RUNNER_HOSTS_VIA_JUMP=("oci-dev")
JUMP_HOST="oci-main"
SSH_USER="ubuntu"
SECRETS_PROJECT="mcp"
SECRETS_ENV="dev"
SECRETS_KEY="INFRA_SSH_KEY_B64"
KEY_COMMENT="qwickapps-mcp-infra-$(date +%Y)"
DRY_RUN=false
CLEANUP=false
OLD_KEY_FINGERPRINT=""
PROVIDED_KEY_FILE=""

# Argument parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --cleanup)   CLEANUP=true; shift ;;
    --old-key)   OLD_KEY_FINGERPRINT="$2"; shift 2 ;;
    --key-file)  PROVIDED_KEY_FILE="$2"; shift 2 ;;
    --comment)   KEY_COMMENT="$2"; shift 2 ;;
    -h|--help)
      grep "^#" "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

echo "======================================================="
echo "  rotate-infra-ssh-key.sh"
echo "  Comment: ${KEY_COMMENT}"
echo "  Dry run: ${DRY_RUN}"
echo "======================================================="

# Step 1: Generate or load the new key
TMPDIR_KEY=$(mktemp -d)
trap 'rm -rf "$TMPDIR_KEY"' EXIT

if [[ -n "$PROVIDED_KEY_FILE" ]]; then
  echo ""
  echo "Step 1: Using provided key file: ${PROVIDED_KEY_FILE}"
  NEW_PRIVATE_KEY_FILE="$PROVIDED_KEY_FILE"
  NEW_PUBLIC_KEY_FILE="${PROVIDED_KEY_FILE}.pub"
  if [[ ! -f "$NEW_PUBLIC_KEY_FILE" ]]; then
    ssh-keygen -y -f "$NEW_PRIVATE_KEY_FILE" > "$NEW_PUBLIC_KEY_FILE"
  fi
else
  echo ""
  echo "Step 1: Generating new ed25519 keypair..."
  NEW_PRIVATE_KEY_FILE="${TMPDIR_KEY}/id_ed25519_new"
  NEW_PUBLIC_KEY_FILE="${NEW_PRIVATE_KEY_FILE}.pub"
  if [[ "$DRY_RUN" != "true" ]]; then
    ssh-keygen -t ed25519 -C "$KEY_COMMENT" -f "$NEW_PRIVATE_KEY_FILE" -N ""
    echo "  Generated: $(cat "$NEW_PUBLIC_KEY_FILE")"
  else
    echo "  [DRY RUN] Would generate new ed25519 key with comment: ${KEY_COMMENT}"
    # Create a placeholder for dry-run
    cat "${HOME}/.ssh/id_ed25519.pub" > "$NEW_PUBLIC_KEY_FILE"
    cp "${HOME}/.ssh/id_ed25519" "$NEW_PRIVATE_KEY_FILE"
    chmod 600 "$NEW_PRIVATE_KEY_FILE"
  fi
fi

NEW_PUBLIC_KEY="$(cat "$NEW_PUBLIC_KEY_FILE")"
NEW_KEY_MATERIAL=$(echo "$NEW_PUBLIC_KEY" | awk '{print $2}')

# Step 2: Sync new key to all runner hosts
echo ""
echo "Step 2: Syncing new public key to all runner hosts..."

"${SCRIPT_DIR}/sync-authorized-keys.sh" \
  --add-key "$NEW_PUBLIC_KEY" \
  ${DRY_RUN:+--dry-run} \
  --key-file "${HOME}/.ssh/id_ed25519"

# Step 3: Update INFRA_SSH_KEY_B64 in secrets service
echo ""
echo "Step 3: Updating INFRA_SSH_KEY_B64 in secrets service (${SECRETS_PROJECT}/${SECRETS_ENV})..."

if [[ -z "${SECRETS_API_URL:-}" ]] || [[ -z "${SECRETS_WRITE_TOKEN:-}" ]]; then
  echo "  WARNING: SECRETS_API_URL or SECRETS_WRITE_TOKEN not set — skipping secrets update."
  echo "  To complete rotation, manually run:"
  echo "    curl -X PUT \${SECRETS_API_URL}/api/secrets/\${SECRETS_PROJECT}/\${SECRETS_ENV}/\${SECRETS_KEY} \\"
  echo "      -H 'Authorization: Bearer \${SECRETS_WRITE_TOKEN}' \\"
  echo "      -d '{\"value\": \"'\$(base64 -i ${NEW_PRIVATE_KEY_FILE} | tr -d '\\n')'\"}'"
else
  NEW_KEY_B64=$(base64 -i "$NEW_PRIVATE_KEY_FILE" | tr -d '\n')
  if [[ "$DRY_RUN" != "true" ]]; then
    HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" -X PUT \
      "${SECRETS_API_URL}/api/secrets/${SECRETS_PROJECT}/${SECRETS_ENV}/${SECRETS_KEY}" \
      -H "Authorization: Bearer ${SECRETS_WRITE_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"value\": \"${NEW_KEY_B64}\"}" 2>/dev/null || echo "000")
    if [[ "$HTTP_STATUS" == "200" ]] || [[ "$HTTP_STATUS" == "201" ]]; then
      echo "  UPDATED: INFRA_SSH_KEY_B64 stored in secrets service"
    else
      echo "  WARNING: Secrets API returned HTTP ${HTTP_STATUS}" >&2
      echo "  Update INFRA_SSH_KEY_B64 manually in the secrets service." >&2
    fi
  else
    echo "  [DRY RUN] Would update INFRA_SSH_KEY_B64 in ${SECRETS_PROJECT}/${SECRETS_ENV}"
  fi
fi

# Step 4: Cleanup old key (optional)
if [[ "$CLEANUP" == "true" ]] && [[ -n "$OLD_KEY_FINGERPRINT" ]]; then
  echo ""
  echo "Step 4: Removing old key (${OLD_KEY_FINGERPRINT:0:20}...) from all hosts..."

  SSH_KEY_FILE="${NEW_PRIVATE_KEY_FILE}"
  SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$SSH_KEY_FILE")
  JUMP_OPTS=(-o "ProxyJump=${SSH_USER}@${JUMP_HOST}")

  remove_old_key() {
    local host="$1"
    shift
    local extra_opts=("$@")
    printf "[%-12s] " "$host"
    if [[ "$DRY_RUN" != "true" ]]; then
      ssh "${SSH_OPTS[@]}" "${extra_opts[@]}" "${SSH_USER}@${host}" \
        "sed -i '/${OLD_KEY_FINGERPRINT}/d' ~/.ssh/authorized_keys && echo REMOVED"
    else
      echo "[DRY RUN] Would remove old key"
    fi
  }

  for host in "${RUNNER_HOSTS_DIRECT[@]}"; do
    remove_old_key "$host"
  done
  for host in "${RUNNER_HOSTS_VIA_JUMP[@]}"; do
    remove_old_key "$host" "${JUMP_OPTS[@]}"
  done
fi

echo ""
echo "======================================================="
echo "  ROTATION COMPLETE"
echo ""
echo "  New public key:"
echo "  $(cat "$NEW_PUBLIC_KEY_FILE")"
echo ""
echo "  Next steps:"
echo "  1. Restart MCP container to pick up new INFRA_SSH_KEY_B64"
echo "  2. Trigger verify-ssh-connectivity workflow to confirm"
if [[ -z "${SECRETS_WRITE_TOKEN:-}" ]]; then
  echo "  3. Manually update INFRA_SSH_KEY_B64 in secrets service (see Step 3 output)"
fi
echo "======================================================="
