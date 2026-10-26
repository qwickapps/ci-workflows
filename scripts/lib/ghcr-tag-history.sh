#!/usr/bin/env bash
# Shared GHCR tag-history query for fail-closed deployment gates.
# Requires GH_TOKEN in the environment. Prints true or false only on success.

ghcr_tag_history_exists() {
  local owner="$1" image_name="$2"; shift 2
  local response err_file visibility_file visibility_response
  local tag_expr=''
  local tag

  if [ "$#" -eq 0 ]; then
    echo "::error::ghcr-tag-history: at least one tag is required" >&2
    return 2
  fi
  for tag in "$@"; do
    tag_expr+=". == $(jq -Rn --arg tag "$tag" '$tag') or "
  done
  tag_expr="${tag_expr% or }"

  err_file="$(mktemp)"
  trap 'rm -f "$err_file" "${visibility_file:-}"' RETURN
  if response="$(gh api --paginate "orgs/${owner}/packages/container/${image_name}/versions?per_page=100" 2>"$err_file")"; then
    if [ -z "$response" ]; then
      echo "::error::ghcr-tag-history: package-versions response was empty" >&2
      return 1
    fi
    if ! printf '%s' "$response" | jq -es . >/dev/null 2>&1; then
      echo "::error::ghcr-tag-history: package-versions response is not valid JSON" >&2
      return 1
    fi
    if printf '%s' "$response" | jq -es "flatten | any(.metadata.container.tags[]? | ${tag_expr})" 2>/dev/null | grep -qx true; then
      printf '%s\n' true
    else
      printf '%s\n' false
    fi
    return 0
  fi

  if ! grep -qi 'HTTP 404' "$err_file" || ! grep -qi 'Package not found' "$err_file"; then
    echo "::error::ghcr-tag-history: package-versions query failed unexpectedly" >&2
    cat "$err_file" >&2
    return 1
  fi

  visibility_file="$(mktemp)"
  if ! visibility_response="$(gh api "orgs/${owner}/packages?package_type=container&per_page=1" 2>"$visibility_file")" || \
      ! printf '%s' "$visibility_response" | jq -es 'flatten | length > 0' 2>/dev/null | grep -qx true; then
    echo "::error::ghcr-tag-history: could not positively confirm this token can see ANY container package in org '${owner}'" >&2
    cat "$visibility_file" >&2
    return 1
  fi
  printf '%s\n' false
}
