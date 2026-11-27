#!/usr/bin/env python3
"""Fail closed on GitHub Actions jobs that violate the CI host-role policy."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import yaml


class PolicyError(ValueError):
    """The policy file is malformed or incomplete."""


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise PolicyError(f"cannot read policy {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise PolicyError("policy must be a JSON object")
    if data.get("schema_version") != 1:
        raise PolicyError("policy schema_version must be 1")
    for key in ("julie_required_labels", "choco_allowlist", "macmini_allowlist"):
        if not isinstance(data.get(key), list):
            raise PolicyError(f"policy {key} must be a list")
    if not all(isinstance(label, str) and label for label in data["julie_required_labels"]):
        raise PolicyError("policy julie_required_labels must contain nonempty strings")
    for key in ("choco_allowlist", "macmini_allowlist"):
        for entry in data[key]:
            if not isinstance(entry, dict):
                raise PolicyError(f"policy {key} entries must be objects")
            if not isinstance(entry.get("path"), str) or not entry["path"].startswith(".github/workflows/"):
                raise PolicyError(f"policy {key} entry path must be an exact .github/workflows path")
            jobs = entry.get("jobs")
            if not isinstance(jobs, list) or not jobs or not all(isinstance(job, str) and job for job in jobs):
                raise PolicyError(f"policy {key} entry jobs must be a nonempty string list")
    return data


def exact_allowlisted(policy: dict[str, Any], key: str, path: str, job_id: str) -> bool:
    return any(entry["path"] == path and job_id in entry["jobs"] for entry in policy[key])


def normalized_labels(value: Any) -> list[str] | None:
    if isinstance(value, str):
        if "${{" in value:
            return None
        return [value]
    if isinstance(value, list) and all(isinstance(label, str) and "${{" not in label for label in value):
        return sorted(value)
    return None


def lint_workflows(policy: dict[str, Any], workflow_dir: Path) -> list[str]:
    repo_root = workflow_dir.parent.parent
    errors: list[str] = []
    paths = sorted([*workflow_dir.glob("*.yml"), *workflow_dir.glob("*.yaml")])
    for path in paths:
        try:
            document = yaml.safe_load(path.read_text()) or {}
        except yaml.YAMLError as exc:
            errors.append(f"{path}: YAML parse error: {exc}")
            continue
        jobs = document.get("jobs", {})
        if not isinstance(jobs, dict):
            errors.append(f"{path}: jobs must be a mapping")
            continue
        relative_path = path.relative_to(repo_root).as_posix()
        for job_id, job in jobs.items():
            if not isinstance(job, dict) or "runs-on" not in job:
                continue
            labels = normalized_labels(job["runs-on"])
            location = f"{relative_path}:{job_id}"
            if labels is None:
                errors.append(f"{location}: dynamic or non-string runs-on is prohibited")
                continue
            label_set = set(labels)
            if "choco" in label_set:
                if not exact_allowlisted(policy, "choco_allowlist", relative_path, str(job_id)):
                    errors.append(f"{location}: choco is Hermes-only and is not exact-path allowlisted")
                continue
            if "macmini" in label_set:
                if not exact_allowlisted(policy, "macmini_allowlist", relative_path, str(job_id)):
                    errors.append(f"{location}: macmini is Apple-build-only and is not exact-path allowlisted")
                continue
            if "self-hosted" in label_set or "julie" in label_set or "interserver-x64" in label_set:
                required = set(policy["julie_required_labels"])
                if not required.issubset(label_set):
                    errors.append(
                        f"{location}: non-Mac self-hosted CI must include Julie labels {sorted(required)!r}; got {labels!r}"
                    )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", type=Path, default=Path("config/ci-host-role-policy.json"))
    parser.add_argument("--workflow-dir", type=Path, default=Path(".github/workflows"))
    args = parser.parse_args()
    try:
        policy = load_json(args.policy)
        errors = lint_workflows(policy, args.workflow_dir)
    except (PolicyError, OSError) as exc:
        print(f"CI HOST ROLE POLICY ERROR: {exc}", file=sys.stderr)
        return 2
    if errors:
        print("CI HOST ROLE DENY", file=sys.stderr)
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"CI HOST ROLE ALLOW workflows={args.workflow_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
