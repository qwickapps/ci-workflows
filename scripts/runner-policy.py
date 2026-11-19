#!/usr/bin/env python3
"""Validate GitHub Actions runner selection and completed-run provenance."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml


def load_json(path: Path) -> dict[str, Any]:
    with path.open() as handle:
        return json.load(handle)


def repository_policy(policy: dict[str, Any], repo: str) -> dict[str, Any]:
    return policy["repositories"].get(repo, policy["repositories"]["*"])


def classify(path: Path, job_id: str) -> str:
    text = f"{path.name} {job_id}".lower()
    if path.name.endswith(("-tests.yml", "-tests.yaml")):
        return "test"
    if "multiarch" in text or re.search(r"(^|[-_])arm", text):
        return "arm"
    if path.name.startswith(("deploy-app", "promote-")):
        return "deploy"
    if any(word in text for word in ("test", "lint", "validate", "scan", "guard", "hygiene", "check", "definition-of-done", "evidence-gate")):
        return "security" if "scan" in text else "test"
    if any(word in text for word in ("deploy", "promote", "provision", "config-apply", "fetch-secrets")):
        return "deploy"
    if any(word in text for word in ("test", "lint", "validate", "scan", "guard", "hygiene", "check", "definition-of-done", "evidence-gate")):
        return "security" if "scan" in text else "test"
    return "build"


def normalized_labels(value: Any) -> list[str] | None:
    if isinstance(value, str):
        if value.startswith("${{"):
            return None
        try:
            decoded = json.loads(value)
        except json.JSONDecodeError:
            return [value]
        value = decoded
    if isinstance(value, list) and all(isinstance(label, str) for label in value):
        return sorted(value)
    return None


def allowed_entries(repo_policy: dict[str, Any], job_class: str) -> list[dict[str, Any]]:
    job_classes = repo_policy["job_classes"]
    if job_class not in job_classes:
        raise ValueError(f"no policy class {job_class!r}")
    return job_classes[job_class]["allowed"]


def label_set_allowed(repo_policy: dict[str, Any], job_class: str, labels: list[str]) -> bool:
    return any(sorted(entry["labels"]) == labels for entry in allowed_entries(repo_policy, job_class))


def entry_matches_provenance(entry: dict[str, Any], labels: list[str], name: str, group: str) -> bool:
    if sorted(entry["labels"]) != labels:
        return False
    allowed_groups = entry.get("runner_groups")
    if allowed_groups and group not in allowed_groups:
        return False
    allowed_names = entry.get("runner_names")
    return not allowed_names or name in allowed_names


def validate_workflows(policy: dict[str, Any], repo: str, workflow_dir: Path) -> list[str]:
    repo_policy = repository_policy(policy, repo)
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
        for job_id, job in jobs.items():
            if not isinstance(job, dict) or "runs-on" not in job:
                continue
            labels = normalized_labels(job["runs-on"])
            job_class = classify(path, str(job_id))
            if labels is None:
                errors.append(f"{path.name}:{job_id}: unresolved runs-on expression is prohibited")
            elif not label_set_allowed(repo_policy, job_class, labels):
                errors.append(
                    f"{path.name}:{job_id}: labels {labels!r} are not approved for {repo} class {job_class}"
                )
    return errors


def gh_api(path: str) -> dict[str, Any]:
    result = subprocess.run(
        ["gh", "api", path], check=False, text=True, capture_output=True
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"gh api failed for {path}")
    return json.loads(result.stdout)


def provenance_job_class(workflow_path: Path, job_name: str) -> str:
    """Prefer an executed job's explicit name when it differentiates build from deploy."""
    name = job_name.lower()
    if name.startswith("build"):
        return "build"
    if name.startswith("test") or "quality" in name:
        return "test"
    return classify(workflow_path, job_name)


def provenance(policy: dict[str, Any], repo: str, run_id: str) -> tuple[bool, list[str]]:
    repo_policy = repository_policy(policy, repo)
    run = gh_api(f"repos/{repo}/actions/runs/{run_id}")
    jobs = gh_api(f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100").get("jobs", [])
    lines = [f"repo={repo}", f"run_id={run_id}", f"head_sha={run.get('head_sha', '')}"]
    allowed = True
    for job in jobs:
        job_class = provenance_job_class(Path(run.get("path", "workflow.yml")), job.get("name", ""))
        labels = sorted(job.get("labels") or [])
        name = job.get("runner_name") or ""
        group = job.get("runner_group_name") or ""
        entries = allowed_entries(repo_policy, job_class)
        match = any(entry_matches_provenance(entry, labels, name, group) for entry in entries)
        conclusion = "allow" if match else "deny"
        lines.append(
            f"job={job.get('name','')} runner_name={name} runner_group={group} labels={','.join(labels)} class={job_class} conclusion={conclusion}"
        )
        allowed = allowed and match
    lines.append(f"conclusion={'allow' if allowed else 'deny'}")
    return allowed, lines


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", type=Path, default=Path(".github/runner-policy.json"))
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate = subparsers.add_parser("validate")
    validate.add_argument("--repo", required=True)
    validate.add_argument("--workflow-dir", type=Path, required=True)
    check = subparsers.add_parser("provenance")
    check.add_argument("--repo", required=True)
    check.add_argument("--run-id", required=True)
    args = parser.parse_args()
    policy = load_json(args.policy)
    if args.command == "validate":
        errors = validate_workflows(policy, args.repo, args.workflow_dir)
        if errors:
            print("RUNNER POLICY DENY", file=sys.stderr)
            print("\n".join(errors), file=sys.stderr)
            return 1
        print(f"RUNNER POLICY ALLOW repo={args.repo} workflows={args.workflow_dir}")
        return 0
    allowed, lines = provenance(policy, args.repo, args.run_id)
    print("\n".join(lines))
    return 0 if allowed else 1


if __name__ == "__main__":
    raise SystemExit(main())
