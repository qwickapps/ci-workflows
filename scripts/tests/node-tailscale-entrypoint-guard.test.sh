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

mkdir -p "$TMP/env/.deploy-app-env"
printf 'TS_EPHEMERAL_AUTHKEY=tskey-client-ignored\n' > "$TMP/env/.deploy-app-env/live.env"
assert_fail "production ephemeral env fails" bash -c "cd '$TMP/env' && APP_NAME=node DEPLOY_STAGE=live IMAGE_REF=ghcr.io/qwickapps/img-node:release '$GUARD' --production-env"
assert_fail "unapproved production image fails" bash -c "cd '$TMP/env' && APP_NAME=node DEPLOY_STAGE=live IMAGE_REF=ghcr.io/qwickapps/node:latest '$GUARD' --production-env"
rm -f "$TMP/env/.deploy-app-env/live.env"
assert_pass "approved clean production input passes" bash -c "cd '$TMP/env' && APP_NAME=node DEPLOY_STAGE=stable IMAGE_REF=ghcr.io/qwickapps/img-node:stable '$GUARD' --production-env"

[[ "$failures" -eq 0 ]] || exit 1
echo "PASS: $pass node persistent-entrypoint guard assertions"
