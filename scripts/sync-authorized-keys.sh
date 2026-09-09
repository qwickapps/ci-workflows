#!/usr/bin/env bash
# sync-authorized-keys.sh
#
# Ensures a given SSH public key is present in ~/.ssh/authorized_keys
# on ALL runner hosts (oci-main, oci-dev, oci-gateway).
#
# Run this immediately after any SSH key rotation to prevent
# SSH Permission Denied incidents on runner hosts.
#
# Usage:
#   # Add current macmini key to all hosts (most common after rotation):
#   ./scripts/sync-authorized-keys.sh
#
#   # Add a specific key:
#   ./scripts/sync-authorized-keys.sh --add-key "ssh-ed25519 AAAA... label"
#
#   # Preview without making changes:
#   ./scripts/sync-authorized-keys.sh --dry-run
#
# Requirements:
#   - SSH access from macmini to oci-main, oci-gateway (direct)
#   - SSH access to oci-dev via oci-main jump host
#   - ~/.ssh/id_ed25519 present (macmini key)

set -euo pipefail

RUNNER_HOSTS_DIRECT=("oci-main" "oci-gateway")
RUNNER_HOSTS_VIA_JUMP=("oci-dev")
JUMP_HOST="oci-main"
SSH_USER="ubuntu"
SSH_KEY_FILE="${SSH_KEY_FILE:-${HOME}/.ssh/id_ed25519}"
DRY_RUN=false
NEW_KEY=""

# Argument parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --add-key)   NEW_KEY="$2"; shift 2 ;;
    --key-file)  NEW_KEY="$(cat "$2")"; shift 2 ;;
    -h|--help)
      grep "^#" "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Default: use current macmini public key
if [[ -z "$NEW_KEY" ]]; then
  NEW_KEY="$(cat "${SSH_KEY_FILE}.pub")"
fi

KEY_MATERIAL=$(echo "$NEW_KEY" | awk '{print $2}')
KEY_LABEL=$(echo "$NEW_KEY" | awk '{print $3}')

echo "======================================================="
echo "  sync-authorized-keys.sh"
echo "  Key:  ${KEY_LABEL}"
echo "  Dry run: ${DRY_RUN}"
echo "======================================================="

SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=15 -i "$SSH_KEY_FILE")

# Helper: ensure key is on a host
ensure_key() {
  local host="$1"
  local display="${2:-$host}"
  shift 2
  local extra_opts=("$@")

  printf "\n[%-12s] " "$display"

  if ssh "${SSH_OPTS[@]}" "${extra_opts[@]}" "${SSH_USER}@${host}" \
      "grep -qF '${KEY_MATERIAL}' ~/.ssh/authorized_keys" 2>/dev/null; then
    echo "OK (key already present)"
    return 0
  fi

  echo "MISSING"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "             [DRY RUN] would append: ${KEY_LABEL}"
    return 0
  fi

  ssh "${SSH_OPTS[@]}" "${extra_opts[@]}" "${SSH_USER}@${host}" \
    "echo '${NEW_KEY}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
  echo "             ADDED: ${KEY_LABEL}"
}

# Helper: verify SSH connectivity
verify_ssh() {
  local host="$1"
  local display="${2:-$host}"
  shift 2
  local extra_opts=("$@")

  printf "[%-12s] " "$display"
  if result=$(ssh "${SSH_OPTS[@]}" "${extra_opts[@]}" "${SSH_USER}@${host}" \
      "hostname" 2>&1); then
    echo "PASS (host=${result})"
    return 0
  else
    echo "FAIL — ${result}" >&2
    return 1
  fi
}

# Step 1: Ensure key on all hosts
echo ""
echo "Step 1: Ensuring key is present on all runner hosts..."

for host in "${RUNNER_HOSTS_DIRECT[@]}"; do
  ensure_key "$host" "$host"
done

JUMP_OPTS=(-o "ProxyJump=${SSH_USER}@${JUMP_HOST}")
for host in "${RUNNER_HOSTS_VIA_JUMP[@]}"; do
  ensure_key "$host" "${host}(jump)" "${JUMP_OPTS[@]}"
done

# Step 2: Verify connectivity
echo ""
echo "Step 2: Verifying SSH connectivity..."

FAILED=0
for host in "${RUNNER_HOSTS_DIRECT[@]}"; do
  verify_ssh "$host" "$host" || FAILED=$((FAILED + 1))
done
for host in "${RUNNER_HOSTS_VIA_JUMP[@]}"; do
  verify_ssh "$host" "${host}(jump)" "${JUMP_OPTS[@]}" || FAILED=$((FAILED + 1))
done

echo ""
echo "======================================================="
if [[ $FAILED -eq 0 ]]; then
  echo "  SUCCESS: All runner hosts verified reachable."
else
  echo "  FAILED: ${FAILED} host(s) failed connectivity check." >&2
  echo "  Manual fix: ssh ubuntu@<host> and check authorized_keys" >&2
  exit 1
fi
