#!/usr/bin/env bash
# Integration regression tests for the reusable Secret Scan materializer.
# Fixtures synthesize detector-shaped strings at runtime and suppress scanner
# output so no value is ever printed by this test.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MATERIALIZER="$ROOT/scripts/secret-scan-head-blobs.sh"
SCANNER="$ROOT/scripts/lib/secret-scan.py"
workdirs=()
cleanup() {
  local dir
  for dir in "${workdirs[@]}"; do rm -rf "$dir"; done
}
trap cleanup EXIT

new_repo() {
  repo="$(mktemp -d)"
  workdirs+=("$repo")
  git -C "$repo" init -q
  git -C "$repo" config user.email ci@example.invalid
  git -C "$repo" config user.name "Secret Scan Test"
  git -C "$repo" commit --allow-empty -qm base
  base="$(git -C "$repo" rev-parse HEAD)"
}

assert_rejected() {
  local name="$1"
  local head rc
  git -C "$repo" add --all
  git -C "$repo" commit -qm "$name"
  head="$(git -C "$repo" rev-parse HEAD)"
  set +e
  bash "$MATERIALIZER" "$base" "$head" "$SCANNER" "$repo" >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne 1 ]]; then
    printf '[FAIL] %s: expected scanner rejection, got rc=%s\n' "$name" "$rc" >&2
    exit 1
  fi
  printf '[PASS] %s\n' "$name"
}

# NUL makes ordinary textual git diffs show a binary marker rather than the
# payload. The changed blob must still reach the scanner.
new_repo
printf 'prefix\0GH_TOKEN=%s%s\n' 'gh' 'p_Aa1Bb2Cc3Dd4Ee5Ff6Gg7Hh8Ii9Jj0Kk' > "$repo/nul-payload.bin"
assert_rejected 'NUL/binary payload'

# A PR can add .gitattributes and hide its companion blob from git diff.
new_repo
printf 'hidden.fixture -diff\n' > "$repo/.gitattributes"
printf 'GH_TOKEN=%s%s\n' 'gh' 'p_Ll1Mm2Nn3Oo4Pp5Qq6Rr7Ss8Tt9Uu0Vv' > "$repo/hidden.fixture"
assert_rejected '.gitattributes -diff payload'

# Magic bytes, not a case-sensitive extension, must select gzip recursion.
new_repo
python3 - "$repo/PAYLOAD.GZ" <<'PY'
import gzip
import sys
with gzip.open(sys.argv[1], "wb") as fh:
    fh.write(b"GH_TOKEN=" + b"gh" + b"p_Ww1Xx2Yy3Zz4Aa5Bb6Cc7Dd8Ee9Ff0Gg")
PY
assert_rejected 'uppercase GZ archive'

# Archive bytes under an arbitrary name cannot be skipped by extension logic.
new_repo
python3 - "$repo/arbitrary-name.data" <<'PY'
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1], "w") as zf:
    zf.writestr("payload.txt", b"GH_TOKEN=" + b"gh" + b"p_Hh1Ii2Jj3Kk4Ll5Mm6Nn7Oo8Pp9Qq0Rr")
PY
assert_rejected 'magic archive with unrecognized filename'

printf '4 integration cases passed\n'
