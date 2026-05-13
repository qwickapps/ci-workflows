#!/usr/bin/env bash
#
# deploy-evidence.sh — emit the audit evidence JSON for a deploy run.
#
# Closes part of qwickapps/ci-workflows#6 ("Workflow outputs include
# commit, image digest, target, actor, validation result, and
# rollback target"). The reusable deploy.yml's evidence job calls
# this script after the deploy completes (success OR failure) and
# uploads the resulting JSON as a workflow artifact.
#
# Usage:
#   ./deploy-evidence.sh \
#     --commit          <git-sha> \
#     --target          <env-label> \
#     --actor           <github-actor> \
#     --image-ref       <ghcr.io/owner/img:tag> \
#     [--image-digest   <sha256:...>] \
#     [--rollback-target <ghcr.io/owner/img:prev>] \
#     --deploy-result   <success|failure|cancelled|skipped> \
#     --validation      <pass|fail|skipped> \
#     [--extra-json     <{"key":"value"}>]
#
# Emits the evidence record to stdout (single-line JSON) so callers
# that don't want the file form can pipe it elsewhere. Stderr carries
# the human-readable progress; stdout stays JSON-only.

set -euo pipefail

COMMIT=""
TARGET=""
ACTOR=""
IMAGE_REF=""
IMAGE_DIGEST=""
ROLLBACK_TARGET=""
DEPLOY_RESULT=""
VALIDATION=""
EXTRA_JSON='{}'

usage() {
  cat >&2 <<USAGE
usage: $0 \\
  --commit          <git-sha> \\
  --target          <env-label> \\
  --actor           <github-actor> \\
  --image-ref       <ghcr.io/owner/img:tag> \\
  [--image-digest   <sha256:...>] \\
  [--rollback-target <ghcr.io/owner/img:prev>] \\
  --deploy-result   <success|failure|cancelled|skipped> \\
  --validation      <pass|fail|skipped> \\
  [--extra-json     <{"key":"value"}>]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit)          COMMIT="$2";          shift 2 ;;
    --target)          TARGET="$2";          shift 2 ;;
    --actor)           ACTOR="$2";           shift 2 ;;
    --image-ref)       IMAGE_REF="$2";       shift 2 ;;
    --image-digest)    IMAGE_DIGEST="$2";    shift 2 ;;
    --rollback-target) ROLLBACK_TARGET="$2"; shift 2 ;;
    --deploy-result)   DEPLOY_RESULT="$2";   shift 2 ;;
    --validation)      VALIDATION="$2";      shift 2 ;;
    --extra-json)      EXTRA_JSON="$2";      shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *)
      echo "::error::Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

# ── Validate required arguments ──────────────────────────────────────────
for var in COMMIT TARGET ACTOR IMAGE_REF DEPLOY_RESULT VALIDATION; do
  if [ -z "${!var}" ]; then
    flag="$(printf '%s' "$var" | tr '[:upper:]_' '[:lower:]-')"
    echo "::error::missing required argument: --$flag" >&2
    usage
    exit 2
  fi
done

case "$VALIDATION" in
  pass|fail|skipped) ;;
  *)
    echo "::error::invalid --validation '$VALIDATION'; must be pass|fail|skipped" >&2
    exit 2
    ;;
esac

case "$DEPLOY_RESULT" in
  success|failure|cancelled|skipped) ;;
  *)
    echo "::error::invalid --deploy-result '$DEPLOY_RESULT'; must be success|failure|cancelled|skipped" >&2
    exit 2
    ;;
esac

# Validate the extra-json blob actually parses; reject silently-broken
# payloads at emit time rather than landing them in the audit log.
if ! printf '%s' "$EXTRA_JSON" | jq -e . >/dev/null 2>&1; then
  echo "::error::--extra-json is not valid JSON: $EXTRA_JSON" >&2
  exit 2
fi
# And it must be an object (not an array, number, etc.) so
# .caller_metadata is mergeable.
if [ "$(printf '%s' "$EXTRA_JSON" | jq -r 'type')" != "object" ]; then
  echo "::error::--extra-json must be a JSON object; got $(printf '%s' "$EXTRA_JSON" | jq -r 'type')" >&2
  exit 2
fi

# ── Build the envelope ──────────────────────────────────────────────────
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"

jq -nc \
  --arg commit          "$COMMIT" \
  --arg target          "$TARGET" \
  --arg actor           "$ACTOR" \
  --arg image_ref       "$IMAGE_REF" \
  --arg image_digest    "$IMAGE_DIGEST" \
  --arg rollback_target "$ROLLBACK_TARGET" \
  --arg deploy_result   "$DEPLOY_RESULT" \
  --arg validation      "$VALIDATION" \
  --argjson extra       "$EXTRA_JSON" \
  --arg emitted_at      "$NOW" \
  '
  {
    commit:            $commit,
    target:            $target,
    actor:             $actor,
    image_ref:         $image_ref,
    deploy_result:     $deploy_result,
    validation_result: $validation,
    emitted_at:        $emitted_at
  }
  # Optional fields: only emit the key when the caller supplied a value.
  # Bare `select(. != "")` would yield empty and collapse the whole
  # object, so we splice in conditionally.
  + (if $image_digest    != "" then {image_digest:    $image_digest}    else {} end)
  + (if $rollback_target != "" then {rollback_target: $rollback_target} else {} end)
  # Caller metadata under a separate key so it cannot collide with the
  # contract-required outputs.
  + (if ($extra | length) > 0 then {caller_metadata: $extra} else {} end)
  '
