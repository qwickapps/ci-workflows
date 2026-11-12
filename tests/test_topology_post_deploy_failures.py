"""Regression tests for topology failure handling in deploy-app.yml.

The live preflight fixture exercises real conflict and verification-failure result
contracts. These tests make the workflow's distinct reactions to those result
classes executable under pytest: only a confirmed 409 conflict reaches rollback;
a verification failure is converted to a fail-closed 400 without rollback.
"""
from __future__ import annotations

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "deploy-app.yml"
LIVE_PREFLIGHT = ROOT / "scripts" / "tests" / "topology-live-preflight.test.sh"
ROLLBACK = ROOT / "scripts" / "tests" / "topology-rollback.test.sh"


def _post_deploy_block() -> str:
    text = WORKFLOW.read_text(encoding="utf-8")
    start = text.index("      - name: Post-deploy topology conflict check + rollback")
    end = text.index("      - name: Deep subsystem health check", start)
    return text[start:end]


def _run(script: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(script)], cwd=ROOT, check=False, text=True, capture_output=True
    )


def test_topology_conflict_returns_409_and_reaches_rollback() -> None:
    """A confirmed conflict is the sole result class allowed to invoke rollback."""
    live = _run(LIVE_PREFLIGHT)
    assert live.returncode == 0, live.stdout + live.stderr
    assert '"status_code": 409' in live.stdout
    assert '"failure_type": "topology_conflict"' in live.stdout

    block = _post_deploy_block()
    conflict = block.index(
        'if [ "$STATUS_CODE" = "409" ] && [ "$FAILURE_TYPE" = "topology_conflict" ]; then'
    )
    rollback = block.index("topology-rollback.py", conflict)
    assert rollback > conflict

    rollback_test = _run(ROLLBACK)
    assert rollback_test.returncode == 0, rollback_test.stdout + rollback_test.stderr
    assert "PASS new claimant scaled to 0" in rollback_test.stdout
    assert "PASS previous owner replicas restored" in rollback_test.stdout


def test_verification_failure_fails_closed_as_400_without_rollback() -> None:
    """An unavailable verifier must fail deployment, but must not undo it."""
    live = _run(LIVE_PREFLIGHT)
    assert live.returncode == 0, live.stdout + live.stderr
    assert '"status_code": 503' in live.stdout
    assert '"failure_type": "verification_failure"' in live.stdout

    block = _post_deploy_block()
    verification = block.index(
        'if [ "$STATUS_CODE" = "503" ] && [ "$FAILURE_TYPE" = "verification_failure" ]; then'
    )
    verification_body = block[verification:]
    assert "verification failed closed (400)" in verification_body
    assert "topology-rollback.py" not in verification_body
