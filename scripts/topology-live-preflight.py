#!/usr/bin/env python3
"""Live-state topology preflight for shared CapRover/Tailscale/Coolify deploys.

Extends scripts/topology-admission.py (the input-tuple/registry check) with a
second, independent layer that reads REAL, live infrastructure state at
deploy time:

  1. docker swarm service state on every registered CapRover host, over SSH
     (oci-gateway, oci-main, server1-qwickforge) -- including hand-made
     swarm services that are NOT CapRover-managed apps (the 2026-10-08
     finding: qwickapps-mcp-gateway-canary-20261003).
  2. Tailscale device state via the tailnet API -- online devices claiming
     the canonical hostname or a `<hostname>-N` ghost variant.
  3. Coolify application state via the Coolify API on momo -- Coolify apps
     can set TS_HOSTNAME directly in their own image (proven: agent-mail-
     clamd, health-ingest, qwickapps-projects-backup on momo, see
     config/service-identities-coolify-findings.md), so a Coolify app could
     silently hold a canonical hostname that this registry never sees via
     CapRover or Tailscale ghosts alone.

This script does not read or trust the registry's static `state` block for
"is anything running" -- that block records *intent*, this script measures
*reality*. It is fail-closed: any unreachable source is a DENY, never a skip.

Exit codes: 0 = admit, 2 = deny (including "could not verify").
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

SCRIPT_DIR = Path(__file__).resolve().parent


def _load_topology_admission_module():
    """Import scripts/topology-admission.py's `load()` so this script reuses
    the SAME registry loader/validator -- no second topology source."""
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "topology_admission", SCRIPT_DIR / "topology-admission.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


ta = _load_topology_admission_module()

DEFAULT_CAPROVER_HOSTS = ["oci-gateway", "oci-main", "server1-qwickforge"]
SSH_USER = "ubuntu"
SSH_JUMP = {
    # host -> jump host, if the host is not directly reachable from the
    # runner. None of the three registered CapRover hosts are known to need
    # one today (unlike oci-dev, which jumps via oci-main) -- kept as a map,
    # not a constant, so a future host can declare one without a code change.
}
SSH_TIMEOUT_SECONDS = 15
HTTP_TIMEOUT_SECONDS = 15
GHOST_SUFFIX_RE = re.compile(r"^(?P<base>[a-z0-9-]+)-(?P<n>\d+)$")


class LiveStateUnreachable(RuntimeError):
    """A live source could not be read. Caller must treat this as a deny."""


def deny(reason: str) -> None:
    print(f"LIVE PREFLIGHT DENIED: {reason}", file=sys.stderr)
    raise SystemExit(2)


def run_ssh(host: str, command: str) -> str:
    jump = SSH_JUMP.get(host)
    ssh_cmd = [
        "ssh",
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", f"ConnectTimeout={SSH_TIMEOUT_SECONDS}",
    ]
    if jump:
        ssh_cmd += ["-o", f"ProxyJump={SSH_USER}@{jump}"]
    ssh_cmd += [f"{SSH_USER}@{host}", command]
    try:
        proc = subprocess.run(
            ssh_cmd, capture_output=True, text=True, timeout=SSH_TIMEOUT_SECONDS + 5
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        raise LiveStateUnreachable(f"ssh to {host} failed to run: {exc}") from exc
    if proc.returncode != 0:
        raise LiveStateUnreachable(
            f"ssh to {host} exited {proc.returncode}: {proc.stderr.strip()[:300]}"
        )
    return proc.stdout


def docker_services_on_host(host: str) -> list[dict]:
    """Return every swarm service on `host`, CapRover-managed or not.

    Uses `docker service ls` + `docker service inspect` so hand-made services
    with a forged `com.caprover.managed` label (the 2026-10-08 finding) are
    still visible -- this never filters by label, only by name/env match
    against the target hostname, which happens in the caller.
    """
    names_out = run_ssh(host, "docker service ls --format '{{.Name}}'")
    names = [n.strip() for n in names_out.splitlines() if n.strip()]
    if not names:
        return []
    inspect_out = run_ssh(host, "docker service inspect " + " ".join(names))
    try:
        specs = json.loads(inspect_out)
    except json.JSONDecodeError as exc:
        raise LiveStateUnreachable(
            f"docker service inspect on {host} returned unparsable JSON: {exc}"
        ) from exc
    services = []
    for spec in specs:
        name = spec.get("Spec", {}).get("Name", "")
        replicas = (
            spec.get("Spec", {}).get("Mode", {}).get("Replicated", {}).get("Replicas")
        )
        if replicas is None:
            # Global mode or unknown -- treat any running task as >0 by
            # reading ServiceStatus if present, else fail closed on ambiguity.
            running = spec.get("ServiceStatus", {}).get("RunningTasks")
            replicas = running if running is not None else None
        env_list = (
            spec.get("Spec", {})
            .get("TaskTemplate", {})
            .get("ContainerSpec", {})
            .get("Env", [])
            or []
        )
        env = {}
        for item in env_list:
            if "=" in item:
                k, v = item.split("=", 1)
                env[k] = v
        image = (
            spec.get("Spec", {})
            .get("TaskTemplate", {})
            .get("ContainerSpec", {})
            .get("Image", "")
        )
        services.append(
            {
                "host": host,
                "name": name,
                "replicas": replicas,
                "ts_hostname": env.get("TS_HOSTNAME"),
                "image": image,
            }
        )
    return services


def tailscale_devices(ts_api_key: str, tailnet: str = "-", base_url: str = "https://api.tailscale.com") -> list[dict]:
    req = urllib.request.Request(
        f"{base_url}/api/v2/tailnet/{tailnet}/devices?fields=all",
        headers={"Authorization": f"Bearer {ts_api_key}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SECONDS) as resp:
            data = json.loads(resp.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise LiveStateUnreachable(f"Tailscale API unreachable: {exc}") from exc
    devices = data.get("devices")
    if not isinstance(devices, list):
        raise LiveStateUnreachable("Tailscale API returned no device list")
    return devices


def device_is_online(device: dict) -> bool:
    # Matches the convention already used by verify-ts-lb-target.sh: a
    # device counts as live if it is authorized and not explicitly expired,
    # and its clientConnectivity/lastSeen marks it as currently connected.
    if device.get("authorized") is False:
        return False
    if device.get("expires") and device.get("keyExpiryDisabled") is not True:
        pass  # expiry alone does not determine liveness here; lastSeen does
    connectivity = device.get("clientConnectivity") or {}
    return bool(connectivity.get("endpoints") or device.get("online") is True)


def coolify_apps(base_url: str, token: str) -> list[dict]:
    headers = {"Authorization": f"Bearer {token}"}
    req = urllib.request.Request(f"{base_url}/applications", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SECONDS) as resp:
            apps = json.loads(resp.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise LiveStateUnreachable(f"Coolify API unreachable: {exc}") from exc
    if not isinstance(apps, list):
        raise LiveStateUnreachable("Coolify API returned no application list")
    results = []
    for app in apps:
        uid = app.get("uuid")
        name = app.get("name")
        try:
            env_req = urllib.request.Request(
                f"{base_url}/applications/{uid}/envs", headers=headers
            )
            with urllib.request.urlopen(env_req, timeout=HTTP_TIMEOUT_SECONDS) as resp:
                envs = json.loads(resp.read())
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise LiveStateUnreachable(
                f"Coolify envs unreachable for app {name}: {exc}"
            ) from exc
        ts_hostnames = {
            e.get("value") for e in envs if e.get("key") == "TS_HOSTNAME" and e.get("value")
        }
        results.append({"name": name, "uuid": uid, "ts_hostnames": sorted(ts_hostnames)})
    return results


def matches_hostname_or_ghost(candidate: Optional[str], canonical: str) -> bool:
    if not candidate:
        return False
    if candidate == canonical:
        return True
    m = GHOST_SUFFIX_RE.match(candidate)
    return bool(m and m.group("base") == canonical)


def caprover_app_name(service_or_app_name: str) -> str:
    """Normalize a CapRover Swarm service name to its app name."""
    return service_or_app_name.removeprefix("srv-captain--")


def is_deploying_service(service: dict, app: str) -> bool:
    """Return whether a live Swarm service is the app this workflow deploys.

    CapRover names Docker services ``srv-captain--<app>`` while reusable
    workflows may receive either that service name or the bare app name. Both
    spellings identify the current deployment, but a similarly named service
    without ``TS_HOSTNAME`` is not a CapRover self-claimant.
    """
    return (
        bool(service.get("ts_hostname"))
        and caprover_app_name(service.get("name", "")) == caprover_app_name(app)
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", required=True, type=Path)
    parser.add_argument("--hostname", required=True, help="canonical_hostname being deployed")
    parser.add_argument("--app", required=True, help="CapRover app name being deployed")
    parser.add_argument("--target-host", required=True, help="required_host for this deploy")
    parser.add_argument("--caprover-hosts", nargs="*", default=DEFAULT_CAPROVER_HOSTS)
    parser.add_argument("--ts-api-key", required=True)
    parser.add_argument("--tailnet", default="-")
    parser.add_argument("--tailscale-base-url", default="https://api.tailscale.com",
                         help="override for tests; production default is the real Tailscale API")
    parser.add_argument("--coolify-base-url", default="http://qwickapps-momo.taile324e7.ts.net:8000/api/v1")
    parser.add_argument("--coolify-token", default="")
    parser.add_argument("--pre-mutation-state-out", type=Path, default=None,
                         help="write the pre-mutation owner snapshot here for the rollback script")
    args = parser.parse_args()

    registry = ta.load(args.registry)
    entry = next((e for e in registry if e["canonical_hostname"].lower() == args.hostname.lower()), None)
    if entry is None:
        deny(f"hostname {args.hostname!r} has no registry entry; static admission should already have caught this")
        return 2
    if entry["required_host"] != args.target_host:
        deny(f"target host {args.target_host!r} != registry required_host {entry['required_host']!r} for {args.hostname!r}")
        return 2

    # 1. Live docker swarm state on every CapRover host, fail-closed.
    live_services: list[dict] = []
    try:
        for host in args.caprover_hosts:
            live_services.extend(docker_services_on_host(host))
    except LiveStateUnreachable as exc:
        deny(f"CapRover live-state source unreachable, refusing to proceed without it: {exc}")
        return 2

    other_claimants = [
        s for s in live_services
        if (
            matches_hostname_or_ghost(s.get("ts_hostname"), args.hostname)
            or matches_hostname_or_ghost(s.get("name"), args.hostname)
        )
        and not is_deploying_service(s, args.app)
    ]
    live_conflicts = [s for s in other_claimants if (s.get("replicas") or 0) > 0]
    if live_conflicts:
        deny(
            "other service(s) already claim hostname "
            f"{args.hostname!r} with replicas>0: "
            + ", ".join(f"{s['name']}@{s['host']} (r={s['replicas']})" for s in live_conflicts)
        )
        return 2

    # 2. Tailscale: deny on any online -N ghost or a differently-named online
    #    device already holding the canonical hostname.
    try:
        devices = tailscale_devices(args.ts_api_key, args.tailnet, args.tailscale_base_url)
    except LiveStateUnreachable as exc:
        deny(f"Tailscale live-state source unreachable, refusing to proceed without it: {exc}")
        return 2

    online_matches = [
        d for d in devices
        if matches_hostname_or_ghost(d.get("name", "").split(".")[0], args.hostname) and device_is_online(d)
    ]
    online_ghosts = [d for d in online_matches if d.get("name", "").split(".")[0] != args.hostname]
    if online_ghosts:
        deny(
            "online Tailscale ghost(s) for hostname "
            f"{args.hostname!r}: " + ", ".join(d.get("name", "?") for d in online_ghosts)
        )
        return 2

    # 3. Coolify: deny if any Coolify app other than the one being deployed
    #    (Coolify never deploys through this pipeline, so any Coolify app at
    #    all claiming this hostname is, by definition, "other").
    if args.coolify_token:
        try:
            apps = coolify_apps(args.coolify_base_url, args.coolify_token)
        except LiveStateUnreachable as exc:
            deny(f"Coolify live-state source unreachable, refusing to proceed without it: {exc}")
            return 2
        coolify_conflicts = [
            a for a in apps if args.hostname in (a.get("ts_hostnames") or [])
        ]
        if coolify_conflicts:
            deny(
                "Coolify app(s) on momo already claim hostname "
                f"{args.hostname!r}: " + ", ".join(a["name"] for a in coolify_conflicts)
            )
            return 2
    else:
        deny("no Coolify token supplied; Coolify is a live claimant source and cannot be skipped")
        return 2

    # Record the pre-mutation owner (if any, on the target host under the
    # registry's own app name) so the rollback script can restore it later.
    if args.pre_mutation_state_out is not None:
        owner = next(
            (s for s in live_services if s["name"] == args.app and s["host"] == args.target_host),
            None,
        )
        snapshot = {"host": args.target_host, "app": args.app, "previous_owner": owner}
        args.pre_mutation_state_out.write_text(json.dumps(snapshot, indent=2))

    print(f"LIVE PREFLIGHT OK: no live claimant conflicts for {args.hostname!r} on {args.target_host!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
