#!/usr/bin/env bash
# Regression guard for deploy-app's post-mutation topology rollback policy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/deploy-app.yml"

python3 - "$WORKFLOW" <<'PY'
from pathlib import Path
import sys

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")

required = [
    '--result-out "$POST_RESULT"',
    'POST_STATUS="$(python3 -c',
    'status not in {"live_conflict", "verification_failure"}',
    'if [ "$POST_STATUS" != "live_conflict" ]; then',
    'no rollback was attempted because no conflict was confirmed',
    'post-deploy topology conflict confirmed',
    'topology-rollback.py',
]
for fragment in required:
    if fragment not in workflow:
        raise SystemExit(f"missing post-deploy rollback guard: {fragment}")

verification_guard = workflow.index('if [ "$POST_STATUS" != "live_conflict" ]; then')
rollback = workflow.index('topology-rollback.py', verification_guard)
if verification_guard >= rollback:
    raise SystemExit('rollback is not guarded by confirmed live_conflict status')

print('PASS deploy rollback runs only after a confirmed live_conflict result')
PY
