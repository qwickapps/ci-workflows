#!/usr/bin/env python3
"""Deploy one closed secondary validation slot to Momo Coolify.

The scoped Coolify token is read only from COOLIFY_MOMO_DEPLOY_TOKEN. Secret
values are never printed. Existing resources must match the exact configured Momo
server/destination; a same-named resource elsewhere is refused.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DIGEST_RE = re.compile(r"^sha256:([0-9a-f]{64})$")


class DeployError(RuntimeError):
    pass


def image_base(image_ref: str) -> str:
    """Strip an optional @digest and an optional :tag (never a registry port)."""
    base = image_ref.split("@", 1)[0]
    last_slash = base.rfind("/")
    colon = base.find(":", last_slash + 1)
    return base[:colon] if colon != -1 else base


def pinned_image(image_ref: str, image_digest: str) -> tuple[str, str]:
    """Return Coolify's native digest form (name='<base>@sha256', tag='<hex>').

    Coolify 4.x deploys `{name}:{tag}`, so this pulls `<base>@sha256:<hex>`:
    the exact digest verify-provenance resolved, never a movable tag such as
    release-candidate. A ref that already carries a different digest is a
    provenance mismatch and is refused.
    """
    match = DIGEST_RE.fullmatch(image_digest or "")
    if not match:
        raise DeployError("Coolify validation requires the verified sha256 image digest from verify-provenance")
    if "@" in image_ref and image_ref.split("@", 1)[1] != image_digest:
        raise DeployError("image_ref digest differs from the verified provenance digest; refusing deployment")
    base = image_base(image_ref)
    if not base:
        raise DeployError("image_ref has no repository component")
    return f"{base}@sha256", match.group(1)


def env_evidence(envs: list[dict]) -> dict:
    """Non-secret fingerprint of the rendered env: key names plus a digest."""
    canonical = "\n".join(f"{e['key']}={e['value']}" for e in envs).encode()
    return {"keys": [e["key"] for e in envs], "sha256": hashlib.sha256(canonical).hexdigest()}


class Coolify:
    def __init__(self, base: str, token: str):
        self.base = base.rstrip("/")
        self.token = token

    def request(self, method: str, path: str, payload=None, *, secret_body=False):
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(
            self.base + path,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            body = exc.read().decode(errors="replace")
            detail = "response body withheld because it may contain rendered secrets" if secret_body else body[:500]
            raise DeployError(f"Coolify {method} {path} failed with HTTP {exc.code}: {detail}") from exc
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise DeployError(f"Coolify {method} {path} failed: {exc}") from exc


def load_config(path: Path) -> dict:
    cfg = json.loads(path.read_text())
    if cfg.get("schema") != "coolify-secondary-validation/v1":
        raise DeployError("unsupported Coolify validation config schema")
    if set(cfg.get("slots", {})) != {"build", "uat"}:
        raise DeployError("Coolify validation config must define exactly build and uat slots")
    return cfg


def parse_env(path: Path, expected_hostname: str) -> list[dict]:
    values: dict[str, str] = {}
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise DeployError(f"rendered env line {number} has no '='")
        key, value = line.split("=", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            raise DeployError(f"rendered env line {number} has invalid key")
        if key in values:
            raise DeployError(f"rendered env contains duplicate key {key}")
        values[key] = value
    if values.get("TS_HOSTNAME") != expected_hostname:
        raise DeployError(
            f"secondary validation requires TS_HOSTNAME={expected_hostname}; rendered env declared a different or empty hostname"
        )
    return [{"key": k, "value": v, "is_preview": False} for k, v in sorted(values.items())]


def find_app(api: Coolify, name: str) -> dict | None:
    apps = api.request("GET", "/applications")
    matches = [a for a in apps if a.get("name") == name]
    if len(matches) > 1:
        raise DeployError(f"multiple Coolify applications are named {name!r}; refusing ambiguous target")
    return matches[0] if matches else None


def assert_target(app: dict, cfg: dict, name: str) -> None:
    destination = app.get("destination") or {}
    server = destination.get("server") or {}
    if app.get("build_pack") != "dockerimage":
        raise DeployError(f"Coolify app {name!r} exists with unsupported build_pack={app.get('build_pack')!r}")
    if destination.get("uuid") != cfg["server"]["destination_uuid"] or server.get("uuid") != cfg["server"]["uuid"]:
        raise DeployError(f"Coolify app {name!r} is not on the exact configured Momo destination; refusing mutation")


def app_state(api: Coolify, uuid: str) -> dict:
    app = api.request("GET", f"/applications/{uuid}")
    envs = api.request("GET", f"/applications/{uuid}/envs")
    return {
        "uuid": uuid,
        "image_name": app.get("docker_registry_image_name"),
        "image_tag": app.get("docker_registry_image_tag"),
        "envs": [
            {"key": e.get("key"), "value": e.get("value", ""), "is_preview": bool(e.get("is_preview", False))}
            for e in envs if e.get("key")
        ],
    }


def write_snapshot(path: Path, snapshot: dict) -> None:
    path.write_text(json.dumps(snapshot))
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)


def trigger_and_wait(api: Coolify, uuid: str) -> str:
    result = api.request("POST", f"/deploy?uuid={urllib.parse.quote(uuid)}&force=false")
    deployments = result.get("deployments") or []
    deployment_uuid = deployments[0].get("deployment_uuid") if deployments else None
    if not deployment_uuid:
        raise DeployError("Coolify deploy returned no deployment_uuid; refusing untracked deployment")
    for _ in range(60):
        record = api.request("GET", f"/deployments/{deployment_uuid}")
        status = record.get("status", "unknown")
        print(f"Coolify deployment status: {status}")
        if status == "finished":
            return deployment_uuid
        if status in {"failed", "cancelled-by-user", "error"}:
            raise DeployError(f"Coolify deployment entered terminal state {status!r}")
        time.sleep(10)
    raise DeployError("Coolify deployment did not finish within 10 minutes")


def restore(api: Coolify, snapshot: dict) -> None:
    uuid = snapshot.get("uuid")
    if snapshot.get("created"):
        if uuid:
            api.request("DELETE", f"/applications/{uuid}?delete_volumes=false&delete_connected_networks=true&delete_configurations=true&docker_cleanup=true")
        return
    if not uuid or not snapshot.get("image_name") or not snapshot.get("image_tag"):
        raise DeployError("rollback snapshot is incomplete")
    api.request("PATCH", f"/applications/{uuid}", {
        "docker_registry_image_name": snapshot["image_name"],
        "docker_registry_image_tag": snapshot["image_tag"],
    })
    api.request("PATCH", f"/applications/{uuid}/envs/bulk", {"data": snapshot.get("envs", [])}, secret_body=True)
    trigger_and_wait(api, uuid)


def deploy(args, cfg: dict, api: Coolify) -> None:
    slot = cfg["slots"].get(args.role)
    if slot is None:
        raise DeployError("secondary Coolify deployment supports only build or uat")
    expected_name = args.app_name + slot["suffix"]
    if args.resource_name != expected_name:
        raise DeployError(f"resource name must be the closed {args.role} slot {expected_name!r}")
    image_name, image_tag = pinned_image(args.image_ref, args.image_digest)
    envs = parse_env(args.env_file, expected_name)

    existing = find_app(api, expected_name)
    if existing:
        assert_target(existing, cfg, expected_name)
        snapshot = {"created": False, **app_state(api, existing["uuid"])}
        uuid = existing["uuid"]
    else:
        snapshot = {"created": True, "uuid": None}
        created = api.request("POST", "/applications/dockerimage", {
            "project_uuid": cfg["project"]["uuid"],
            "server_uuid": cfg["server"]["uuid"],
            "destination_uuid": cfg["server"]["destination_uuid"],
            "environment_name": cfg["project"]["environment_name"],
            "docker_registry_image_name": image_name,
            "docker_registry_image_tag": image_tag,
            "ports_exposes": str(args.container_port),
            "name": expected_name,
            "instant_deploy": False,
        })
        uuid = created.get("uuid")
        if not uuid:
            raise DeployError("Coolify application creation returned no uuid")
        snapshot["uuid"] = uuid
    write_snapshot(args.snapshot, snapshot)

    try:
        if snapshot["created"]:
            # A new resource must land on the exact Momo destination before
            # anything is deployed to it; otherwise it is removed again.
            assert_target(api.request("GET", f"/applications/{uuid}"), cfg, expected_name)
        api.request("PATCH", f"/applications/{uuid}", {
            "docker_registry_image_name": image_name,
            "docker_registry_image_tag": image_tag,
            "ports_exposes": str(args.container_port),
        })
        api.request("PATCH", f"/applications/{uuid}/envs/bulk", {"data": envs}, secret_body=True)
        deployment_uuid = trigger_and_wait(api, uuid)
        current = api.request("GET", f"/applications/{uuid}")
        current_envs = api.request("GET", f"/applications/{uuid}/envs")
        current_map = {e.get("key"): e.get("value", "") for e in current_envs}
        expected_map = {e["key"]: e["value"] for e in envs}
        if current.get("docker_registry_image_name") != image_name or current.get("docker_registry_image_tag") != image_tag:
            raise DeployError("Coolify image readback did not match the requested immutable image")
        if any(current_map.get(k) != v for k, v in expected_map.items()):
            raise DeployError("Coolify rendered-env readback did not match the requested values")
        if args.evidence_out:
            args.evidence_out.write_text(json.dumps({
                "schema": "coolify-secondary-validation-evidence/v1",
                "lane": "secondary",
                "backend": "coolify-momo",
                "role": args.role,
                "resource_name": expected_name,
                "resource_uuid": uuid,
                "created": bool(snapshot["created"]),
                "server_uuid": cfg["server"]["uuid"],
                "destination_uuid": cfg["server"]["destination_uuid"],
                "image": f"{image_name}:{image_tag}",
                "image_digest": args.image_digest,
                "deployment_uuid": deployment_uuid,
                "rendered_env": env_evidence(envs),
                "rollback": "previous image+env snapshot" if not snapshot["created"] else "delete created resource",
            }, sort_keys=True) + "\n")
        print(f"Coolify validation resource {expected_name} deployed and read back successfully")
    except Exception:
        try:
            restore(api, snapshot)
            print("Coolify validation mutation rolled back after deployment failure", file=sys.stderr)
        except Exception as rollback_exc:
            print(f"FATAL: Coolify validation rollback also failed: {rollback_exc}", file=sys.stderr)
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["deploy", "rollback", "stop"])
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--role", choices=["build", "uat"], required=True)
    parser.add_argument("--app-name", required=True)
    parser.add_argument("--resource-name", required=True)
    parser.add_argument("--image-ref")
    parser.add_argument("--image-digest")
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--container-port", type=int)
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--evidence-out", type=Path)
    args = parser.parse_args()
    token = os.environ.get("COOLIFY_MOMO_DEPLOY_TOKEN", "")
    if not token or token == "-":
        raise DeployError("COOLIFY_MOMO_DEPLOY_TOKEN is missing; secondary deployment fails closed")
    cfg = load_config(args.config)
    api = Coolify(cfg["api_base_url"], token)
    expected = args.app_name + cfg["slots"][args.role]["suffix"]
    if args.resource_name != expected:
        raise DeployError(f"resource name must be {expected!r}")
    if args.command == "deploy":
        if not args.image_ref or not args.image_digest or not args.env_file or not args.container_port:
            raise DeployError("deploy requires image-ref, image-digest, env-file, and container-port")
        deploy(args, cfg, api)
    elif args.command == "rollback":
        if not args.snapshot.is_file():
            raise DeployError("rollback snapshot is missing")
        restore(api, json.loads(args.snapshot.read_text()))
        print(f"Coolify validation resource {expected} rolled back")
    else:
        app = find_app(api, expected)
        if not app:
            raise DeployError(f"Coolify validation resource {expected!r} does not exist")
        assert_target(app, cfg, expected)
        api.request("POST", f"/applications/{app['uuid']}/stop")
        print(f"Coolify validation resource {expected} stop requested")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except DeployError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
