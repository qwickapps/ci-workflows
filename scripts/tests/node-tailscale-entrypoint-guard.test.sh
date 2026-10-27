#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GUARD="$ROOT/scripts/node-tailscale-entrypoint-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
failures=0

assert_pass() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else echo "FAIL: $label" >&2; failures=$((failures + 1)); fi
}
assert_fail() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "FAIL: $label (unexpected pass)" >&2; failures=$((failures + 1)); else pass=$((pass + 1)); fi
}
fixture() {
  local d="$1"
  mkdir -p "$d/.github/workflows"
  git -C "$d" init -q
  git -C "$d" config user.email test@example.invalid
  git -C "$d" config user.name test
  cat > "$d/Dockerfile" <<'EOF'
COPY entrypoint.sh /usr/local/bin/qwick-ts-entrypoint
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/qwick-ts-entrypoint"]
EOF
  cat > "$d/entrypoint.sh" <<'EOF'
TS_EPHEMERAL_AUTHKEY is forbidden
TS_STATE_MODE=mem is forbidden
--statedir="/var/lib/tailscale/${SERVICE}"
EOF
  git -C "$d" add . && git -C "$d" commit -qm fixture
}

fixture "$TMP/good"
assert_pass "canonical node source passes" bash -c "cd '$TMP/good' && GITHUB_REPOSITORY=qwickapps/node '$GUARD' --source"
printf 'COPY backup-entrypoint.sh /tmp/entrypoint\n' >> "$TMP/good/Dockerfile"
assert_fail "alternate Dockerfile copy fails" bash -c "cd '$TMP/good' && GITHUB_REPOSITORY=qwickapps/node '$GUARD' --source"

fixture "$TMP/mem"
printf 'TS_STATE_MODE=mem\n' > "$TMP/mem/.github/workflows/deploy.yml"
git -C "$TMP/mem" add . && git -C "$TMP/mem" commit -qm mem
assert_fail "memory state in production workflow fails" bash -c "cd '$TMP/mem' && GITHUB_REPOSITORY=qwickapps/node '$GUARD' --source"

fixture "$TMP/entrypoint-mem"
printf '\nSTATE_MODE="${TS_STATE_MODE:-mem}"\n' >> "$TMP/entrypoint-mem/entrypoint.sh"
git -C "$TMP/entrypoint-mem" add . && git -C "$TMP/entrypoint-mem" commit -qm entrypoint-mem
assert_fail "memory state default in canonical entrypoint fails" bash -c "cd '$TMP/entrypoint-mem' && GITHUB_REPOSITORY=qwickapps/node '$GUARD' --source"

fixture "$TMP/entrypoint-ephemeral-assignment"
printf '\nexport TS_EPHEMERAL_AUTHKEY=[redacted: assigned secret]' >> "$TMP/entrypoint-ephemeral-assignment/entrypoint.sh"
git -C "$TMP/entrypoint-ephemeral-assignment" add . && git -C "$TMP/entrypoint-ephemeral-assignment" commit -qm entrypoint-ephemeral-assignment
assert_fail "ephemeral key assignment in canonical entrypoint fails" bash -c "cd '$TMP/entrypoint-ephemeral-assignment' && GITHUB_REPOSITORY=qwickapps/node '$GUARD' --source"

fixture "$TMP/entrypoint-ephemeral-readonly"
printf '\nreadonly TS_EPHEMERAL_AUTHKEY=[redacted: assigned secret]\n' >> "$TMP/entrypoint-ephemeral-readonly/entrypoint.sh"
git -C "$TMP/entrypoint-ephemeral-readonly" add . && git -C "$TMP/entrypoint-ephemeral-readonly" commit -qm entrypoint-ephemeral-readonly
assert_fail "readonly ephemeral key declaration in canonical entrypoint fails" bash -c "cd '$TMP/entrypoint-ephemeral-readonly' && GITHUB_REPOSITORY=qwickapps/node '$GUARD' --source"

