#!/usr/bin/env bash
set -euo pipefail

CANONICAL_REF="${BLUE_GREEN_DEPLOY_REF:-qwickapps/ci-workflows/.github/workflows/deploy-app.yml@main}"
EXEMPTION_PATTERN='#[[:space:]]*blue-green-exempt:[[:space:]]*[^[:space:]].*'
# ci-workflows#153 (check 3): the actual, root-cause trigger is CONTENT, not
# filename. qwickapps/billing's promote-to-live.yml / promote-to-stable.yml
# have no "deploy" in their filenames at all and evaded the previous
# filename-based `*deploy*.yml` check entirely while independently accessing
# secrets.OCI_*/GHCR_* CapRover credentials. Any workflow file that
# references a CapRover secret is now in scope, regardless of what it's
# named.
CAPROVER_SECRET_PATTERN='secrets\.[A-Za-z0-9_]*CAPROVER[A-Za-z0-9_]*'

usage() {
  cat <<'EOF'
Usage:
  blue-green-workflow-guard.sh [changed-file ...]

Fails when a changed .github/workflows/*.yml (or .yaml) file references a
CapRover secret (secrets.*CAPROVER*) without also calling the canonical
QwickApps deploy workflow, or carrying an explicit exemption comment:

  # blue-green-exempt: <reason>

This is a content-based trigger, not a filename pattern (ci-workflows#153) —
a workflow named anything at all that touches CapRover credentials directly
is in scope.

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

is_workflow_file() {
  case "$1" in
    .github/workflows/*.yml|.github/workflows/*.yaml) return 0 ;;
    *) return 1 ;;
  esac
}

references_caprover_secret() {
  # ci-workflows#155/#166: matched case-insensitively. secrets.*CAPROVER*
  # only matched a literal uppercase "CAPROVER" substring; a workflow
  # referencing e.g. secrets.OCI_DEV_Caprover_Password (or any other casing)
  # would silently evade this content-based trigger entirely.
  grep -Eqi "$CAPROVER_SECRET_PATTERN" "$1"
}

failed=0
checked=0

while IFS= read -r file; do
  [ -n "$file" ] || continue
  is_workflow_file "$file" || continue

  if [ ! -f "$file" ]; then
    echo "blue-green guard: skipping deleted workflow: $file"
    continue
  fi

  references_caprover_secret "$file" || continue

  checked=$((checked + 1))

  if grep -Eq "$EXEMPTION_PATTERN" "$file"; then
    echo "blue-green guard: exempt CapRover workflow: $file"
    continue
  fi

  if grep -Fq "$CANONICAL_REF" "$file"; then
    echo "blue-green guard: compliant CapRover workflow: $file"
    continue
  fi

  failed=1
  cat <<EOF
::error file=${file}::Workflow references a CapRover secret (${CAPROVER_SECRET_PATTERN}) without calling ${CANONICAL_REF} or carrying '# blue-green-exempt: <reason>'.
blue-green guard: non-compliant CapRover workflow: $file
EOF
done < <(collect_changed_files "$@")

if [ "$checked" -eq 0 ]; then
  echo "blue-green guard: no changed workflows reference a CapRover secret"
fi

exit "$failed"
