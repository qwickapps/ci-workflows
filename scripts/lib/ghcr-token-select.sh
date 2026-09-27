#!/usr/bin/env bash

# ci-workflows#204: shared ephemeral-vs-legacy GHCR token selection.
#
# Before #204, deploy-app.yml fed every GHCR operation
# `secrets.GHCR_PULL_TOKEN || secrets.GITHUB_TOKEN` (and the PUSH
# equivalent). That `||` only fires when the secret is UNSET -- a SET but
# STALE PAT still wins and the job fails, even though the job's own
# ephemeral github.token already has the permissions it needs (live
# example: qwickapps/secrets run 36272536825, `verify-provenance` 403'd on
# a stale GHCR_PULL_TOKEN while its own github.token could have pulled the
# image just fine).
#
# This library answers "which of these candidate tokens can actually pull
# this image from ghcr.io right now" by hitting the registry directly
# (token endpoint + manifest HEAD/GET), instead of trusting "is the secret
# set" as a proxy for "does the secret still work". Preference order is
# entirely up to the caller -- this file tries candidates in the order it's
# given them, and returns the first one that works.
#
# No function here ever prints a token VALUE to stdout/stderr -- only
# caller-supplied LABELS (e.g. "github.token", "GHCR_PULL_TOKEN") are ever
# echoed, so job logs can say which source was chosen without exposing what
# it was.

set -euo pipefail

# ghcr_parse_image_ref <image_ref>
#
# Parses a (possibly digest-pinned) ghcr.io image reference into the three
# pieces ghcr_probe_pull_token/ghcr_select_token actually need, printed as
# three lines: owner, package, reference. Callers that derived "reference"
# via `${IMAGE_REF##*:}` alone get the wrong value for a digest-pinned ref
# like ghcr.io/qwickapps/img-x@sha256:abcd... (that pattern strips to just
# the hex, dropping the "sha256:" prefix ghcr.io's manifest endpoint
# requires) -- this function exists so every call site parses the same way.
#
# - A leading "ghcr.io/" is stripped if present.
# - If "@" is present, the reference is everything after the LAST "@"
#   (e.g. "sha256:abcd...") -- a digest always wins over any tag also
#   present in the same ref (e.g. "img-x:tag@sha256:...").
# - Otherwise, the reference is the tag after the last ":" in the FINAL
#   path segment only (so a registry ref never confuses a "owner/pkg" path
#   separator for a tag separator), defaulting to "latest" when that
#   segment has no ":".
# - owner is the first remaining path segment; package is everything after
#   it, slashes kept, so nested package paths (owner/team/pkg) survive
#   intact rather than collapsing to just the last segment.
ghcr_parse_image_ref() {
  local ref="$1"
  local path="$ref"

  case "$path" in
    ghcr.io/*) path="${path#ghcr.io/}" ;;
  esac

  local reference
  case "$path" in
    *@*)
      reference="${path##*@}"
      path="${path%%@*}"
      # A ref can carry both a tag and a digest (e.g. "img-x:tag@sha256:...");
      # the digest above already wins as the reference, so any leftover
      # ":tag" on the final path segment must still be stripped here.
      local last_segment="${path##*/}"
      case "$last_segment" in
        *:*) path="${path%:*}" ;;
      esac
      ;;
    *)
      local last_segment="${path##*/}"
      case "$last_segment" in
        *:*) reference="${last_segment##*:}" ;;
        *) reference="latest" ;;
      esac
      path="${path%:"$reference"}"
      ;;
  esac

  local owner="${path%%/*}"
  local package="${path#*/}"

  printf '%s\n%s\n%s\n' "$owner" "$package" "$reference"
}

# ghcr_probe_pull_token <actor> <token> <owner> <package> <tag>
#
# Returns 0 if <token>, basic-auth'd as <actor>, can pull the manifest for
# ghcr.io/<owner>/<package>:<tag>; 1 otherwise (including on any curl/jq
# failure, an empty <token>, or a non-200 manifest response). Two real
# HTTP calls: the ghcr.io/token endpoint (to exchange basic auth for a
# scoped bearer token), then a manifest GET using that bearer.
ghcr_probe_pull_token() {
  local actor="$1" token="$2" owner="$3" package="$4" tag="$5"

  if [ -z "$token" ]; then
    return 1
  fi

  local scope="repository:${owner}/${package}:pull"
  local token_resp bearer
  token_resp="$(curl -fsS --max-time 10 -u "${actor}:${token}" \
    "https://ghcr.io/token?service=ghcr.io&scope=${scope}" 2>/dev/null)" || return 1
  bearer="$(printf '%s' "$token_resp" | jq -r '.token // empty' 2>/dev/null)" || return 1
  [ -n "$bearer" ] || return 1

  local accept="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Authorization: Bearer ${bearer}" \
    -H "Accept: ${accept}" \
    "https://ghcr.io/v2/${owner}/${package}/manifests/${tag}" 2>/dev/null)" || return 1
  [ "$status" = "200" ]
}

# ghcr_probe_auth_only <actor> <token> <owner>
#
# Weaker check for call sites that don't know (or don't care about) a
# specific package -- e.g. the qwickway gateway route step, which
# refreshes registry credentials against a DIFFERENT package than the one
# this deploy job itself pulled. Confirms only that <actor>:<token> is
# accepted by ghcr.io's own token endpoint at all; never proves access to
# any particular image.
ghcr_probe_auth_only() {
  local actor="$1" token="$2" owner="$3"

  if [ -z "$token" ]; then
    return 1
  fi

  local scope="repository:${owner}/ghcr-token-select-auth-probe:pull"
  curl -fsS --max-time 10 -u "${actor}:${token}" \
    "https://ghcr.io/token?service=ghcr.io&scope=${scope}" >/dev/null 2>&1
}

# ghcr_select_token <actor> <owner> <package> <tag> <label1> <token1> [<label2> <token2> ...]
#
# Tries each candidate label/token pair IN THE ORDER GIVEN (preference is
# entirely the caller's choice -- this function does not reorder them),
# using ghcr_probe_pull_token. Prints the winning LABEL to stdout (nothing
# else -- never a token value) and returns 0 on the first candidate that
# can pull <owner>/<package>:<tag>. Returns 1 with no stdout if none work;
# callers are expected to ::error:: and exit themselves, since the right
# failure message differs per call site.
ghcr_select_token() {
  local actor="$1" owner="$2" package="$3" tag="$4"
  shift 4

  while [ "$#" -ge 2 ]; do
    local label="$1" token="$2"
    shift 2
    if ghcr_probe_pull_token "$actor" "$token" "$owner" "$package" "$tag"; then
      printf '%s\n' "$label"
      return 0
    fi
  done

  return 1
}
