#!/usr/bin/env bash
# scripts/tests/merge-gate-audit.test.sh
#
# Unit tests for the audit-evidence decision in
# .github/workflows/merge-gate-audit.yml (merge-gates design S2). Mirrors
# the "is this commit audited" logic: audited if either (a) a
# merge-gate/audit commit status is success, or (b) .merge-gate/audit.jsonl
# at that commit has a line with the matching merge_sha. Keep in sync with
# the workflow by hand.
#
# Test cases:
#   T1 — status success alone => audited                        (PASS)
#   T2 — status failure/pending alone => not audited             (FAIL)
#   T3 — audit.jsonl line match alone => audited                 (PASS)
#   T4 — neither present => not audited                          (FAIL, by design -- true until S1/S3 ship)
#   T5 — audit.jsonl present but for a DIFFERENT sha => not audited (FAIL)

set -euo pipefail

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# is_audited STATUS_STATE AUDIT_JSONL_CONTENT SHA
is_audited() {
  local status_state="$1" jsonl="$2" sha="$3"
  if [ "$status_state" = "success" ]; then
    echo "true"; return
  fi
  if printf '%s' "$jsonl" | grep -qF "\"merge_sha\":\"${sha}\""; then
    echo "true"; return
  fi
  echo "false"
}

[ "$(is_audited "success" "" "abc123")" = "true" ] \
  && ok "T1 status success => audited" || bad "T1 status success => audited"

[ "$(is_audited "failure" "" "abc123")" = "false" ] \
  && ok "T2 status failure => not audited" || bad "T2 status failure => not audited"

[ "$(is_audited "" '{"merge_sha":"abc123","repo":"x"}' "abc123")" = "true" ] \
  && ok "T3 audit.jsonl match => audited" || bad "T3 audit.jsonl match => audited"

[ "$(is_audited "" "" "abc123")" = "false" ] \
  && ok "T4 neither present => not audited (expected during rollout)" || bad "T4 neither present => not audited"

[ "$(is_audited "" '{"merge_sha":"deadbeef","repo":"x"}' "abc123")" = "false" ] \
  && ok "T5 audit.jsonl for a different sha => not audited" || bad "T5 audit.jsonl for a different sha => not audited"

echo ""
echo "merge-gate-audit.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
