#!/usr/bin/env python3
"""Regression tests for the fail-closed Coolify token-name policy."""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/validate-coolify-token-exclusivity.py"
spec = importlib.util.spec_from_file_location("token_policy", SCRIPT)
assert spec is not None
policy = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(policy)


def check(name: str, condition: bool) -> None:
    if not condition:
        raise AssertionError(name)
    print(f"PASS: {name}")


check("real deployment assets pass", policy.violations([ROOT / path for path in policy.DEFAULT_PATHS]) == [])

with tempfile.TemporaryDirectory() as tmp:
    fixture = Path(tmp) / "deploy.yml"
    fixture.write_text("env:\n  COOLIFY_API_TOKEN: forbidden\n", encoding="utf-8")
    findings = policy.violations([fixture])
    check("generic token is rejected", len(findings) == 1 and "forbidden Coolify token name" in findings[0])
    result = subprocess.run([sys.executable, str(SCRIPT), str(fixture)], capture_output=True, text=True)
    check("validator command fails closed", result.returncode == 1 and "forbidden Coolify token name" in result.stderr)

with tempfile.TemporaryDirectory() as tmp:
    fixture = Path(tmp) / "deploy.yml"
    fixture.write_text("env:\n  COOLIFY_MOMO_DEPLOY_TOKEN: approved\n", encoding="utf-8")
    check("scoped token is accepted", policy.violations([fixture]) == [])

with tempfile.TemporaryDirectory() as tmp:
    missing = Path(tmp) / "missing.yml"
    findings = policy.violations([missing])
    check("missing deployment asset fails closed", len(findings) == 1 and "required deployment asset is missing" in findings[0])