fixture "$TMP/entrypoint-ephemeral-declare"
printf '\ndeclare TS_EPHEMERAL_AUTHKEY=[redacted: assigned secret]\n' >> "$TMP/entrypoint-ephemeral-declare/entrypoint.sh"
git -C "$TMP/entrypoint-ephemeral-declare" add . && git -C "$TMP/entrypoint-ephemeral-declare" commit -qm entrypoint-ephemeral-declare
assert_fail "declare ephemeral key declaration in canonical entrypoint fails" bash -c "cd '$TMP/entrypoint-ephemeral-declare' && GITHUB_REPOSITORY=qwickapps/node '$GUARD' --source"

fixture "$TMP/entrypoint-ephemeral-local"
printf '\nf(){ local TS_EPHEMERAL_AUTHKEY=[redacted: assigned secret] }\n' >> "$TMP/entrypoint-ephemeral-local/entrypoint.sh"
git -C "$TMP/entrypoint-ephemeral-local" add . && git -C "$TMP/entrypoint-ephemeral-local" commit -qm entrypoint-ephemeral-local
assert_fail "local ephemeral key declaration in canonical entrypoint fails" bash -c "cd '$TMP/entrypoint-ephemeral-local' && GITHUB_REPOSITORY=qwickapps/node '$GUARD' --source"

fixture "$TMP/entrypoint-mem-assignment"
printf '\nTS_STATE_MODE=mem\n' >> "$TMP/entrypoint-mem-assignment/entrypoint.sh"
git -C "$TMP/entrypoint-mem-assignment" add . && git -C "$TMP/entrypoint-mem-assignment" commit -qm entrypoint-mem-assignment
assert_fail "memory state assignment in canonical entrypoint fails" bash -c "cd '$TMP/entrypoint-mem-assignment' && GITHUB_REPOSITORY=qwickapps/node '$GUARD' --source"

fixture "$TMP/entrypoint-mem-readonly"
printf '\nreadonly TS_STATE_MODE=mem\n' >> "$TMP/entrypoint-mem-readonly/entrypoint.sh"
git -C "$TMP/entrypoint-mem-readonly" add . && git -C "$TMP/entrypoint-mem-readonly" commit -qm entrypoint-mem-readonly
assert_fail "readonly memory state declaration in canonical entrypoint fails" bash -c "cd '$TMP/entrypoint-mem-readonly' && GITHUB_REPOSITORY=qwickapps/node '$GUARD' --source"

fixture "$TMP/entrypoint-mem-declare"
printf '\ndeclare TS_STATE_MODE=mem\n' >> "$TMP/entrypoint-mem-declare/entrypoint.sh"
git -C "$TMP/entrypoint-mem-declare" add . && git -C "$TMP/entrypoint-mem-declare" commit -qm entrypoint-mem-declare
assert_fail "declare memory state declaration in canonical entrypoint fails" bash -c "cd '$TMP/entrypoint-mem-declare' && GITHUB_REPOSITORY=qwickapps/node '$GUARD' --source"

# --- --production-env: the guard inspects exactly the file it is given ------
ENVD="$TMP/env"
mkdir -p "$ENVD"
prod() { # prod <stage> <image> <file...>
  local stage="$1" image="$2"; shift 2
  APP_NAME=node DEPLOY_STAGE="$stage" IMAGE_REF="$image" "$GUARD" --production-env "$@"
}
REL=ghcr.io/qwickapps/img-node:release
printf 'PORT=8080\nTS_STATE_MODE=disk\n' > "$ENVD/clean.env"
printf 'PORT=8080\nTS_EPHEMERAL_AUTHKEY=placeholder-not-a-key\n' > "$ENVD/ephemeral.env"
printf 'export TS_EPHEMERAL_AUTHKEY="placeholder-not-a-key"\n' > "$ENVD/ephemeral-export.env"
printf 'TS_EPHEMERAL_AUTHKEY=\n' > "$ENVD/ephemeral-empty.env"
printf '  TS_STATE_MODE = "mem"\r\n' > "$ENVD/mem-quoted.env"
printf '# TS_EPHEMERAL_AUTHKEY=placeholder\nTS_STATE_MODE=memory-is-not-mem\n' > "$ENVD/commented.env"
: > "$ENVD/empty.env"

