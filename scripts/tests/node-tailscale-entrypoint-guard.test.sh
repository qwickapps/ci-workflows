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

mkdir -p "$TMP/env"
printf 'TS_EPHEMERAL_AUTHKEY=[redacted: tailscale key]\n' > "$TMP/env/rendered-live.env"
assert_fail "rendered production ephemeral env fails" bash -c "cd '$TMP/env' && APP_NAME=node DEPLOY_STAGE=live IMAGE_REF=ghcr.io/qwickapps/img-node:release '$GUARD' --production-env '$TMP/env/rendered-live.env'"
printf 'TS_STATE_MODE=mem\n' > "$TMP/env/rendered-live.env"
assert_fail "rendered production memory state fails" bash -c "cd '$TMP/env' && APP_NAME=node DEPLOY_STAGE=live IMAGE_REF=ghcr.io/qwickapps/img-node:release '$GUARD' --production-env '$TMP/env/rendered-live.env'"
assert_fail "missing rendered production env fails" bash -c "cd '$TMP/env' && APP_NAME=node DEPLOY_STAGE=live IMAGE_REF=ghcr.io/qwickapps/img-node:release '$GUARD' --production-env"
assert_fail "unapproved production image fails" bash -c "cd '$TMP/env' && APP_NAME=node DEPLOY_STAGE=live IMAGE_REF=ghcr.io/qwickapps/node:latest '$GUARD' --production-env '$TMP/env/rendered-live.env'"
printf 'TS_STATE_MODE=stateful\n' > "$TMP/env/rendered-live.env"
assert_pass "approved clean rendered production input passes" bash -c "cd '$TMP/env' && APP_NAME=node DEPLOY_STAGE=stable IMAGE_REF=ghcr.io/qwickapps/img-node:stable '$GUARD' --production-env '$TMP/env/rendered-live.env'"

assert_pass "workflow passes rendered env output to production guard" bash -c "grep -q 'ENV_FILE: \${{ steps.env-file.outputs.path }}' '$ROOT/.github/workflows/deploy-app.yml' && grep -q 'node-tailscale-entrypoint-guard.sh --production-env \"\$ENV_FILE\"' '$ROOT/.github/workflows/deploy-app.yml'"

[[ "$failures" -eq 0 ]] || exit 1
echo "PASS: $pass node persistent-entrypoint guard assertions"
