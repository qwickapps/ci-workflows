#!/usr/bin/env python3
"""Offline regression for the Momo Coolify secondary-lane safety helpers.

No network: every Coolify call goes to an in-memory fake. Run directly:
  python3 scripts/tests/coolify-validation-safety.test.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("cvd", ROOT / "scripts" / "coolify-validation-deploy.py")
cvd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cvd)

DIGEST = "sha256:" + "a" * 64
OTHER = "sha256:" + "b" * 64
CFG = cvd.load_config(ROOT / "config" / "coolify-secondary-validation.json")
passed = failed = 0


def check(name, fn):
    global passed, failed
    try:
        fn()
        print(f"  PASS  {name}")
        passed += 1
    except Exception as exc:  # noqa: BLE001
        print(f"  FAIL  {name}: {exc}")
        failed += 1


def raises(fn, needle):
    try:
        fn()
    except cvd.DeployError as exc:
        assert needle in str(exc), f"wrong error: {exc}"
        return
    raise AssertionError("expected DeployError")


def t_pin_tag():
    assert cvd.pinned_image("ghcr.io/qwickapps/img-x:release-candidate", DIGEST) == ("ghcr.io/qwickapps/img-x@sha256", "a" * 64)


def t_pin_registry_port():
    assert cvd.pinned_image("reg.local:5000/img-x:sha-abc", DIGEST) == ("reg.local:5000/img-x@sha256", "a" * 64)


def t_pin_matching_digest_ref():
    assert cvd.pinned_image(f"ghcr.io/qwickapps/img-x@{DIGEST}", DIGEST)[1] == "a" * 64


def t_pin_mismatch():
    raises(lambda: cvd.pinned_image(f"ghcr.io/qwickapps/img-x@{OTHER}", DIGEST), "differs from the verified provenance")


def t_pin_missing_digest():
    raises(lambda: cvd.pinned_image("ghcr.io/qwickapps/img-x:tag", ""), "verified sha256 image digest")


class FakeApi:
    def __init__(self, apps, dest_uuid=None):
        self.apps = apps
        self.calls = []
        self.dest_uuid = dest_uuid or CFG["server"]["destination_uuid"]
        self.store = {}

    def request(self, method, path, payload=None, *, secret_body=False):
        self.calls.append((method, path.split("?")[0]))
        if method == "GET" and path == "/applications":
            return self.apps
        if method == "POST" and path == "/applications/dockerimage":
            self.store = {"uuid": "new1", "destination": {"uuid": self.dest_uuid, "server": {"uuid": CFG["server"]["uuid"]}}, "build_pack": "dockerimage"}
            return {"uuid": "new1"}
        if method == "PATCH" and path.endswith("/envs/bulk"):
            self.store["envs"] = payload["data"]
            return {}
        if method == "PATCH":
            self.store.update(payload)
            return {}
        if method == "POST" and path.startswith("/deploy"):
            return {"deployments": [{"deployment_uuid": "d1"}]}
        if method == "GET" and path.startswith("/deployments/"):
            return {"status": "finished"}
        if method == "GET" and path.endswith("/envs"):
            return self.store.get("envs", [])
        if method == "GET" and path.startswith("/applications/"):
            return self.store
        if method == "DELETE":
            return {}
        raise AssertionError(f"unexpected {method} {path}")


def run_deploy(api, tmp, name="demo-build"):
    env = Path(tmp) / "app.env"
    env.write_text(f"TS_HOSTNAME={name}\nSECRET=s3cret\n")

    class A:  # minimal argparse stand-in
        role = "build"
        app_name = "demo"
        resource_name = name
        image_ref = "ghcr.io/qwickapps/img-demo:sha-abc"
        image_digest = DIGEST
        env_file = env
        container_port = 8080
        snapshot = Path(tmp) / "snap.json"
        evidence_out = Path(tmp) / "evidence.json"
    cvd.deploy(A, CFG, api)
    return A


def t_deploy_creates_pinned_with_evidence():
    with tempfile.TemporaryDirectory() as tmp:
        api = FakeApi([])
        a = run_deploy(api, tmp)
        assert api.store["docker_registry_image_name"] == "ghcr.io/qwickapps/img-demo@sha256"
        assert api.store["docker_registry_image_tag"] == "a" * 64
        ev = json.loads(a.evidence_out.read_text())
        assert ev["image_digest"] == DIGEST and ev["deployment_uuid"] == "d1" and ev["lane"] == "secondary"
        assert "s3cret" not in a.evidence_out.read_text(), "evidence leaked an env value"
        assert ev["rendered_env"]["keys"] == ["SECRET", "TS_HOSTNAME"]


def t_created_on_wrong_destination_is_deleted():
    with tempfile.TemporaryDirectory() as tmp:
        api = FakeApi([], dest_uuid="oci-main-destination")
        try:
            run_deploy(api, tmp)
        except cvd.DeployError as exc:
            assert "exact configured Momo destination" in str(exc)
        else:
            raise AssertionError("wrong destination accepted")
        assert ("DELETE", "/applications/new1") in api.calls, "created resource was not rolled back"
        assert not any(c[0] == "POST" and c[1].startswith("/deploy") for c in api.calls), "deployed to wrong destination"


def t_existing_on_other_server_refused():
    with tempfile.TemporaryDirectory() as tmp:
        foreign = {"uuid": "x", "name": "demo-build", "build_pack": "dockerimage", "destination": {"uuid": "other", "server": {"uuid": "nsheaqysn30sioqgk6bctgsk"}}}
        api = FakeApi([foreign])
        raises(lambda: run_deploy(api, tmp), "exact configured Momo destination")
        assert not any(c[0] in {"PATCH", "DELETE"} for c in api.calls), "mutated a foreign resource"


def t_slot_name_closed():
    with tempfile.TemporaryDirectory() as tmp:
        raises(lambda: run_deploy(FakeApi([]), tmp, name="demo-live"), "closed build slot")


def t_token_source_only_scoped():
    os.environ.pop("COOLIFY_MOMO_DEPLOY_TOKEN", None)
    os.environ["COOLIFY_API_TOKEN"] = "stale"
    sys.argv = ["x", "stop", "--config", str(ROOT / "config/coolify-secondary-validation.json"), "--role", "build",
                "--app-name", "demo", "--resource-name", "demo-build", "--snapshot", "/nonexistent"]
    raises(cvd.main, "COOLIFY_MOMO_DEPLOY_TOKEN is missing")


for name, fn in list(globals().items()):
    if name.startswith("t_") and callable(fn):
        check(name, fn)
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
