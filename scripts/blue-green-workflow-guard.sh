#!/usr/bin/env bash
set -euo pipefail

CANONICAL_REF="${BLUE_GREEN_DEPLOY_REF:-qwickapps/ci-workflows/.github/workflows/deploy-app.yml@main}"
EXEMPTION_PATTERN='#[[:space:]]*blue-green-exempt:[[:space:]]*[^[:space:]].*'

usage() {
  cat <<'EOF'
Usage:
  blue-green-workflow-guard.sh [changed-file ...]

Fails when a changed .github/workflows/*deploy*.yml file does not call the
canonical QwickApps deploy workflow or carry an explicit exemption comment:

  # blue-green-exempt: <reason>

When no files are passed, the script computes changed files from BASE_SHA and
HEAD_SHA. If those are not set it falls back to the previous commit.
EOF
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

collect_changed_files() {
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@"
    return
  fi

  local base="${BASE_SHA:-}"
  local head="${HEAD_SHA:-HEAD}"

  if [ -z "$base" ]; then
    if git rev-parse --verify HEAD^ >/dev/null 2>&1; then
      base="HEAD^"
    else
      git ls-files
      return
    fi
  fi

  git diff --name-only --diff-filter=ACMR "$base" "$head"
}

is_deploy_workflow() {
  case "$1" in
    .github/workflows/*deploy*.yml|.github/workflows/*deploy*.yaml) return 0 ;;
    *) return 1 ;;
  esac
}

failed=0
checked=0

while IFS= read -r file; do
  [ -n "$file" ] || continue
  is_deploy_workflow "$file" || continue

  checked=$((checked + 1))

  if [ ! -f "$file" ]; then
    echo "blue-green guard: skipping deleted deploy workflow: $file"
    continue
  fi

  if grep -Eq "$EXEMPTION_PATTERN" "$file"; then
    echo "blue-green guard: exempt deploy workflow: $file"
    continue
  fi

  if grep -Fq "$CANONICAL_REF" "$file"; then
    echo "blue-green guard: compliant deploy workflow: $file"
    continue
  fi

  failed=1
  cat <<EOF
::error file=${file}::Deploy workflows must call ${CANONICAL_REF} or carry '# blue-green-exempt: <reason>'.
blue-green guard: non-compliant deploy workflow: $file
EOF
done < <(collect_changed_files "$@")

if [ "$checked" -eq 0 ]; then
  echo "blue-green guard: no changed deploy workflows"
fi

exit "$failed"
