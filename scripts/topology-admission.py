#!/usr/bin/env python3
"""Fail-closed topology admission for shared deployments.

The registry is deliberately machine-readable JSON (valid YAML subset) so the
same source can render deployment checks and a Windmill inventory without a
runtime package install. This program never mutates runtime state.
"""
from __future__ import annotations
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_REGISTRY = ROOT / "config" / "service-identities.json"


def fail(message: str) -> None:
    print(f"TOPOLOGY ADMISSION DENIED: {message}", file=sys.stderr)
    raise SystemExit(2)


def load(path: Path) -> list[dict]:
    data: dict[str, object] = {}
    try:
        parsed = json.loads(path.read_text())
        if isinstance(parsed, dict):
            data = parsed
        else:
            fail("registry root must be an object")
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"registry unreadable: {exc}")
    raw_entries = data.get("services")
    if not isinstance(raw_entries, list) or not raw_entries:
        fail("registry has no service identities")
    typed_entries: list[dict] = []
    for entry in raw_entries:
        if not isinstance(entry, dict):
            fail("registry services must be objects")
        typed_entries.append(entry)
    required = {"canonical_hostname", "workload_owner", "repo", "platform", "app", "required_host", "role", "state"}
    owners: dict[str, dict] = {}
    for entry in typed_entries:
        missing = required - set(entry)
        if missing:
            fail(f"registry entry missing {','.join(sorted(missing))}")
        hostname = entry["canonical_hostname"].lower()
        if not re.fullmatch(r"[a-z0-9-]+", hostname):
            fail(f"invalid canonical hostname {hostname!r}")
        if hostname in owners:
            fail(f"duplicate canonical owner in registry for {hostname}: {owners[hostname]['app']} and {entry['app']}")
        if entry["role"] == "load-balancer" and entry["required_host"] != "oci-gateway":
            fail(f"LB {entry['app']} is not assigned to oci-gateway")
        if not isinstance(entry["state"], dict) or not entry["state"].get("mode"):
            fail(f"registry entry {entry['app']} has no state mode")
        owners[hostname] = entry
    return typed_entries


def render(entries: list[dict], output: Path) -> None:
    inventory = {"version": 1, "services": []}
    for entry in entries:
        inventory["services"].append({
            "hostname": entry["canonical_hostname"],
            "platform": entry["platform"],
            "app": entry["app"],
            "host": entry["required_host"],
            "role": entry["role"],
            "state": entry["state"],
            "repo": entry["repo"],
        })
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(inventory, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry", type=Path, default=DEFAULT_REGISTRY)
    parser.add_argument("--render-windmill-inventory", type=Path)
    parser.add_argument("--host")
    parser.add_argument("--platform")
    parser.add_argument("--app")
    parser.add_argument("--hostname")
    parser.add_argument("--image-ref", default="")
    parser.add_argument("--source-sha", default="")
    parser.add_argument("--source-merged", choices=("true", "false"))
    parser.add_argument("--production", action="store_true")
    args = parser.parse_args()
    entries = load(args.registry)
    if args.render_windmill_inventory:
        render(entries, args.render_windmill_inventory)
        print(f"Rendered Windmill inventory: {args.render_windmill_inventory}")
        return
    required = (args.host, args.platform, args.app, args.hostname)
    if not all(required):
        fail("--host, --platform, --app and --hostname are required for admission")
    hostname = args.hostname.lower()
    matches = [e for e in entries if e["canonical_hostname"].lower() == hostname]
    if len(matches) != 1:
        fail(f"canonical hostname {hostname} has {len(matches)} registry owners")
    entry = matches[0]
    if (args.host, args.platform, args.app) != (entry["required_host"], entry["platform"], entry["app"]):
        fail("tuple mismatch for %s: requested host=%s platform=%s app=%s; registry requires host=%s platform=%s app=%s" % (
            hostname, args.host, args.platform, args.app,
            entry["required_host"], entry["platform"], entry["app"]))
    if "qwickway" in args.image_ref.lower() and args.host != "oci-gateway":
        fail("QwickWay/LB image is permitted only on oci-gateway")
    if args.production:
        if not re.fullmatch(r"[0-9a-f]{40}", args.source_sha):
            fail("production deploy lacks a full git SHA; direct/tar source is forbidden")
        if args.source_merged != "true":
            fail("production source SHA is not proven reachable from the default branch")
    print("TOPOLOGY ADMISSION PASSED: %s -> %s/%s/%s" % (hostname, args.host, args.platform, args.app))

if __name__ == "__main__":
    main()
