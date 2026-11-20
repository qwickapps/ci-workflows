#!/usr/bin/env python3
"""Dynamic regression suite: primary (CapRover/OCI-main) vs secondary (Momo
Coolify) deployment lanes (kanban t_5d681050).

Every check EXECUTES real code -- the resolve-stage script extracted from
deploy-app.yml, the job `if:` graph, coolify-validation-deploy.py,
coolify-validation-topology.py and resolve-coolify-validation-credentials.sh --
against in-memory / PATH-stubbed fakes. Nothing reaches the network:
urllib.request.urlopen is replaced with a tripwire and `curl` is a stub.

  1. Legacy primary lane behaviour is unchanged (golden from pre-lane main).
  2. Secondary lane resolves separate, explicit build and UAT slots.
  3. Secondary lane rejects live / stable validation roles.
  4. A caller cannot steer a validation role to OCI-main.
  5. Wrong or stale Coolify token sources are never selected.

Run:  python3 scripts/tests/lane-regression.test.py
Regenerate the legacy golden (only from a pre-lane deploy-app.yml):
      python3 scripts/tests/lane-regression.test.py --regen-golden <legacy-deploy-app.yml>
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import itertools
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/deploy-app.yml"
ACTION = ROOT / ".github/actions/coolify-validation/action.yml"
CONFIG = ROOT / "config/coolify-secondary-validation.json"
RESOLVER = ROOT / "scripts/resolve-coolify-validation-credentials.sh"
GOLDEN = ROOT / "scripts/tests/fixtures/primary-lane-resolve-stage.golden.json"
OCI_MAIN = "captain.app.qwickforge.com"
FIXED_SHA = "0123456789abcdef0123456789abcdef01234567"
# Outputs the lane work added on purpose; everything else must match legacy.
LANE_OUTPUTS = {"deployment_lane", "deployment_backend"}
VOLATILE_OUTPUTS = {"deploy_start_epoch"}
STALE_TOKEN_NAMES = ("COOLIFY_TOKEN", "COOLIFY_API_TOKEN", "COOLIFY_MOMO_API_TOKEN", "COOLIFY_ROOT_TOKEN")


def _no_network(*_a, **_k):
    raise AssertionError("test attempted a real network call")


urllib.request.urlopen = _no_network  # tripwire for every module loaded below


def load_module(name: str, rel: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cvd = load_module("cvd", "scripts/coolify-validation-deploy.py")
topo = load_module("cvt", "scripts/coolify-validation-topology.py")
CFG = cvd.load_config(CONFIG)
DIGEST = "sha256:" + "c" * 64

passed = failed = 0


def check(name, fn):
    global passed, failed
    try:
        fn()
        print(f"  PASS  {name}")
        passed += 1
    except Exception as exc:  # noqa: BLE001
        print(f"  FAIL  {name}: {type(exc).__name__}: {exc}")
        failed += 1


def expect_deploy_error(fn, needle):
    try:
        fn()
    except cvd.DeployError as exc:
        assert needle in str(exc), f"wrong refusal: {exc}"
        return
    raise AssertionError(f"expected DeployError containing {needle!r}")


# ---------------------------------------------------------------- resolve-stage
def extract_resolve_stage(workflow: Path) -> str:
    doc = yaml.safe_load(workflow.read_text())
    for step in doc["jobs"]["resolve-stage"]["steps"]:
        if step.get("name") == "Resolve canonical stage contract":
            script = step["run"]
            break
    else:
        raise AssertionError("resolve-stage contract step not found")
    script = script.replace(".ci-workflows-policy/scripts/stable-host-policy.sh",
                            str(ROOT / "scripts/stable-host-policy.sh"))
    script = re.sub(r"\$\{\{\s*env\.(\w+)\s*\}\}", r"${\1}", script)
    script = re.sub(r"\$\{\{\s*inputs\.(\w+)\s*\}\}", lambda m: "${IN_" + m.group(1).upper() + ":-}", script)
    leftover = re.findall(r"\$\{\{[^}]*\}\}", script)
    assert not leftover, f"unsubstituted expressions: {leftover}"
    return script


DEFAULT_INPUTS = {"container_port": "8080", "dockerfile_only": "true", "health_path": "/health",
                  "run_migrations": "false", "bootstrap_first_stable": "false",
                  "record_first_stable_evidence": "false", "require_live_approval_check": "false"}


def run_resolve(script: str, **inputs) -> tuple[int, dict, str]:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "resolve.sh"
        path.write_text(script)
        out = Path(tmp) / "gh-output"
        out.write_text("")
        env = {"PATH": os.environ["PATH"], "HOME": tmp, "REGISTRY": "ghcr.io", "OWNER": "qwickapps",
               "GITHUB_SHA": FIXED_SHA, "GITHUB_OUTPUT": str(out)}
        for key, value in {**DEFAULT_INPUTS, **inputs}.items():
            env["IN_" + key.upper()] = value
        proc = subprocess.run(["bash", str(path)], env=env, capture_output=True, text=True, timeout=60)
        outputs = {}
        for line in out.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                outputs[k] = v
        errors = "\n".join(l for l in (proc.stdout + proc.stderr).splitlines() if "ERROR" in l or "::error" in l)
        return proc.returncode, outputs, errors


def primary_matrix():
    """Legacy-caller input sets. `lane` is never passed: legacy callers omit it."""
    cases = []
    for stage, app, host, url, mig in itertools.product(
            ["build", "uat", "live", "stable"],
            ["demo", "faabzi-uat", "qwickapps-forge"],
            [OCI_MAIN, "captain.dev.qwickforge.com", "macmini-devserver", "Captain.App.QwickForge.Com"],
            ["", "https://captain.app.qwickforge.com", "https://captain.dev.qwickforge.com"],
            ["false", "true"]):
        case = {"stage": stage, "app_name": app, "caprover_host": host, "caprover_url": url, "run_migrations": mig}
        if stage == "stable":
            case["gateway_stable_url"] = f"http://{app}-stable.taile324e7.ts.net:8080"
        cases.append(case)
    cases.append({"stage": "uat", "app_name": "demo", "caprover_host": OCI_MAIN,
                  "image_ref": "ghcr.io/qwickapps/img-demo:sha-0123456"})
    cases.append({"stage": "", "app_name": "demo", "caprover_host": OCI_MAIN})
    return cases


def normalise(rc, outputs, errors):
    return {"rc": rc, "errors": errors,
            "outputs": {k: v for k, v in outputs.items() if k not in LANE_OUTPUTS | VOLATILE_OUTPUTS}}


def regen_golden(legacy_workflow: Path) -> None:
    script = extract_resolve_stage(legacy_workflow)
    assert "inputs.lane" not in legacy_workflow.read_text(), "golden must come from a pre-lane workflow"
    records = [{"inputs": case, **normalise(*run_resolve(script, **case))} for case in primary_matrix()]
    GOLDEN.parent.mkdir(parents=True, exist_ok=True)
    GOLDEN.write_text(json.dumps({"source": "pre-lane deploy-app.yml resolve-stage", "cases": records}, indent=1) + "\n")
    print(f"wrote {len(records)} golden cases to {GOLDEN}")


CURRENT = extract_resolve_stage(WORKFLOW)


def resolve(**inputs):
    return run_resolve(CURRENT, **inputs)


# --------------------------------------------------------------- job if: graph
def eval_if(expr: str, ctx: dict) -> bool:
    """Evaluate a GitHub `if:` expression for the subset deploy-app.yml uses."""
    py = expr.replace("&&", " and ").replace("||", " or ").replace("always()", "True")
    py = re.sub(r"(?<![=!<>])!(?!=)", " not ", py)
    py = re.sub(r"needs\.([\w-]+)\.(result|outputs\.\w+)",
                lambda m: f"ctx[{(m.group(1) + '.' + m.group(2))!r}]", py)
    assert "needs." not in py and "inputs." not in py, f"unsupported expression: {expr}"
    py = "(" + " ".join(py.split()) + ")"
    return bool(eval(py, {"__builtins__": {}}, {"ctx": ctx}))  # noqa: S307 -- parsed from our own workflow


JOBS = yaml.safe_load(WORKFLOW.read_text())["jobs"]
PRIMARY_JOBS = ("deploy-caprover", "deploy-stable", "scale-build-slot")
SECONDARY_JOBS = ("deploy-coolify-build", "deploy-coolify-uat", "stop-coolify-build-slot")


class Ctx(dict):
    def __missing__(self, key):  # any unspecified job result: worst case 'success'
        return "success" if key.endswith(".result") else ""


def graph_contexts(lane):
    # On secondary, caprover_required is varied too: the lane conjunct alone
    # must keep primary jobs off, independent of the caprover_required output.
    required = ["true"] if lane == "primary" else ["true", "false"]
    for stage, build, caprover, cb, cu, retag, req in itertools.product(
            ["build", "uat", "live", "stable"], ["success", "skipped", "failure"],
            ["success", "skipped", "failure"], ["success", "skipped"], ["success", "skipped"],
            ["success", "skipped"], required):
        yield Ctx({"resolve-stage.outputs.deployment_lane": lane, "resolve-stage.outputs.stage": stage,
                   "resolve-stage.outputs.caprover_required": req,
                   "resolve-stage.outputs.next_tag": "v1", "build.result": build,
                   "deploy-caprover.result": caprover, "deploy-coolify-build.result": cb,
                   "deploy-coolify-uat.result": cu, "retag.result": retag})


# ========================================================== 1. primary unchanged
def t1_primary_resolve_stage_matches_legacy_golden():
    golden = json.loads(GOLDEN.read_text())["cases"]
    assert len(golden) == len(primary_matrix()), "golden is stale relative to the case matrix"
    diffs = []
    for record in golden:
        got = normalise(*resolve(**record["inputs"], lane="primary"))
        want = {k: record[k] for k in ("rc", "errors", "outputs")}
        if got != want:
            diffs.append((record["inputs"], want, got))
    assert not diffs, f"{len(diffs)} primary cases diverge from legacy; first: {diffs[0]}"


def t1_golden_covers_both_outcomes():
    rcs = {r["rc"] for r in json.loads(GOLDEN.read_text())["cases"]}
    assert 0 in rcs and any(rc != 0 for rc in rcs), "golden must contain accepted and refused legacy cases"


def t1_primary_lane_tags_caprover_backend():
    for stage, suffix in (("build", "dev"), ("uat", "uat"), ("live", "live")):
        rc, out, err = resolve(stage=stage, app_name="demo", caprover_host=OCI_MAIN, lane="primary")
        assert rc == 0, err
        assert out["deployment_lane"] == "primary" and out["deployment_backend"] == "caprover-oci-main"
        assert out["target_app"] == f"demo-{suffix}" and out["caprover_required"] == "true"


def t1_lane_input_defaults_to_primary():
    doc = yaml.safe_load(WORKFLOW.read_text())
    lane = (doc.get("on") or doc.get(True))["workflow_call"]["inputs"]["lane"]
    assert lane.get("required") is False and lane.get("default") == "primary", lane


def t1_primary_job_graph_unchanged():
    legacy = Path(os.environ.get("LEGACY_DEPLOY_APP", ""))
    # Without a legacy file, compare against the conjunct the lane work added.
    for name in PRIMARY_JOBS + ("retag",):
        expr = JOBS[name]["if"]
        legacy_expr = expr.replace("needs.resolve-stage.outputs.deployment_lane == 'primary' &&", "")
        legacy_expr = legacy_expr.replace(
            "(needs.deploy-caprover.result == 'success' || needs.deploy-coolify-build.result == 'success' || needs.deploy-coolify-uat.result == 'success')",
            "needs.deploy-caprover.result == 'success'")
        if legacy.is_file():
            legacy_expr = yaml.safe_load(legacy.read_text())["jobs"][name]["if"]
        for ctx in graph_contexts("primary"):
            ctx = Ctx({**ctx, "deploy-coolify-build.result": "skipped", "deploy-coolify-uat.result": "skipped"})
            assert eval_if(expr, ctx) == eval_if(legacy_expr, ctx), (name, dict(ctx))


def t1_secondary_jobs_never_run_on_primary():
    for name in SECONDARY_JOBS:
        assert not any(eval_if(JOBS[name]["if"], c) for c in graph_contexts("primary")), name


# ================================================= 2. explicit build / UAT slots
def t2_resolve_stage_maps_distinct_slots():
    seen = {}
    for stage in ("build", "uat"):
        rc, out, err = resolve(stage=stage, app_name="demo", caprover_host=OCI_MAIN, lane="secondary")
        assert rc == 0, err
        assert out["deployment_backend"] == "coolify-momo" and out["caprover_required"] == "false", out
        seen[stage] = out["target_app"]
    assert seen == {"build": "demo-build", "uat": "demo-uat"}, seen


def t2_each_stage_selects_exactly_its_own_job():
    for ctx in graph_contexts("secondary"):
        stage = ctx["resolve-stage.outputs.stage"]
        b = eval_if(JOBS["deploy-coolify-build"]["if"], ctx)
        u = eval_if(JOBS["deploy-coolify-uat"]["if"], ctx)
        assert not (b and u), dict(ctx)
        if stage not in ("build", "uat"):
            assert not b and not u, dict(ctx)
        if b:
            assert stage == "build"
        if u:
            assert stage == "uat" and ctx["build.result"] == "skipped"


def t2_jobs_pin_role_and_closed_config():
    for name, role in (("deploy-coolify-build", "build"), ("deploy-coolify-uat", "uat")):
        step = [s for s in JOBS[name]["steps"] if s.get("uses", "").endswith("coolify-validation")]
        assert len(step) == 1 and step[0]["with"]["role"] == role, name
    assert ACTION.read_text().count("--config .ci-workflows/config/coolify-secondary-validation.json") == 2


class FakeCoolify:
    """In-memory Coolify v4 API: apps keyed by uuid, every call recorded."""

    def __init__(self, apps=None, place_on=None):
        self.apps = {a["uuid"]: a for a in (apps or [])}
        self.calls = []
        self.place_on = place_on or (CFG["server"]["uuid"], CFG["server"]["destination_uuid"])
        self.n = 0

    def request(self, method, path, payload=None, *, secret_body=False):  # noqa: ARG002
        bare = path.split("?")[0]
        self.calls.append((method, bare, payload))
        if method == "GET" and bare == "/applications":
            return list(self.apps.values())
        if method == "POST" and bare == "/applications/dockerimage":
            self.n += 1
            uuid = f"app{self.n}"
            server, dest = self.place_on
            self.apps[uuid] = {"uuid": uuid, "name": payload["name"], "build_pack": "dockerimage",
                               "destination": {"uuid": dest, "server": {"uuid": server}}, "envs": []}
            return {"uuid": uuid}
        stop = re.fullmatch(r"/applications/(\w+)/stop", bare)
        if method == "POST" and stop and stop.group(1) in self.apps:
            return {"message": "stop queued"}
        m = re.fullmatch(r"/applications/(\w+)(/envs(/bulk)?)?", bare)
        if m and m.group(1) in self.apps:
            app = self.apps[m.group(1)]
            if method == "PATCH" and m.group(3):
                app["envs"] = payload["data"]
                return {}
            if method == "PATCH":
                app.update(payload)
                return {}
            if method == "GET" and m.group(2):
                return app["envs"]
            if method == "GET":
                return app
            if method == "DELETE":
                del self.apps[m.group(1)]
                return {}
        if method == "POST" and bare == "/deploy":
            return {"deployments": [{"deployment_uuid": f"dep-{len(self.calls)}"}]}
        if method == "GET" and bare.startswith("/deployments/"):
            return {"status": "finished"}
        raise AssertionError(f"unexpected Coolify call {method} {path}")

    def mutated_uuids(self):
        return {re.match(r"/applications/(\w+)", p).group(1) for m, p, _ in self.calls
                if m in ("PATCH", "DELETE") and p.startswith("/applications/")}


def deploy_args(tmp, role, resource=None, app="demo"):
    env = Path(tmp) / f"{role}.env"
    env.write_text(f"TS_HOSTNAME={resource or app + '-' + role}\nAPP_SECRET=not-a-real-secret\n")
    return type("Args", (), {
        "role": role, "app_name": app, "resource_name": resource or f"{app}-{role}",
        "image_ref": "ghcr.io/qwickapps/img-demo:sha-0123456", "image_digest": DIGEST,
        "env_file": env, "container_port": 8080,
        "snapshot": Path(tmp) / f"{role}-snap.json", "evidence_out": Path(tmp) / f"{role}-ev.json"})


def quiet(fn, *a):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return fn(*a)


def t2_build_and_uat_deploy_to_separate_resources():
    with tempfile.TemporaryDirectory() as tmp:
        api = FakeCoolify()
        quiet(cvd.deploy, deploy_args(tmp, "build"), CFG, api)
        build_uuid = next(u for u, a in api.apps.items() if a["name"] == "demo-build")
        api.calls.clear()
        quiet(cvd.deploy, deploy_args(tmp, "uat"), CFG, api)
        names = sorted(a["name"] for a in api.apps.values())
        assert names == ["demo-build", "demo-uat"], names
        assert build_uuid not in api.mutated_uuids(), "UAT deploy mutated the build slot"
        assert json.loads((Path(tmp) / "uat-ev.json").read_text())["resource_name"] == "demo-uat"


def t2_role_and_resource_cannot_cross():
    with tempfile.TemporaryDirectory() as tmp:
        api = FakeCoolify()
        expect_deploy_error(lambda: cvd.deploy(deploy_args(tmp, "uat", resource="demo-build"), CFG, api),
                            "closed uat slot 'demo-uat'")
        expect_deploy_error(lambda: cvd.deploy(deploy_args(tmp, "build", resource="demo-uat"), CFG, api),
                            "closed build slot 'demo-build'")
        assert not api.calls, "a crossed slot reached Coolify"


def t2_config_must_define_exactly_build_and_uat():
    with tempfile.TemporaryDirectory() as tmp:
        for slots in ({"build": {"suffix": "-build"}},
                      {**CFG["slots"], "live": {"suffix": "-live"}},
                      {**CFG["slots"], "stable": {"suffix": ""}}):
            bad = Path(tmp) / "cfg.json"
            bad.write_text(json.dumps({**CFG, "slots": slots}))
            expect_deploy_error(lambda: cvd.load_config(bad), "exactly build and uat")


# ======================================================== 3. live/stable refused
def t3_resolve_stage_refuses_live_stable_variants():
    for stage in ("live", "stable", "LIVE", "Stable", "prod", "production"):
        rc, out, err = resolve(stage=stage, app_name="demo", caprover_host=OCI_MAIN, lane="secondary",
                               gateway_stable_url="http://demo-stable.taile324e7.ts.net:8080")
        assert rc != 0, f"secondary stage {stage!r} was accepted: {out}"
        # Exact live/stable must hit the lane gate itself, not a later accident;
        # other spellings are already refused by canonical stage validation.
        needle = ("secondary deployment lane supports only explicit build and uat"
                  if stage in ("live", "stable") else "invalid stage")
        assert needle in err, (stage, err)
        assert "deployment_backend" not in out, f"{stage!r} emitted a backend before refusing"


def t3_deploy_cli_rejects_live_stable_before_any_call():
    for role in ("live", "stable"):
        with tempfile.TemporaryDirectory() as tmp:
            env = {"PATH": os.environ["PATH"], "COOLIFY_MOMO_DEPLOY_TOKEN": "fake-scoped"}
            proc = subprocess.run([sys.executable, str(ROOT / "scripts/coolify-validation-deploy.py"), "stop",
                                   "--config", str(CONFIG), "--role", role, "--app-name", "demo",
                                   "--resource-name", f"demo-{role}", "--snapshot", f"{tmp}/s.json"],
                                  env=env, capture_output=True, text=True, timeout=30)
            assert proc.returncode == 2 and "invalid choice" in proc.stderr, (role, proc.stderr)


def t3_deploy_function_refuses_unknown_roles():
    for role in ("live", "stable"):
        with tempfile.TemporaryDirectory() as tmp:
            api = FakeCoolify()
            expect_deploy_error(lambda: cvd.deploy(deploy_args(tmp, role), CFG, api), "only build or uat")
            assert not api.calls


def t3_no_secondary_job_runs_for_live_or_stable():
    for ctx in graph_contexts("secondary"):
        if ctx["resolve-stage.outputs.stage"] in ("live", "stable"):
            assert not any(eval_if(JOBS[n]["if"], ctx) for n in SECONDARY_JOBS + PRIMARY_JOBS), dict(ctx)


# =========================================================== 4. no OCI-main steer
def t4_caller_host_is_ignored_and_url_override_refused():
    for host in (OCI_MAIN, "oci-main", "Captain.App.QwickForge.Com"):
        rc, out, err = resolve(stage="uat", app_name="demo", caprover_host=host, lane="secondary")
        assert rc == 0 and out["deployment_backend"] == "coolify-momo", (host, err)
        assert out["caprover_required"] == "false"
    for url in ("https://captain.app.qwickforge.com", "https://oci-main", "https://qwickapps-momo:3000"):
        rc, out, err = resolve(stage="build", app_name="demo", caprover_host=OCI_MAIN, caprover_url=url,
                               lane="secondary")
        assert rc != 0 and "caprover_url" in err, (url, err)


def t4_primary_jobs_never_run_on_secondary():
    for ctx in graph_contexts("secondary"):
        for name in PRIMARY_JOBS:
            assert not eval_if(JOBS[name]["if"], ctx), (name, dict(ctx))


def t4_secondary_jobs_take_no_caller_target():
    for name in SECONDARY_JOBS:
        text = json.dumps(JOBS[name])
        for forbidden in ("inputs.caprover_host", "inputs.caprover_url", "CAPROVER_URL", "captain.app"):
            assert forbidden not in text, (name, forbidden)
    action = yaml.safe_load(ACTION.read_text())
    assert not {"config", "api-base-url", "server-uuid", "destination-uuid", "coolify-base-url"} & set(action["inputs"]), \
        "the composite action exposes a target override"
    assert "--coolify-base-url" not in ACTION.read_text()
    default = re.search(r'"--coolify-base-url", default="([^"]+)"',
                        (ROOT / "scripts/coolify-validation-topology.py").read_text())
    assert default and default.group(1).startswith("http://qwickapps-momo."), "topology claimant source is not Momo"


def t4_config_targets_momo_only():
    assert re.match(r"^https?://qwickapps-momo[.:]", CFG["api_base_url"]), CFG["api_base_url"]
    assert "oci-main" not in json.dumps(CFG) and "qwickforge" not in json.dumps(CFG)


def t4_existing_slot_on_oci_main_is_not_touched():
    oci = {"uuid": "ocislot", "name": "demo-uat", "build_pack": "dockerimage",
           "destination": {"uuid": "oci-main-dest", "server": {"uuid": "oci-main-server"}}, "envs": []}
    with tempfile.TemporaryDirectory() as tmp:
        api = FakeCoolify([oci])
        expect_deploy_error(lambda: quiet(cvd.deploy, deploy_args(tmp, "uat"), CFG, api),
                            "exact configured Momo destination")
        assert not api.mutated_uuids() and not any(c[1] == "/deploy" for c in api.calls), api.calls


def t4_resource_created_off_momo_is_deleted_before_deploy():
    with tempfile.TemporaryDirectory() as tmp:
        api = FakeCoolify(place_on=("oci-main-server", "oci-main-dest"))
        expect_deploy_error(lambda: quiet(cvd.deploy, deploy_args(tmp, "build"), CFG, api),
                            "exact configured Momo destination")
        assert not api.apps, "resource created off Momo survived"
        assert not any(c[1] == "/deploy" for c in api.calls)


def t4_stop_refuses_off_momo_slot():
    oci = {"uuid": "ocislot", "name": "demo-build", "build_pack": "dockerimage",
           "destination": {"uuid": "oci-main-dest", "server": {"uuid": "oci-main-server"}}}
    api = FakeCoolify([oci])
    orig = cvd.Coolify
    cvd.Coolify = lambda base, token: api
    os.environ["COOLIFY_MOMO_DEPLOY_TOKEN"] = "fake-scoped"
    sys.argv = ["x", "stop", "--config", str(CONFIG), "--role", "build", "--app-name", "demo",
                "--resource-name", "demo-build", "--snapshot", "/nonexistent"]
    try:
        expect_deploy_error(cvd.main, "exact configured Momo destination")
    finally:
        cvd.Coolify = orig
        os.environ.pop("COOLIFY_MOMO_DEPLOY_TOKEN", None)
    assert not any(c[0] == "POST" and c[1].endswith("/stop") for c in api.calls)


def run_topology(services, devices, apps, hostname="demo-build"):
    tl = topo.tl
    saved = (tl.docker_services_on_host, tl.tailscale_devices, tl.coolify_apps)
    tl.docker_services_on_host = lambda host: [dict(s, host=host) for s in services.get(host, [])]
    tl.tailscale_devices = lambda *a: devices
    tl.coolify_apps = lambda *a: apps
    sys.argv = ["x", "--hostname", hostname, "--resource-name", hostname, "--ts-api-key", "fake",
                "--coolify-token", "fake", "--caprover-hosts", "oci-gateway", "oci-main", "server1-qwickforge"]
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc = topo.main()
    finally:
        tl.docker_services_on_host, tl.tailscale_devices, tl.coolify_apps = saved
    return rc, json.loads(buf.getvalue().strip().splitlines()[-1])


def t4_topology_refuses_hostname_claimed_on_oci_main():
    rc, res = run_topology({"oci-main": [{"name": "srv-captain--demo-build", "ts_hostname": "demo-build", "replicas": 1}]}, [], [])
    assert rc == 2 and res["status_code"] == 409 and "oci-main" in res["reason"], res
    rc, res = run_topology({}, [], [{"name": "demo-build", "ts_hostnames": ["demo-build"]}])
    assert rc == 0 and res["status_code"] == 200 and res["target_host"] == "qwickapps-momo", res


def t4_topology_fails_closed_when_oci_main_unreachable():
    def boom(host):
        raise topo.tl.LiveStateUnreachable(f"{host} ssh refused")
    tl = topo.tl
    saved = tl.docker_services_on_host
    tl.docker_services_on_host = boom
    sys.argv = ["x", "--hostname", "demo-uat", "--resource-name", "demo-uat", "--ts-api-key", "f", "--coolify-token", "f"]
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc = topo.main()
    finally:
        tl.docker_services_on_host = saved
    assert rc == 2 and json.loads(buf.getvalue())["status_code"] == 503


# ============================================================ 5. token sources
CURL_STUB = r"""#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
echo "$url" >> "$CURL_LOG"
path="${url#*/v1/secrets/}"
f="$SECRET_STORE/$(printf '%s' "$path" | tr '/' '_')"
[ -f "$f" ] || exit 22
printf '{"value": "%s"}' "$(cat "$f")"
"""


def run_resolver(env_tokens: dict, store: dict):
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "bin").mkdir()
        curl = tmp / "bin/curl"
        curl.write_text(CURL_STUB)
        curl.chmod(curl.stat().st_mode | stat.S_IEXEC)
        (tmp / "store").mkdir()
        for path, value in store.items():
            (tmp / "store" / path.replace("/", "_")).write_text(value)
        gh_env = tmp / "github_env"
        gh_env.write_text("")
        env = {"PATH": f"{tmp / 'bin'}:{os.environ['PATH']}", "GITHUB_ENV": str(gh_env),
               "CURL_LOG": str(tmp / "curl.log"), "SECRET_STORE": str(tmp / "store"),
               "SECRETS_SERVICE_KEY": "fake-service-key", **env_tokens}
        proc = subprocess.run(["bash", str(RESOLVER)], env=env, capture_output=True, text=True, timeout=30)
        log = (tmp / "curl.log").read_text().split() if (tmp / "curl.log").exists() else []
        values = dict(l.split("=", 1) for l in gh_env.read_text().splitlines() if "=" in l)
        return proc.returncode, values, log, proc.stdout + proc.stderr


STALE_ENV = {name: f"stale-{name.lower()}" for name in STALE_TOKEN_NAMES}
STALE_STORE = {f"infrastructure/{d}/{n}": f"stale-store-{n.lower()}"
               for d in ("caprover", "coolify") for n in STALE_TOKEN_NAMES}
TS_OK = {"TS_API_KEY": "fake-ts"}


def t5_explicit_scoped_secret_wins_over_stale_aliases():
    rc, vals, log, out = run_resolver({**STALE_ENV, **TS_OK, "COOLIFY_MOMO_DEPLOY_TOKEN": "scoped-gh"}, STALE_STORE)
    assert rc == 0, out
    assert vals["COOLIFY_MOMO_DEPLOY_TOKEN"] == "scoped-gh", vals
    assert not log, f"resolver called the secrets service needlessly: {log}"
    assert set(vals) == {"COOLIFY_MOMO_DEPLOY_TOKEN", "TS_API_KEY_RESOLVED"}, vals


def t5_fallback_reads_only_the_scoped_path():
    store = {**STALE_STORE, "infrastructure/caprover/COOLIFY_MOMO_DEPLOY_TOKEN": "scoped-store"}
    for placeholder in ("", "-"):
        rc, vals, log, out = run_resolver({**STALE_ENV, **TS_OK, "COOLIFY_MOMO_DEPLOY_TOKEN": placeholder}, store)
        assert rc == 0, out
        assert vals["COOLIFY_MOMO_DEPLOY_TOKEN"] == "scoped-store", vals
        assert [u.split("/v1/secrets/")[1] for u in log] == ["infrastructure/caprover/COOLIFY_MOMO_DEPLOY_TOKEN"], log


def t5_stale_sources_alone_fail_closed():
    rc, vals, log, out = run_resolver({**STALE_ENV, **TS_OK}, STALE_STORE)
    assert rc != 0 and "COOLIFY_MOMO_DEPLOY_TOKEN could not be resolved" in out, out
    assert not any(v.startswith("stale") for v in vals.values()), vals
    assert all("COOLIFY_MOMO_DEPLOY_TOKEN" in u for u in log if "COOLIFY" in u), log


def t5_placeholder_in_store_fails_closed():
    rc, vals, _, out = run_resolver({**TS_OK}, {"infrastructure/caprover/COOLIFY_MOMO_DEPLOY_TOKEN": "-"})
    assert rc != 0 and "COOLIFY_MOMO_DEPLOY_TOKEN" not in vals, (out, vals)


def t5_deploy_script_uses_only_scoped_env():
    seen = []
    orig = cvd.Coolify

    def capture(base, token):
        seen.append((base, token))
        return FakeCoolify([{"uuid": "b1", "name": "demo-build", "build_pack": "dockerimage",
                             "destination": {"uuid": CFG["server"]["destination_uuid"],
                                             "server": {"uuid": CFG["server"]["uuid"]}}}])
    cvd.Coolify = capture
    saved_env = dict(os.environ)
    try:
        os.environ.update(STALE_ENV)
        os.environ["COOLIFY_MOMO_DEPLOY_TOKEN"] = "scoped-env"
        sys.argv = ["x", "stop", "--config", str(CONFIG), "--role", "build", "--app-name", "demo",
                    "--resource-name", "demo-build", "--snapshot", "/nonexistent"]
        quiet(cvd.main)
        assert seen == [(CFG["api_base_url"], "scoped-env")], seen
        for placeholder in ("", "-"):
            os.environ["COOLIFY_MOMO_DEPLOY_TOKEN"] = placeholder
            expect_deploy_error(cvd.main, "COOLIFY_MOMO_DEPLOY_TOKEN is missing")
        os.environ.pop("COOLIFY_MOMO_DEPLOY_TOKEN")
        expect_deploy_error(cvd.main, "COOLIFY_MOMO_DEPLOY_TOKEN is missing")
        assert len(seen) == 1, "a stale alias produced a Coolify client"
    finally:
        cvd.Coolify = orig
        os.environ.clear()
        os.environ.update(saved_env)


def t5_workflow_maps_only_the_scoped_secret():
    text = WORKFLOW.read_text() + ACTION.read_text()
    names = set(re.findall(r"secrets\.(COOLIFY_\w+)", text))
    assert names == {"COOLIFY_MOMO_DEPLOY_TOKEN"}, names

    def walk(node, path=""):
        if isinstance(node, dict):
            for k, v in node.items():
                if k == "env" and isinstance(v, dict):
                    for ek, ev in v.items():
                        if "COOLIFY" in ek or "COOLIFY" in str(ev):
                            assert ek == "COOLIFY_MOMO_DEPLOY_TOKEN", f"{path}: env {ek}={ev}"
                            assert ev in ("${{ secrets.COOLIFY_MOMO_DEPLOY_TOKEN }}",
                                          "${{ env.COOLIFY_MOMO_DEPLOY_TOKEN }}"), f"{path}: {ev}"
                walk(v, f"{path}/{k}")
        elif isinstance(node, list):
            for i, v in enumerate(node):
                walk(v, f"{path}[{i}]")
    walk(yaml.safe_load(WORKFLOW.read_text()))
    walk(yaml.safe_load(ACTION.read_text()))


def t5_cleanup_inherits_resolved_token_from_github_env():
    steps = JOBS["stop-coolify-build-slot"]["steps"]
    resolver = next(s for s in steps if s.get("name") == "Resolve scoped Momo validation credentials")
    cleanup = next(s for s in steps if s.get("name") == "Stop build validation resource")
    assert "resolve-coolify-validation-credentials.sh" in resolver["run"]
    assert "COOLIFY_MOMO_DEPLOY_TOKEN" not in cleanup.get("env", {}), cleanup.get("env")

    rc, values, _, output = run_resolver({**TS_OK, "COOLIFY_MOMO_DEPLOY_TOKEN": "cleanup-scoped"}, {})
    assert rc == 0, output
    inherited = {**os.environ, **values}
    proc = subprocess.run(
        ["bash", "-c", 'test "$COOLIFY_MOMO_DEPLOY_TOKEN" = cleanup-scoped'],
        env=inherited,
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr


def t5_exclusivity_validator_rejects_stale_names():
    validator = ROOT / "scripts/validate-coolify-token-exclusivity.py"
    with tempfile.TemporaryDirectory() as tmp:
        for name in STALE_TOKEN_NAMES:
            f = Path(tmp) / "asset.sh"
            f.write_text(f'TOKEN="${{{name}:-}}"\n')
            proc = subprocess.run([sys.executable, str(validator), str(f)], capture_output=True, text=True)
            assert proc.returncode == 1 and name in proc.stderr, (name, proc.stderr)
        ok = Path(tmp) / "ok.sh"
        ok.write_text('TOKEN="${COOLIFY_MOMO_DEPLOY_TOKEN:-}"\n')
        assert subprocess.run([sys.executable, str(validator), str(ok)], capture_output=True).returncode == 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--regen-golden":
        regen_golden(Path(sys.argv[2]))
        raise SystemExit(0)
    tests = [(n, f) for n, f in list(globals().items()) if re.match(r"t\d_", n) and callable(f)]
    for section in "12345":
        print(f"== {section}")
        for name, fn in tests:
            if name.startswith(f"t{section}_"):
                check(name, fn)
    print(f"{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
