#!/usr/bin/env bash
# Fail closed until the CapRover Swarm service is running only the image digest
# requested by the deployment. A successful HTTP health response alone is not
# evidence: it may be served by an older task when CapRover accepted no deploy.
set -euo pipefail

SSH_HOST="oci-main"
SERVICE=""
IMAGE_REF=""
MAX_ATTEMPTS=15
SLEEP_SECONDS=10

usage() {
  echo "Usage: $0 --service <swarm-service> --image-ref <image@sha256:digest> [--ssh-host <host>] [--max-attempts <n>] [--sleep <seconds>]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service) SERVICE="${2:-}"; shift 2 ;;
    --image-ref) IMAGE_REF="${2:-}"; shift 2 ;;
    --ssh-host) SSH_HOST="${2:-}"; shift 2 ;;
    --max-attempts) MAX_ATTEMPTS="${2:-}"; shift 2 ;;
    --sleep) SLEEP_SECONDS="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ "$SERVICE" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "ERROR: invalid service name" >&2; exit 2; }
[[ "$SSH_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "ERROR: invalid SSH host" >&2; exit 2; }
[[ "$IMAGE_REF" =~ ^.+@sha256:[a-f0-9]{64}$ ]] || { echo "ERROR: image_ref must be immutable (<image>@sha256:<64 lowercase hex>), got '$IMAGE_REF'" >&2; exit 2; }
[[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --max-attempts must be a positive integer" >&2; exit 2; }
[[ "$SLEEP_SECONDS" =~ ^[0-9]+$ ]] || { echo "ERROR: --sleep must be a non-negative integer" >&2; exit 2; }

EXPECTED_DIGEST="${IMAGE_REF##*@}"
REMOTE_CMD="docker service ps --no-trunc --format '{{.CurrentState}}|{{.DesiredState}}|{{.Image}}' '$SERVICE'"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  echo "Attempt $attempt/$MAX_ATTEMPTS: checking $SERVICE task images on $SSH_HOST"
  if ! TASKS="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_HOST" "$REMOTE_CMD" 2>&1)"; then
    echo "WARNING: unable to read service tasks: $TASKS" >&2
  else
    running=0
    matching=0
    mismatching=0
    while IFS='|' read -r current desired image; do
      [[ -n "$current" ]] || continue
      if [[ "$current" == Running* ]] && [[ "$desired" == Running* ]]; then
        running=$((running + 1))
        if [[ "$image" == *"$EXPECTED_DIGEST"* ]]; then
          matching=$((matching + 1))
        else
          mismatching=$((mismatching + 1))
          echo "WARNING: running task has unexpected image: $image" >&2
        fi
      fi
    done <<< "$TASKS"

    if [[ "$matching" -gt 0 && "$mismatching" -eq 0 ]]; then
      echo "Verified $matching running task(s) for $SERVICE use requested digest $EXPECTED_DIGEST"
      exit 0
    fi
    echo "Waiting for requested service image: running=$running matching=$matching mismatching=$mismatching expected=$EXPECTED_DIGEST" >&2
  fi

  if [[ "$attempt" -lt "$MAX_ATTEMPTS" ]]; then
    sleep "$SLEEP_SECONDS"
  fi
done

echo "ERROR: $SERVICE never reached an all-running task set for requested image digest $EXPECTED_DIGEST after $MAX_ATTEMPTS attempts" >&2
exit 1
