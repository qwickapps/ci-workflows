#!/usr/bin/env python3
"""Fail closed when a deployment asset names an unapproved Coolify token."""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ALLOWED_TOKEN = "COOLIFY_MOMO_DEPLOY_TOKEN"
TOKEN_NAME = re.compile(r"\bCOOLIFY_[A-Z0-9_]*TOKEN[A-Z0-9_]*\b")
DEFAULT_PATHS = (
    ".github/workflows/deploy-app.yml",
    ".github/actions/coolify-validation/action.yml",
    "scripts/resolve-coolify-validation-credentials.sh",
    "scripts/coolify-validation-deploy.py",
)


def violations(paths: list[Path]) -> list[str]:
    findings: list[str] = []
    for path in paths:
        if not path.is_file():
            findings.append(f"{path}: required deployment asset is missing")
            continue
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for name in TOKEN_NAME.findall(line):
                if name != ALLOWED_TOKEN:
                    findings.append(f"{path}:{line_number}: forbidden Coolify token name {name}")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="*", type=Path)
    parser.add_argument("--root", type=Path, default=Path("."))
    args = parser.parse_args()
    paths = args.paths or [args.root / relative for relative in DEFAULT_PATHS]
    findings = violations(paths)
    if findings:
        print("ERROR: deployment pipeline may use only COOLIFY_MOMO_DEPLOY_TOKEN", file=sys.stderr)
        for finding in findings:
            print(f"  {finding}", file=sys.stderr)
        return 1
    print("Coolify deployment token exclusivity check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
