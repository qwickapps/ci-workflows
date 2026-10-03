#!/usr/bin/env bash
set -euo pipefail

# ci-workflows#165: a repo's Dockerfile can install dependencies from a
# different lockfile/package manager than CI actually validates. When they
# disagree, CI can go fully green on a dependency tree that never ships --
# a Dependabot/security PR passes every check on the pnpm tree while the
# shipped image keeps installing the old, vulnerable package-lock.json tree.
# Found independently in qwickapps/mcp#363 (fixed mcp#365) and
# qwickapps/secrets#86 (fixed secrets#89) -- both needed BOTH Dockerfile
# stages fixed, not just the first. ci-workflows#139 is the mirror image:
# this very reusable workflow hardcoded pnpm while qwickapps/agents is an
# npm repo, so its build guard could never pass at all.
#
# This script checks both directions:
#   A. Every Dockerfile* build stage that installs dependencies must use
#      the SAME package manager CI validates (--ci-manager's lockfile).
#   B. --ci-manager's lockfile must actually exist in the repo -- if the
#      repo only has a different lockfile, CI is validating a tree that
#      doesn't correspond to what's checked in (the ci-workflows#139 shape).

CI_MANAGER="pnpm"
ROOT="."
DOCKERFILE_GLOB="Dockerfile*"

usage() {
  cat <<'EOF'
Usage:
  lockfile-consistency-guard.sh [--ci-manager pnpm|npm|yarn|bun] [--root DIR] [--dockerfile-glob GLOB]

Fails when a repo's Dockerfile* install steps use a different package
manager/lockfile than the one CI validates (--ci-manager, default: pnpm,
matching this workflow's install step for language: ts|js), in either
direction:

  A. A Dockerfile build stage installs via a manager whose lockfile CI
     never validated (e.g. `npm ci` against package-lock.json while CI
     runs `pnpm install --frozen-lockfile` against pnpm-lock.yaml).
     Checked per-stage, so a multi-stage Dockerfile with only its second
     stage wrong is still caught.
  B. CI's assumed package manager has no matching lockfile in this repo
     at all (e.g. CI hardcodes pnpm but the repo only has
     package-lock.json).

Exits 0 (no-op) for repos with no package.json -- this check only applies
to Node.js repos.
EOF
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ci-manager)
      CI_MANAGER="$2"
      shift 2
      ;;
    --root)
      ROOT="$2"
      shift 2
      ;;
    --dockerfile-glob)
      DOCKERFILE_GLOB="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cd "$ROOT"

if [ ! -f package.json ]; then
  echo "lockfile guard: no package.json -- not a Node.js repo, skipping"
  exit 0
fi

lockfile_candidates_for_manager() {
  case "$1" in
    npm) echo "package-lock.json" ;;
    pnpm) echo "pnpm-lock.yaml" ;;
    yarn) echo "yarn.lock" ;;
    bun) echo "bun.lock bun.lockb" ;;
    *) echo "" ;;
  esac
}

failed=0
present_lockfiles=""
for lf in package-lock.json pnpm-lock.yaml yarn.lock bun.lock bun.lockb; do
  if [ -f "$lf" ]; then
    present_lockfiles="${present_lockfiles}${present_lockfiles:+ }${lf}"
  fi
done

# --- Check B: CI's assumed manager must have a matching lockfile present ---
ci_lockfile_candidates="$(lockfile_candidates_for_manager "$CI_MANAGER")"
ci_lockfile_present=0
for cand in $ci_lockfile_candidates; do
  [ -f "$cand" ] && ci_lockfile_present=1
done

if [ "$ci_lockfile_present" -eq 1 ]; then
  echo "lockfile guard: CI manager '${CI_MANAGER}' lockfile is present"
elif [ -n "$present_lockfiles" ]; then
  failed=1
  cat <<EOF
::error::CI installs dependencies with '${CI_MANAGER}' (expects: ${ci_lockfile_candidates}) but this repo has no such lockfile. Found instead: ${present_lockfiles}. CI is validating a package manager this repo does not use (ci-workflows#139 shape).
EOF
else
  echo "lockfile guard: no lockfile found at all in a Node.js repo -- nothing to compare (unrelated to this check)"
fi

# --- Check A: every Dockerfile* build stage must install via CI_MANAGER ---
detect_stage_manager() {
  # $1 = accumulated RUN/COPY lines for one Dockerfile build stage
  local content="$1"
  local npm_lines

  npm_lines="$(printf '%s\n' "$content" | grep -E '(^|[^A-Za-z0-9_-])npm[[:space:]]+(ci|install)([[:space:]]|$)' | grep -Ev -- '(^|[[:space:]])(-g|--global)([[:space:]]|$)' || true)"
  if [ -n "$npm_lines" ]; then
    echo "npm"
    return
  fi
  if printf '%s\n' "$content" | grep -Eq '(^|[^A-Za-z0-9_-])pnpm[[:space:]]+(install|i)([[:space:]]|$)'; then
    echo "pnpm"
    return
  fi
  if printf '%s\n' "$content" | grep -Eq '(^|[^A-Za-z0-9_-])yarn[[:space:]]+install([[:space:]]|$)|(^|[^A-Za-z0-9_-])yarn[[:space:]]+--frozen-lockfile'; then
    echo "yarn"
    return
  fi
  if printf '%s\n' "$content" | grep -Eq '(^|[^A-Za-z0-9_-])bun[[:space:]]+install([[:space:]]|$)'; then
    echo "bun"
    return
  fi
  echo ""
}

check_stage() {
  # $1 = dockerfile path, $2 = stage number, $3 = FROM arg, $4 = stage content
  local df="$1" num="$2" from="$3" content="$4" mgr
  [ -n "$content" ] || return 0

  mgr="$(detect_stage_manager "$content")"
  [ -n "$mgr" ] || return 0

  if [ "$mgr" != "$CI_MANAGER" ]; then
    failed=1
    cat <<EOF
::error file=${df}::Stage ${num} (FROM ${from}) installs dependencies with '${mgr}', but CI validates '${CI_MANAGER}'. The shipped image's dependency tree diverges from the tree CI tested (mcp#365 / secrets#89 shape).
EOF
  else
    echo "lockfile guard: ${df} stage ${num} (FROM ${from}) installs via '${mgr}', matches CI"
  fi
}

found_dockerfile=0
for df in $DOCKERFILE_GLOB; do
  [ -f "$df" ] || continue
  [ "$df" = ".dockerignore" ] && continue
  found_dockerfile=1

  dockerfile_body="$(cat "$df")"
  stage_num=0
  stage_from=""
  stage_content=""

  while IFS= read -r line || [ -n "$line" ]; do
    if printf '%s\n' "$line" | grep -Eq '^FROM[[:space:]]+'; then
      check_stage "$df" "$stage_num" "$stage_from" "$stage_content"
      stage_num=$((stage_num + 1))
      stage_from="$(printf '%s\n' "$line" | sed -E 's/^FROM[[:space:]]+//')"
      stage_content=""
    else
      stage_content="${stage_content}
${line}"
    fi
  done <<< "$dockerfile_body"
  check_stage "$df" "$stage_num" "$stage_from" "$stage_content"
done

if [ "$found_dockerfile" -eq 0 ]; then
  echo "lockfile guard: no ${DOCKERFILE_GLOB} found, skipping Dockerfile-vs-CI check"
fi

exit "$failed"