assert_pass "clean rendered env passes" prod live "$REL" "$ENVD/clean.env"
assert_pass "commented-out key passes" prod live "$REL" "$ENVD/commented.env"
assert_fail "rendered TS_EPHEMERAL_AUTHKEY fails" prod live "$REL" "$ENVD/ephemeral.env"
assert_fail "exported quoted TS_EPHEMERAL_AUTHKEY fails" prod stable ghcr.io/qwickapps/img-node:stable "$ENVD/ephemeral-export.env"
assert_fail "empty TS_EPHEMERAL_AUTHKEY assignment fails" prod live "$REL" "$ENVD/ephemeral-empty.env"
assert_fail "quoted CRLF TS_STATE_MODE=mem fails" prod live "$REL" "$ENVD/mem-quoted.env"
assert_fail "missing env path argument fails closed" prod live "$REL"
assert_fail "nonexistent env file fails closed" prod live "$REL" "$ENVD/absent.env"
assert_fail "empty env file fails closed" prod live "$REL" "$ENVD/empty.env"
assert_fail "unapproved production image fails" prod live ghcr.io/qwickapps/node:latest "$ENVD/clean.env"
assert_pass "non-production stage skips" prod uat ghcr.io/qwickapps/node:latest "$ENVD/ephemeral.env"
assert_pass "non-node app is not applicable" env APP_NAME=other DEPLOY_STAGE=live IMAGE_REF=x "$GUARD" --production-env "$ENVD/ephemeral.env"
out="$(prod live "$REL" "$ENVD/ephemeral.env" 2>&1 || true)"
if [[ "$out" == *placeholder-not-a-key* ]]; then echo "FAIL: guard echoed a rendered secret value" >&2; failures=$((failures + 1)); else pass=$((pass + 1)); fi

# --- Regression (t_07fc2558): drive deploy-app.yml's OWN render + guard steps.
# The rejected head checked a cwd-relative .deploy-app-env directory while the
# renderer writes ${RUNNER_TEMP}/app-env-<env>-<app>.env, so an ephemeral key
# in the real rendered file passed. For every job that renders an env file
# this extracts the real step scripts, renders into a simulated RUNNER_TEMP
# from an unrelated cwd, and runs the job's guard step exactly as wired.
WF="$ROOT/.github/workflows/deploy-app.yml"
SIM="$TMP/sim"
mkdir -p "$SIM"
python3 - "$WF" "$SIM" <<'PY'
import os, re, sys, yaml
wf, out = sys.argv[1], sys.argv[2]
jobs = yaml.safe_load(open(wf))["jobs"]
found = []
for name, job in jobs.items():
    steps = job.get("steps", [])
    idx = [i for i, s in enumerate(steps) if s.get("id") == "env-file"]
    if not idx:
        continue
    r = idx[0]
    guards = [i for i, s in enumerate(steps) if "node-tailscale-entrypoint-guard.sh --production-env" in (s.get("run") or "")]
    consumers = [i for i, s in enumerate(steps) if i != r and "steps.env-file.outputs.path" in (s.get("run") or "") + str(s.get("env") or "")
                 and i not in guards]
    if not guards:
        sys.exit(f"job {name}: renders an env file but has no --production-env guard step")
    g = guards[0]
    if not (r < g and all(g < c for c in consumers)):
        sys.exit(f"job {name}: guard step must run after the render and before every consumer of its output")
    genv = steps[g].get("env") or {}
    if genv.get("RENDERED_ENV_FILE") != "${{ steps.env-file.outputs.path }}":
        sys.exit(f"job {name}: guard RENDERED_ENV_FILE must be the renderer's output path")
    cond = steps[g].get("if", "")
    for need in ("qwickapps/node", "app_name == 'node'", "'live'", "'stable'"):
        if need not in cond:
            sys.exit(f"job {name}: guard if: is missing {need}")
    subst = {"inputs.environment": "live", "inputs.app_name": "node",
             "inputs.env_render_script": os.path.join(out, "render.sh")}
    def expand(text):
        def rep(m):
            k = m.group(1).strip()
            if k not in subst:
                sys.exit(f"job {name}: unexpected expression {k} in render step")
            return subst[k]
        return re.sub(r"\$\{\{\s*([^}]+?)\s*\}\}", rep, text)
    os.makedirs(os.path.join(out, name))
    open(os.path.join(out, name, "render.sh"), "w").write(expand(steps[r]["run"]))
    open(os.path.join(out, name, "guard.sh"), "w").write(steps[g]["run"])
    found.append(name)
