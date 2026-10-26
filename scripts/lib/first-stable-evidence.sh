#!/usr/bin/env bash
# Fail-closed reader for digest-bound build/UAT qualification records.
# Requires GH_TOKEN and scripts/lib/check-run-binding.sh to be loaded.

first_stable_evidence_require() {
  local repo="$1" app_name="$2" sha="$3" image_digest="$4" kind="$5"
  local check_name expected_step encoded response total returned candidate
  local found=0 rc app_slug external_id

  case "$kind" in
    build)
      check_name="blue-green/first-stable-build/${app_name}"
      expected_step="Record first-stable build proof"
      ;;
    uat)
      check_name="blue-green/first-stable-uat/${app_name}"
      expected_step="Record first-stable UAT proof"
      ;;
    *)
      echo "::error::first-stable evidence REFUSED (invalid_kind): '$kind'" >&2
      return 2
      ;;
  esac

  encoded="$(jq -rn --arg n "$check_name" '$n | @uri')"
  if ! response="$(gh api "repos/${repo}/commits/${sha}/check-runs?check_name=${encoded}&per_page=100" 2>&1)"; then
    echo "::error::first-stable evidence REFUSED (check_runs_query_failed): ${response:-<no output>}" >&2
    return 2
  fi
  if ! printf '%s' "$response" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "::error::first-stable evidence REFUSED (check_runs_query_failed): response was not an object" >&2
    return 2
  fi
  total="$(printf '%s' "$response" | jq -r '.total_count // 0')"
  returned="$(printf '%s' "$response" | jq -r '(.check_runs // []) | length')"
  if [ "$returned" -lt "$total" ]; then
    echo "::error::first-stable evidence REFUSED (check_runs_incomplete): ${check_name} response was truncated" >&2
    return 2
  fi

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    app_slug="$(printf '%s' "$candidate" | jq -r '.app.slug // ""')"
    external_id="$(printf '%s' "$candidate" | jq -r '.external_id // ""')"
    if ! printf '%s' "$candidate" | jq -e \
      --arg repo "$repo" --arg app "$app_name" --arg sha "$sha" --arg digest "$image_digest" --arg kind "$kind" '
        .conclusion == "success" and
        ((.output.text // "") | fromjson? // {}) as $p |
        ($p.schema == "first-stable-source-proof/v1" and
         $p.kind == $kind and
         $p.repo == $repo and
         $p.app_name == $app and
         $p.source_sha == $sha and
         $p.image_digest == $digest and
         ($kind != "uat" or $p.stage == "uat"))
      ' >/dev/null 2>&1; then
      continue
    fi
    if check_run_binding_verify "$repo" "$sha" "$app_slug" "$external_id" "$expected_step"; then
      found=1
      break
    else
      rc=$?
      [ "$rc" -eq 1 ] || {
        echo "::error::first-stable evidence REFUSED (binding_unverifiable): ${check_name}" >&2
        return 2
      }
    fi
  done < <(printf '%s' "$response" | jq -c '.check_runs[]?')

  if [ "$found" -ne 1 ]; then
    echo "::error::first-stable evidence REFUSED (missing_${kind}_proof): no bound ${kind} proof for ${repo}@${sha} / ${app_name} / ${image_digest}" >&2
    return 1
  fi
}
