#!/usr/bin/env python3
"""Post-deploy conflict rollback for shared CapRover/Tailscale deploys.

Decision (t_fbb1ae02, item 2): if post-deploy verification finds that THIS
deploy introduced a hostname conflict (e.g. a race against another deploy
that claimed the same canonical hostname between preflight and mutation),
scale the NEW claimant (this deploy's own app) to 0 and restore the previous
owner's replica count/image as recorded by topology-live-preflight.py BEFORE
mutation. This script never renames or edits the registered canonical owner
in config/service-identities.json -- it only moves live docker service
replica counts/images back to what they were.

This is a separate script/step on purpose (own test, own blast radius): a
preflight bug must never be able to also break rollback.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

SSH_USER = "ubuntu"
SSH_TIMEOUT_SECONDS = 15


class RollbackActionFailed(RuntimeError):
    pass


def run_ssh(host: str, command: str) -> str:
    ssh_cmd = [
        "ssh",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", f"ConnectTimeout={SSH_TIMEOUT_SECONDS}",
        f"{SSH_USER}@{host}",
        command,
    ]
    try:
        proc = subprocess.run(
            ssh_cmd, capture_output=True, text=True, timeout=SSH_TIMEOUT_SECONDS + 5
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise RollbackActionFailed(f"ssh to {host} failed to run: {exc}") from exc
    if proc.returncode != 0:
        raise RollbackActionFailed(
            f"ssh to {host} exited {proc.returncode}: {proc.stderr.strip()[:300]}"
        )
    return proc.stdout


def scale_service(host: str, service: str, replicas: int) -> None:
    run_ssh(host, f"docker service scale {service}={replicas} --detach=false")


def restore_image(host: str, service: str, image: str) -> None:
    run_ssh(host, f"docker service update --image {image} {service} --detach=false")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pre-mutation-state", required=True, type=Path,
                         help="JSON snapshot written by topology-live-preflight.py")
    parser.add_argument("--new-claimant-host", required=True)
    parser.add_argument("--new-claimant-app", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not args.pre_mutation_state.exists():
        print(
            f"ROLLBACK ABORTED: no pre-mutation snapshot at {args.pre_mutation_state}; "
            "cannot safely restore an unknown previous owner. Manual intervention required.",
            file=sys.stderr,
        )
        return 2

    snapshot = json.loads(args.pre_mutation_state.read_text())
    previous_owner = snapshot.get("previous_owner")

    actions = []

    # Step 1: always neutralize the new claimant first, regardless of
    # whether a previous owner existed, so the conflict stops immediately.
    actions.append(("scale_new_claimant_to_zero", args.new_claimant_host, args.new_claimant_app, 0, None))

    # Step 2: restore the previous owner's replica count/image, if one was
    # recorded. If none was recorded, this deploy was onto a hostname with
    # no prior live owner -- nothing to restore, and that is NOT an error.
    if previous_owner:
        actions.append((
            "restore_previous_owner_replicas",
            previous_owner["host"],
            previous_owner["name"],
            previous_owner.get("replicas") or 1,
            previous_owner.get("image"),
        ))

    results = []
    for kind, host, service, replicas, image in actions:
        if args.dry_run:
            results.append({"action": kind, "host": host, "service": service,
                             "replicas": replicas, "image": image, "status": "dry-run"})
            continue
        try:
            scale_service(host, service, replicas)
            if image:
                restore_image(host, service, image)
            results.append({"action": kind, "host": host, "service": service,
                             "replicas": replicas, "image": image, "status": "ok"})
        except RollbackActionFailed as exc:
            results.append({"action": kind, "host": host, "service": service,
                             "replicas": replicas, "image": image, "status": "FAILED",
                             "error": str(exc)})

    failed = [r for r in results if r["status"] == "FAILED"]
    print(json.dumps({"results": results}, indent=2))
    if failed:
        print(
            f"ROLLBACK INCOMPLETE: {len(failed)} action(s) failed; "
            "manual intervention required -- see results above.",
            file=sys.stderr,
        )
        return 2
    print("ROLLBACK OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
