#!/usr/bin/env bash
# scripts/tests/merge-gate-status.test.sh
#
# Unit tests for the pure decision logic embedded in
# .github/workflows/merge-gate.yml (merge-gates design S2). Each function
# below mirrors the corresponding bash logic in the workflow's `run:` block
# so it can be exercised without GitHub Actions or network access. Keep
# these in sync with the workflow by hand -- if you change one, change both.
#
# Test cases:
#   T1  — blast radius under limits                           (PASS)
#   T2  — blast radius over limits, no large-change label      (FAIL)
#   T3  — blast radius over limits, large-change label present (PASS)
#   T4  — lockfiles excluded from blast-radius file count       (PASS)
#   T5  — Kanban: t_xxxx in PR body is recognized               (PASS)
#   T6  — Closes #N in PR body is recognized                    (PASS)
#   T7  — PR body with neither is not recognized                (WARN)
#   T8  — protected path match flags qwick-guard                (FLAG)
#   T9  — protected path match flags .github/workflows/deploy   (FLAG)
#   T10 — unrelated path does not flag as protected              (PASS)
#   T11 — migrations/ path requires migration label + Rollback:  (FAIL without)
#   T12 — migrations/ path passes with label + Rollback: line    (PASS)

set -euo pipefail

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

LOCKFILE_RE='(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Cargo\.lock|go\.sum|poetry\.lock|uv\.lock)$'
PROTECTED_RE='(^|/)(hermes-plugins/qwick-guard/|aos/guard/|rules\.json$|allow\.json$|environments\.yml$|qwick-secrets-|\.github/workflows/merge-gate|\.github/workflows/deploy-app\.yml|\.github/workflows/promote)'
MIGRATION_RE='(^|/)(migrations/|.*\.sql$)'

# over_blast_radius FILES_STR NUM_LINES MAX_LINES MAX_FILES HAS_LARGE_LABEL
# echoes "fail" or "pass"
over_blast_radius() {
  local files="$1" lines="$2" max_lines="$3" max_files="$4" has_label="$5"
  local n_files
  n_files=$(printf '%s\n' "$files" | grep -vE "$LOCKFILE_RE" | grep -c . || true)
  if [ "$lines" -gt "$max_lines" ] || [ "$n_files" -gt "$max_files" ]; then
    [ "$has_label" = "true" ] && echo "pass" || echo "fail"
  else
    echo "pass"
  fi
}

linked_to_work() {
  local body="$1"
  if printf '%s' "$body" | grep -qE 'Kanban: *t_[0-9a-f]+'; then
    echo "true"; return
  fi
  if printf '%s' "$body" | grep -qiE 'Closes #[0-9]+'; then
    echo "true"; return
  fi
  echo "false"
}

touches_protected() {
  printf '%s' "$1" | grep -qE "$PROTECTED_RE" && echo "true" || echo "false"
}

migration_gate() {
  local files="$1" has_label="$2" has_rollback="$3"
  if printf '%s' "$files" | grep -qE "$MIGRATION_RE"; then
    if [ "$has_label" = "true" ] && [ "$has_rollback" = "true" ]; then
      echo "pass"
    else
      echo "fail"
    fi
  else
    echo "pass"
  fi
}

# T1
[ "$(over_blast_radius "$(printf 'a.ts\nb.ts')" 100 800 40 false)" = "pass" ] \
  && ok "T1 blast radius under limits passes" || bad "T1 blast radius under limits passes"

# T2
[ "$(over_blast_radius "$(printf 'a.ts\nb.ts')" 900 800 40 false)" = "fail" ] \
  && ok "T2 over limits, no label fails" || bad "T2 over limits, no label fails"

# T3
[ "$(over_blast_radius "$(printf 'a.ts\nb.ts')" 900 800 40 true)" = "pass" ] \
  && ok "T3 over limits, large-change label passes" || bad "T3 over limits, large-change label passes"

# T4: 41 files but one of them is package-lock.json -> 40 non-lock files, exactly at the limit, passes
FILES_WITH_LOCK=$(printf 'f1.ts\nf2.ts\nf3.ts\nf4.ts\nf5.ts\nf6.ts\nf7.ts\nf8.ts\nf9.ts\nf10.ts\nf11.ts\nf12.ts\nf13.ts\nf14.ts\nf15.ts\nf16.ts\nf17.ts\nf18.ts\nf19.ts\nf20.ts\nf21.ts\nf22.ts\nf23.ts\nf24.ts\nf25.ts\nf26.ts\nf27.ts\nf28.ts\nf29.ts\nf30.ts\nf31.ts\nf32.ts\nf33.ts\nf34.ts\nf35.ts\nf36.ts\nf37.ts\nf38.ts\nf39.ts\nf40.ts\npackage-lock.json')
[ "$(over_blast_radius "$FILES_WITH_LOCK" 10 800 40 false)" = "pass" ] \
  && ok "T4 lockfiles excluded from file count" || bad "T4 lockfiles excluded from file count"

# T5
[ "$(linked_to_work 'fixes a bug

Kanban: t_abc12345')" = "true" ] && ok "T5 Kanban: t_xxxx recognized" || bad "T5 Kanban: t_xxxx recognized"

# T6
[ "$(linked_to_work 'fixes a bug

Closes #123')" = "true" ] && ok "T6 Closes #N recognized" || bad "T6 Closes #N recognized"

# T7
[ "$(linked_to_work 'fixes a bug, no links')" = "false" ] && ok "T7 no link recognized as absent" || bad "T7 no link recognized as absent"

# T8
[ "$(touches_protected "$(printf 'hermes-plugins/qwick-guard/__init__.py')")" = "true" ] \
  && ok "T8 qwick-guard path flags protected" || bad "T8 qwick-guard path flags protected"

# T9
[ "$(touches_protected "$(printf '.github/workflows/deploy-app.yml')")" = "true" ] \
  && ok "T9 deploy-app.yml flags protected" || bad "T9 deploy-app.yml flags protected"

# T10
[ "$(touches_protected "$(printf 'src/widgets/button.tsx')")" = "false" ] \
  && ok "T10 unrelated path not flagged" || bad "T10 unrelated path not flagged"

# T11
[ "$(migration_gate "$(printf 'migrations/0001_init.sql')" false false)" = "fail" ] \
  && ok "T11 migration without label+rollback fails" || bad "T11 migration without label+rollback fails"

# T12
[ "$(migration_gate "$(printf 'migrations/0001_init.sql')" true true)" = "pass" ] \
  && ok "T12 migration with label+rollback passes" || bad "T12 migration with label+rollback passes"

echo ""
echo "merge-gate-status.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
