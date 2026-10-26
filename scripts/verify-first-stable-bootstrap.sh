#!/usr/bin/env bash
# Fail-closed proof for the one permitted stable-slot bootstrap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ghcr-tag-history.sh"
source "$SCRIPT_DIR/lib/check-run-binding.sh"
source "$SCRIPT_DIR/lib/first-stable-evidence.sh"

GITHUB_TOKEN="" REPO="" APP_NAME="" SHA="" IMAGE_REF="" IMAGE_BASE=""
usage() { echo "Usage: $0 --github-token <token> --repo <owner/repo> --app-name <app> --sha <sha> --image-ref <base>@sha256:<digest> --image-base <base>" >&2; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --github-token) GITHUB_TOKEN="$2"; shift 2;; --repo) REPO="$2"; shift 2;;
    --app-name) APP_NAME="$2"; shift 2;; --sha) SHA="$2"; shift 2;;
    --image-ref) IMAGE_REF="$2"; shift 2;; --image-base) IMAGE_BASE="$2"; shift 2;;
    -h|--help) usage; exit 0;; *) echo "::error::unknown option: $1" >&2; usage; exit 2;;
  esac
done
for v in GITHUB_TOKEN REPO APP_NAME SHA IMAGE_REF IMAGE_BASE; do
  [ -n "${!v}" ] || { echo "::error::missing required argument: $v" >&2; exit 2; }
done
[[ "$IMAGE_REF" =~ ^.+@sha256:[a-f0-9]{64}$ ]] || { echo "::error::first-stable-bootstrap REFUSED (image_not_digest_pinned): image_ref must be digest-pinned" >&2; exit 1; }
export GH_TOKEN="$GITHUB_TOKEN"
refuse() { echo "::error::first-stable-bootstrap REFUSED ($1): $2" >&2; exit 1; }

IMAGE_NAME="${IMAGE_BASE##*/}"
if ! ghcr_package_readable "qwickapps" "$IMAGE_NAME"; then
  refuse "stable_tag_visibility_probe_failed" "could not prove read visibility for ${IMAGE_BASE} before treating :stable as absent"
fi
if ! stable_history="$(ghcr_tag_history_exists "qwickapps" "$IMAGE_NAME" stable)"; then
  refuse "stable_tag_probe_failed" "could not prove whether ${IMAGE_BASE}:stable exists"
fi
[ "$stable_history" = false ] || refuse "stable_tag_already_exists" "${IMAGE_BASE}:stable already exists; use the normal stable path"

source_digest="$(docker buildx imagetools inspect --format '{{.Digest}}' "$IMAGE_REF" 2>/dev/null)" || refuse "source_digest_probe_failed" "could not resolve digest for image_ref"
release_digest="$(docker buildx imagetools inspect --format '{{.Digest}}' "${IMAGE_BASE}:release" 2>/dev/null)" || refuse "release_digest_probe_failed" "could not resolve digest for ${IMAGE_BASE}:release"
[[ "$source_digest" =~ ^sha256:[a-f0-9]{64}$ ]] || refuse "source_digest_invalid" "source digest was malformed"
[[ "$release_digest" =~ ^sha256:[a-f0-9]{64}$ ]] || refuse "release_digest_invalid" "release digest was malformed"
[ "$source_digest" = "$release_digest" ] || refuse "release_digest_mismatch" "image_ref digest does not equal ${IMAGE_BASE}:release"

# The pinned digest is eligible only after BOTH the build-stage deployment and
# the subsequent UAT deployment wrote independently GitHub-bound success
# records for this exact caller commit and manifest digest. Missing evidence,
# a forged record, pagination loss, or an API/binding ambiguity all refuse.
if ! first_stable_evidence_require "$REPO" "$APP_NAME" "$SHA" "$source_digest" build; then
  refuse "build_proof_missing_or_invalid" "source image lacks bound build qualification"
fi
if ! first_stable_evidence_require "$REPO" "$APP_NAME" "$SHA" "$source_digest" uat; then
  refuse "uat_proof_missing_or_invalid" "source image lacks bound UAT qualification"
fi

check_name="blue-green/first-stable-bootstrap/${APP_NAME}"
encoded="$(jq -rn --arg n "$check_name" '$n | @uri')"
response="$(gh api "repos/${REPO}/commits/${SHA}/check-runs?check_name=${encoded}&per_page=100" 2>&1)" || refuse "marker_query_failed" "$response"
printf '%s' "$response" | jq -e 'type == "object"' >/dev/null 2>&1 || refuse "marker_query_failed" "check-runs response was not an object"
total="$(printf '%s' "$response" | jq -r '.total_count // 0')"
returned="$(printf '%s' "$response" | jq -r '(.check_runs // []) | length')"
[ "$returned" -ge "$total" ] || refuse "marker_query_incomplete" "check-runs response was truncated"
creator_step="Record first-stable bootstrap authorization"
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  app_slug="$(printf '%s' "$candidate" | jq -r '.app.slug // ""')"
  external_id="$(printf '%s' "$candidate" | jq -r '.external_id // ""')"
  if check_run_binding_verify "$REPO" "$SHA" "$app_slug" "$external_id" "$creator_step" " / deploy-stable"; then
    refuse "bootstrap_already_used" "a verified ${check_name} marker already exists"
  else
    rc=$?
    [ "$rc" -eq 1 ] || refuse "marker_binding_unverifiable" "a candidate marker could not be verified"
  fi
done < <(printf '%s' "$response" | jq -c --arg repo "$REPO" --arg app "$APP_NAME" --arg sha "$SHA" --arg source "$source_digest" --arg release "$release_digest" '
  .check_runs[]? | select(.conclusion == "success") | (.output.text // "" | fromjson? // {}) as $p |
  select($p.repo == $repo and $p.app_name == $app and $p.sha == $sha and $p.source_digest == $source and $p.release_digest == $release) |
  .')

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  { echo "source_digest=$source_digest"; echo "release_digest=$release_digest"; } >> "$GITHUB_OUTPUT"
fi
printf 'source_digest=%s\nrelease_digest=%s\n' "$source_digest" "$release_digest"
