#!/usr/bin/env bash
# scripts/tests/validation-evidence-gate.test.sh
#
# Unit tests for the two Python parsers embedded in
# .github/workflows/validation-evidence-gate.yml:
#
#   Parser 1 — section detection (has_section):
#     Outputs "true" if the PR body contains a ^## Test plan$ or ^## Validation$
#     heading (case-insensitive). Outputs "false" otherwise.
#
#   Parser 2 — unchecked item finder:
#     Returns lineno:item for every `- [ ] ...` line inside the section that
#     does NOT contain SKIP:.  Items outside the section, or inside a later
#     sibling section, are ignored.
#
# Test cases:
#   T1 — all checked → has_section=true, unchecked empty               (PASS)
#   T2 — one unchecked item → unchecked contains the item              (FAIL)
#   T3 — SKIP: annotation → not counted as unchecked                   (PASS)
#   T4 — no ## Test plan section → has_section=false                   (WARN)
#   T5 — items outside section are not counted                         (PASS)
#   T6 — section terminates at next ## heading                         (PASS)
#   T7 — case-insensitive heading match (TEST PLAN)                    (PASS)
#   T8 — Validation heading alias                                       (PASS)
#   T9 — multiple unchecked items → all reported                       (FAIL)
#   T10 — unchecked item before section start is ignored               (PASS)

set -euo pipefail

PASS=0
FAIL=0

ok() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail_test() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

check() {
  local desc="$1"
  shift
  if "$@"; then
    ok "$desc"
  else
    fail_test "$desc"
  fi
}

# contains HAYSTACK NEEDLE — asserts NEEDLE is a substring of HAYSTACK
contains() {
  printf '%s' "$1" | grep -qF -- "$2"
}

# not_contains HAYSTACK NEEDLE — asserts NEEDLE is NOT in HAYSTACK
not_contains() {
  ! printf '%s' "$1" | grep -qF -- "$2"
}

# matches_re HAYSTACK REGEX — asserts any line in HAYSTACK matches REGEX
matches_re() {
  printf '%s\n' "$1" | grep -qE -- "$2"
}

TMPDIR_GATE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_GATE"' EXIT

BODY_FILE="$TMPDIR_GATE/body.txt"

# ── Parser functions (must stay in sync with validation-evidence-gate.yml) ────

# has_section → stdout "true" or "false"
has_section() {
  python3 - "$BODY_FILE" <<'PYEOF'
import re, sys
body = open(sys.argv[1]).read()
if re.search(r'^##\s+(test plan|validation)\s*$', body, re.IGNORECASE | re.MULTILINE):
    print("true")
else:
    print("false")
PYEOF
}

# unchecked_items → stdout "lineno:item" per unchecked line (empty if none)
unchecked_items() {
  python3 - "$BODY_FILE" <<'PYEOF'
import re, sys
body = open(sys.argv[1]).read()
lines = body.split('\n')
in_section = False
unchecked = []
for i, line in enumerate(lines):
    if re.match(r'^##\s+(test plan|validation)\s*$', line.strip(), re.IGNORECASE):
        in_section = True
        continue
    if in_section and re.match(r'^##', line):
        in_section = False
    if in_section and re.match(r'^- \[ \]', line) and 'SKIP:' not in line:
        unchecked.append((i+1, line.strip()))
for lineno, item in unchecked:
    print(f"{lineno}:{item}")
PYEOF
}

# ── T1: all checked → section present, no unchecked items ────────────────────

echo "== T1: all checked items → PASS =="

cat > "$BODY_FILE" <<'EOF'
## Test plan
- [x] Deployed to UAT
- [x] Verified auth flow
- [x] Health check passes
EOF

check "T1: has_section=true"       test "$(has_section)" = "true"
check "T1: unchecked_items empty"  test -z "$(unchecked_items)"

# ── T2: one unchecked item → section present, item in output ─────────────────

echo "== T2: one unchecked item → FAIL =="

cat > "$BODY_FILE" <<'EOF'
## Test plan
- [x] Deployed to UAT
- [ ] Verified auth flow
EOF

