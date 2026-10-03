#!/usr/bin/env bash
# Enforce qwickapps/node's one supported persistent Tailscale entrypoint.
# This guard is deliberately scoped: shared workflows must not reject the
# ephemeral gateway contract used by unrelated QwickWay deployments.
set -euo pipefail

mode="${1:---source}"
repo="${GITHUB_REPOSITORY:-}"
app_name="${APP_NAME:-}"
stage="${DEPLOY_STAGE:-}"
image_ref="${IMAGE_REF:-}"

applicable=false
if [[ "$repo" == "qwickapps/node" || "$app_name" == "node" ]]; then
  applicable=true
fi
if [[ "$applicable" != true ]]; then
  echo "node persistent-entrypoint guard: not applicable"
  exit 0
fi

fail() { echo "::error::node persistent-entrypoint guard: $*" >&2; exit 1; }

case "$mode" in
  --source)
    [[ -f Dockerfile ]] || fail "Dockerfile is required"
    [[ -f entrypoint.sh ]] || fail "canonical entrypoint.sh is required"

    # Only the canonical root source may be copied into the production image;
    # alternative entrypoint files make a reviewable fix easy to bypass.
    grep -qE '^COPY[[:space:]]+entrypoint\.sh[[:space:]]+/usr/local/bin/qwick-ts-entrypoint$' Dockerfile \
      || fail "Dockerfile must COPY canonical entrypoint.sh to /usr/local/bin/qwick-ts-entrypoint"
    grep -qE '^ENTRYPOINT \["/sbin/tini", "--", "/usr/local/bin/qwick-ts-entrypoint"\]$' Dockerfile \
      || fail "Dockerfile must use tini and /usr/local/bin/qwick-ts-entrypoint"
    if grep -nE '^[[:space:]]*(COPY|ADD)[[:space:]].*(entrypoint|tailscale).*[[:space:]]' Dockerfile \
      | grep -vE '^[0-9]+:COPY[[:space:]]+entrypoint\.sh[[:space:]]+/usr/local/bin/qwick-ts-entrypoint$' >/dev/null; then
      fail "Dockerfile contains a frozen or alternate Tailscale entrypoint copy"
    fi
    extra=$(git ls-files 2>/dev/null | grep -E '(^|/)(entrypoint|qwick-ts-entrypoint)[^/]*\.(sh|bash)$' | grep -vE '^(entrypoint\.sh|tests/)' || true)
    [[ -z "$extra" ]] || fail "alternate entrypoint source is forbidden: ${extra//$'\n'/, }"

    # The canonical source must itself make the persistent contract explicit.
    grep -q 'TS_EPHEMERAL_AUTHKEY is forbidden' entrypoint.sh || fail "canonical entrypoint must reject TS_EPHEMERAL_AUTHKEY"
    grep -q 'TS_STATE_MODE=mem is forbidden' entrypoint.sh || fail "canonical entrypoint must reject mem state"
    grep -q -- '--statedir="/var/lib/tailscale/${SERVICE}"' entrypoint.sh || fail "tailscaled must use disk-backed /var/lib/tailscale state"
    if grep -nF '${TS_STATE_MODE:-mem}' entrypoint.sh >/dev/null; then
      fail "canonical entrypoint must not default Tailscale state to memory"
    fi
    if git grep -nE '(TS_EPHEMERAL_AUTHKEY[[:space:]]*=|TS_STATE_MODE[[:space:]]*=[[:space:]]*mem|--statedir[[:space:]]*=[^[:space:]]*(/tmp|mem))' -- \
      Dockerfile ':!tests/**' ':!entrypoint.sh' '.github/workflows' 2>/dev/null | grep -v '/tests/' >/dev/null; then
      fail "production source config enables ephemeral auth or memory-backed Tailscale state"
    fi
    echo "node persistent-entrypoint source contract passed"
    ;;
  --production-env)
    [[ "$stage" == "live" || "$stage" == "stable" ]] || { echo "node production guard skipped for stage '$stage'"; exit 0; }
    [[ "$image_ref" =~ ^ghcr\.io/qwickapps/img-node:(release|stable)$ || "$image_ref" =~ ^ghcr\.io/qwickapps/img-node@sha256:[0-9a-f]{64}$ ]] \
      || fail "live/stable node deploy must use approved qwickapps img-node release/stable tag or immutable digest, got '$image_ref'"
    if [[ -d .deploy-app-env ]] && grep -RInE '^[[:space:]]*(TS_EPHEMERAL_AUTHKEY|TS_STATE_MODE)[[:space:]]*=[[:space:]]*(.+|mem)[[:space:]]*$' .deploy-app-env 2>/dev/null; then
      fail "rendered production env enables TS_EPHEMERAL_AUTHKEY or TS_STATE_MODE=mem"
    fi
    echo "node persistent-entrypoint production contract passed"
    ;;
  *) fail "unknown mode '$mode'" ;;
esac