for req in ("validate-env", "deploy-caprover", "deploy-stable"):
    if req not in found:
        sys.exit(f"expected job {req} to render and guard an env file")
open(os.path.join(out, "jobs"), "w").write("\n".join(found) + "\n")
PY
pass=$((pass + 1))

cat > "$SIM/render.sh" <<'EOF'
#!/usr/bin/env bash
# Fixture renderer: writes whatever RENDER_FIXTURE holds to the requested path.
cp "$RENDER_FIXTURE" "$3"
EOF
chmod +x "$SIM/render.sh"
mkdir -p "$SIM/checkout/.ci-workflows/scripts"
cp "$GUARD" "$SIM/checkout/.ci-workflows/scripts/"
chmod +x "$SIM/checkout/.ci-workflows/scripts/node-tailscale-entrypoint-guard.sh"

run_job() { # run_job <job> <fixture> -> exit status of the job's guard step
  local job="$1" fixture="$2" rt="$SIM/runner-temp-$1" gho path
  rm -rf "$rt"; mkdir -p "$rt"; gho="$rt/github-output"; : > "$gho"
  # Setup failures abort the suite so they can never satisfy an assert_fail.
  ( cd "$SIM/checkout" && RUNNER_TEMP="$rt" GITHUB_OUTPUT="$gho" RENDER_FIXTURE="$fixture" bash -e "$SIM/$job/render.sh" ) \
    || { echo "SETUP FAIL: $job render step" >&2; exit 2; }
  path="$(sed -n 's/^path=//p' "$gho")"
  [[ "$path" == "$rt/app-env-live-node.env" && -s "$path" ]] || { echo "SETUP FAIL: $job render path '$path'" >&2; exit 2; }
  [[ ! -e "$SIM/checkout/.deploy-app-env" ]] || { echo "SETUP FAIL: unexpected .deploy-app-env" >&2; exit 2; }
  ( cd "$SIM/checkout" && APP_NAME=node DEPLOY_STAGE=live IMAGE_REF="$REL" RENDERED_ENV_FILE="$path" bash -e "$SIM/$job/guard.sh" )
}
while IFS= read -r job; do
  [[ -n "$job" ]] || continue
  assert_fail "$job: ephemeral key in real RUNNER_TEMP render blocks deploy" run_job "$job" "$ENVD/ephemeral.env"
  assert_fail "$job: TS_STATE_MODE=mem in real RUNNER_TEMP render blocks deploy" run_job "$job" "$ENVD/mem-quoted.env"
  assert_pass "$job: clean real RUNNER_TEMP render passes" run_job "$job" "$ENVD/clean.env"
done < "$SIM/jobs"

[[ "$failures" -eq 0 ]] || exit 1
echo "PASS: $pass node persistent-entrypoint guard assertions"