UNCHECKED_T2="$(unchecked_items)"
check "T2: has_section=true"              test "$(has_section)" = "true"
check "T2: unchecked item in output"      contains "$UNCHECKED_T2" "- [ ] Verified auth flow"
check "T2: output includes line number"   matches_re "$UNCHECKED_T2" '^[0-9]+:'
check "T2: exactly 1 unchecked item"      test "$(printf '%s\n' "$UNCHECKED_T2" | grep -c .)" = "1"

# ── T3: SKIP: annotation → not counted as unchecked ─────────────────────────

echo "== T3: SKIP: annotation → PASS =="

cat > "$BODY_FILE" <<'EOF'
## Test plan
- [x] Deployed to UAT
- [ ] SKIP: no staging env — Verified auth flow on staging
EOF

check "T3: has_section=true"              test "$(has_section)" = "true"
check "T3: SKIP: item not counted"        test -z "$(unchecked_items)"

# ── T4: no ## Test plan section → has_section=false ──────────────────────────

echo "== T4: no Test plan section → WARN (has_section=false) =="

cat > "$BODY_FILE" <<'EOF'
## Summary
This PR does things.

## Changes
- Changed foo
- Changed bar
EOF

check "T4: has_section=false"             test "$(has_section)" = "false"
check "T4: unchecked_items empty"         test -z "$(unchecked_items)"

# ── T5: unchecked items OUTSIDE section are not counted ──────────────────────

echo "== T5: items outside section ignored → PASS =="

cat > "$BODY_FILE" <<'EOF'
## Summary
- [ ] This is not a test plan item — it is in Summary

## Test plan
- [x] Actually checked
EOF

check "T5: has_section=true"             test "$(has_section)" = "true"
check "T5: Summary item not counted"     test -z "$(unchecked_items)"

# ── T6: section terminates at next ## heading ─────────────────────────────────

echo "== T6: section ends at next ## heading → PASS =="

cat > "$BODY_FILE" <<'EOF'
## Test plan
- [x] Deployed

## Validation debt
- [ ] This is in a different section — not counted
EOF

check "T6: has_section=true"             test "$(has_section)" = "true"
check "T6: Validation debt item ignored" test -z "$(unchecked_items)"

# ── T7: case-insensitive heading match ────────────────────────────────────────

echo "== T7: case-insensitive heading (TEST PLAN) → PASS =="

cat > "$BODY_FILE" <<'EOF'
## TEST PLAN
- [ ] Unchecked item in uppercase section
EOF

UNCHECKED_T7="$(unchecked_items)"
check "T7: has_section=true for uppercase"       test "$(has_section)" = "true"
check "T7: item from uppercase section found"    contains "$UNCHECKED_T7" "Unchecked item in uppercase section"

# ── T8: Validation heading alias ─────────────────────────────────────────────

echo "== T8: Validation section alias → treated as test plan =="

cat > "$BODY_FILE" <<'EOF'
## Validation
- [x] All checks pass
- [ ] Manual regression on UAT
EOF

UNCHECKED_T8="$(unchecked_items)"
check "T8: has_section=true for Validation"      test "$(has_section)" = "true"
check "T8: unchecked item in Validation found"   contains "$UNCHECKED_T8" "Manual regression on UAT"

# ── T9: multiple unchecked items → all reported ───────────────────────────────

echo "== T9: multiple unchecked items → all in output =="

cat > "$BODY_FILE" <<'EOF'
## Test plan
- [x] Done item
- [ ] First unchecked
- [ ] Second unchecked
- [ ] SKIP: skipped item
- [ ] Third unchecked
EOF

UNCHECKED_T9="$(unchecked_items)"
check "T9: 3 unchecked items reported"   test "$(printf '%s\n' "$UNCHECKED_T9" | grep -c .)" = "3"
check "T9: First unchecked present"      contains "$UNCHECKED_T9" "First unchecked"
check "T9: Second unchecked present"     contains "$UNCHECKED_T9" "Second unchecked"
check "T9: Third unchecked present"      contains "$UNCHECKED_T9" "Third unchecked"
check "T9: SKIP item not present"        not_contains "$UNCHECKED_T9" "skipped item"

# ── T10: unchecked item BEFORE section start is ignored ──────────────────────

echo "== T10: unchecked before section → not counted =="

cat > "$BODY_FILE" <<'EOF'
- [ ] Pre-section unchecked item

## Test plan
- [x] In-section checked item
EOF

check "T10: pre-section item not counted"  test -z "$(unchecked_items)"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
