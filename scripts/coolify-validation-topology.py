#!/usr/bin/env python3
"""Fail-closed live topology check for one Momo Coolify validation slot."""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("topology_live", SCRIPT_DIR / "topology-live-preflight.py")
assert _spec is not None and _spec.loader is not None
tl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tl)


def emit(args, status_code: int, reason: str | None = None) -> int:
    result = {
        "status_code": status_code,
        "failure_type": None if status_code == 200 else ("verification_failure" if status_code == 503 else "topology_conflict"),
        "reason": reason,
        "hostname": args.hostname,
        "resource_name": args.resource_name,
        "target_host": "qwickapps-momo",
    }
    rendered = json.dumps(result, sort_keys=True)
    if args.result_json_out:
        args.result_json_out.write_text(rendered + "\n")
    print(rendered)
    return 0 if status_code == 200 else 2


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--resource-name", required=True)
    parser.add_argument("--caprover-hosts", nargs="*", default=tl.DEFAULT_CAPROVER_HOSTS)
    parser.add_argument("--ts-api-key", required=True)
    parser.add_argument("--tailnet", default="-")
    parser.add_argument("--tailscale-base-url", default="https://api.tailscale.com")
    parser.add_argument("--coolify-base-url", default="http://qwickapps-momo.taile324e7.ts.net:8000/api/v1")
    parser.add_argument("--coolify-token", required=True)
    parser.add_argument("--result-json-out", type=Path)
    args = parser.parse_args()

    try:
        services = []
        for host in args.caprover_hosts:
            services.extend(tl.docker_services_on_host(host))
    except tl.LiveStateUnreachable as exc:
        return emit(args, 503, f"CapRover live-state source unreachable: {exc}")
    conflicts = [
        s for s in services
        if (tl.matches_hostname_or_ghost(s.get("ts_hostname"), args.hostname)
            or tl.matches_hostname_or_ghost(tl.caprover_app_name(s.get("name", "")), args.hostname))
        and (s.get("replicas") or 0) > 0
    ]
    if conflicts:
        return emit(args, 409, "CapRover/OCI service already claims this Momo validation hostname: " + ", ".join(f"{s['name']}@{s['host']}" for s in conflicts))

    try:
        devices = tl.tailscale_devices(args.ts_api_key, args.tailnet, args.tailscale_base_url)
    except tl.LiveStateUnreachable as exc:
        return emit(args, 503, f"Tailscale live-state source unreachable: {exc}")
    ghosts = [
        d for d in devices
        if tl.matches_hostname_or_ghost(d.get("name", "").split(".")[0], args.hostname)
        and d.get("name", "").split(".")[0] != args.hostname
        and tl.device_is_online(d)
    ]
    if ghosts:
        return emit(args, 409, "online Tailscale ghost(s) claim validation hostname: " + ", ".join(d.get("name", "?") for d in ghosts))

    try:
        apps = tl.coolify_apps(args.coolify_base_url, args.coolify_token)
    except tl.LiveStateUnreachable as exc:
        return emit(args, 503, f"Coolify live-state source unreachable: {exc}")
    conflicts = [
        a for a in apps
        if a.get("name") != args.resource_name
        and args.hostname in (a.get("ts_hostnames") or [])
    ]
    if conflicts:
        return emit(args, 409, "another Coolify app claims validation hostname: " + ", ".join(a["name"] for a in conflicts))
    return emit(args, 200)


if __name__ == "__main__":
    raise SystemExit(main())
