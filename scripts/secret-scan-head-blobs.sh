#!/usr/bin/env bash
# Materialize every changed HEAD blob for the reusable Secret Scan workflow.
# Paths arrive as NUL-delimited git output and are never used as filesystem
# names, so unusual names cannot escape the private temporary directory.
# `git show <head>:<path>` deliberately reads the blob rather than a rendered
# diff: NUL bytes and .gitattributes -diff attributes cannot hide content.

set -euo pipefail

if [[ $# -ne 4 ]]; then
  printf 'usage: %s BASE_SHA HEAD_SHA SCANNER REPOSITORY_ROOT\n' "$0" >&2
  exit 64
fi

base_sha="$1"
head_sha="$2"
scanner="$3"
repository_root="$4"

[[ -f "$scanner" ]] || { printf 'secret-scan: scanner missing\n' >&2; exit 1; }
[[ -d "$repository_root/.git" || -f "$repository_root/.git" ]] || {
  printf 'secret-scan: repository root is not a git worktree\n' >&2
  exit 1
}

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

blobs=()
index=0
while IFS= read -r -d '' path; do
  # Git pathspec syntax accepts every path returned by --name-only. The output
  # file is a numeric private filename, not the repository-controlled path.
  blob="$tmpdir/blob-$index"
  if ! git -C "$repository_root" show "${head_sha}:${path}" > "$blob"; then
    printf 'secret-scan: failed to materialize a changed HEAD blob\n' >&2
    exit 1
  fi
  blobs+=("$blob")
  index=$((index + 1))
done < <(git -C "$repository_root" diff --name-only -z --diff-filter=ACMR "$base_sha" "$head_sha")

if [[ ${#blobs[@]} -eq 0 ]]; then
  printf 'secret-scan: no changed A/C/M/R head blobs\n' >&2
  exit 0
fi

python3 "$scanner" --paths "${blobs[@]}"
