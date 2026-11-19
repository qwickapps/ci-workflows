#!/usr/bin/env python3
"""Write the final Momo validation evidence record.

Merges the deploy-time record (slot, digest, Coolify deployment id, env key
names + hash, rollback plan) with the outcome of every post-deploy gate, so the
record proves the validated state rather than just the deploy.

Gate outcomes come from O_* environment variables (GitHub step outcomes:
success, failure, cancelled, skipped, or empty when the step never ran).
The verdict is "validated" only when every required gate succeeded, every
optional gate succeeded or was skipped, and no rollback ran. Anything else is
"not-validated". The record never contains secret values.
"""
import argparse
import json
import os
import sys

SCHEMA = "coolify-secondary-validation-final-evidence/v1"
REQUIRED = ("preflight", "deploy", "health", "deep_health", "postcheck")
OPTIONAL = ("smoke_path", "smoke_command", "e2e_suite", "migrations", "e2e_command")


def outcome(name):
    return os.environ.get("O_" + name.upper(), "") or "not-run"


def build_record(deploy_evidence_path):
    deploy = None
    deploy_error = None
    try:
        with open(deploy_evidence_path, encoding="utf-8") as fh:
            deploy = json.load(fh)
    except FileNotFoundError:
        deploy_error = "deploy evidence record missing"
    except (OSError, ValueError) as exc:
        deploy_error = "deploy evidence record unreadable: %s" % type(exc).__name__

    gates = {name: outcome(name) for name in REQUIRED + OPTIONAL}
    rollback = outcome("rollback")
    reasons = []
    if deploy_error:
        reasons.append(deploy_error)
    for name in REQUIRED:
        if gates[name] != "success":
            reasons.append("required gate %s: %s" % (name, gates[name]))
    for name in OPTIONAL:
        if gates[name] not in ("success", "skipped", "not-run"):
            reasons.append("gate %s: %s" % (name, gates[name]))
    if rollback not in ("skipped", "not-run"):
        reasons.append("rollback ran: %s" % rollback)

    return {
        "schema": SCHEMA,
        "verdict": "not-validated" if reasons else "validated",
        "reasons": reasons,
        "gates": gates,
        "rollback": rollback,
        "deploy": deploy,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--deploy-evidence", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    record = build_record(args.deploy_evidence)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(record, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print("final evidence verdict: %s" % record["verdict"])
    # A missing deploy record is an evidence failure in its own right.
    return 1 if record["deploy"] is None and outcome("deploy") == "success" else 0


if __name__ == "__main__":
    sys.exit(main())
