#!/usr/bin/env python3
"""Regression tests for scripts/coolify-validation-evidence.py (no network)."""
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.path.join(ROOT, "scripts", "coolify-validation-evidence.py")
ALL_OK = {"O_PREFLIGHT": "success", "O_DEPLOY": "success", "O_HEALTH": "success",
          "O_DEEP_HEALTH": "success", "O_POSTCHECK": "success", "O_SMOKE_PATH": "skipped",
          "O_SMOKE_COMMAND": "success", "O_E2E_SUITE": "", "O_MIGRATIONS": "skipped",
          "O_E2E_COMMAND": "", "O_ROLLBACK": "skipped"}


def run(outcomes, deploy_record=True):
    d = tempfile.mkdtemp()
    dep = os.path.join(d, "e.json")
    if deploy_record:
        json.dump({"slot": "demo-build", "image_digest": "sha256:" + "a" * 64}, open(dep, "w"))
    out = os.path.join(d, "final.json")
    env = {k: v for k, v in os.environ.items() if not k.startswith("O_")}
    env.update(outcomes)
    rc = subprocess.run([sys.executable, SCRIPT, "--deploy-evidence", dep, "--out", out],
                        env=env, capture_output=True, text=True).returncode
    return rc, json.load(open(out))


def t_all_green_is_validated():
    rc, r = run(ALL_OK)
    assert rc == 0 and r["verdict"] == "validated" and r["reasons"] == [], r
    assert r["deploy"]["slot"] == "demo-build"


def t_failed_smoke_is_not_validated():
    rc, r = run(dict(ALL_OK, O_SMOKE_COMMAND="failure", O_ROLLBACK="success"))
    assert r["verdict"] == "not-validated", r
    assert "gate smoke_command: failure" in r["reasons"] and "rollback ran: success" in r["reasons"], r


def t_skipped_required_gate_is_not_validated():
    rc, r = run(dict(ALL_OK, O_POSTCHECK="skipped"))
    assert r["verdict"] == "not-validated" and "required gate postcheck: skipped" in r["reasons"], r


def t_missing_deploy_record_fails():
    rc, r = run(ALL_OK, deploy_record=False)
    assert rc == 1 and r["verdict"] == "not-validated" and r["deploy"] is None, (rc, r)


def t_no_secret_values_in_record():
    rc, r = run(dict(ALL_OK, COOLIFY_MOMO_DEPLOY_TOKEN="tok-should-not-appear"))
    assert "tok-should-not-appear" not in json.dumps(r)


if __name__ == "__main__":
    passed = failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("t_") and callable(fn):
            try:
                fn(); passed += 1; print("  PASS ", name)
            except Exception as exc:  # noqa: BLE001
                failed += 1; print("  FAIL ", name, exc)
    print("%d passed, %d failed" % (passed, failed))
    sys.exit(1 if failed else 0)
