#!/usr/bin/env bash
# Contract test for ci-workflows#203: shared helper scripts used by the
# reusable promote workflow must be read from the workflow's immutable SHA,
# while caller-owned deployment files remain in the caller checkout.
#
# The contract is universal, not presence-only:
#   * every `actions/checkout` step that targets qwickapps/ci-workflows is
#     classified by its `path:`; the helper checkout (.ci-workflows) must be
#     pinned to github.job_workflow_sha and sparse-check `scripts`; the
#     stable-host policy checkout (.ci-workflows-policy, ci-workflows#239) is
#     the one documented main-tracked exception and may only carry the
#     policy data file and its evaluator; any other target path fails.
#   * every *.sh invoked by a `run:` block must resolve to a documented
#     source: the pinned helper checkout, the policy checkout (policy
#     evaluator only), the caller-owned deploy scripts, or the runner-owned
#     protocols drift checker. A bare `scripts/...` path (the original
#     defect) or any other source fails.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT
WORKFLOW="${WORKFLOW:-$ROOT/.github/workflows/promote-to-stable.yml}"

HELPER_PATH=".ci-workflows"
POLICY_PATH=".ci-workflows-policy"
# shellcheck disable=SC2016 # GitHub expression is intentionally literal.
PINNED_REF='ref: ${{ github.job_workflow_sha }}'

# Shared helpers the promote workflow must only ever run from the pinned
# helper checkout.
PINNED_HELPERS=(verify-multiarch-manifest.sh rescope-ts-hostname.sh)
# Caller-owned assets: these must come from the caller checkout and never
# from either ci-workflows checkout.
CALLER_OWNED=(.github/scripts/deploy-from-ghcr.sh .qwickapps/runtime.env.manifest.yml)

pass=0
fail=0

ok()  { echo "ok - $1"; pass=$((pass + 1)); }
nok() { echo "not ok - $1"; if [ $# -gt 1 ]; then printf '    %s\n' "${@:2}"; fi; fail=$((fail + 1)); }

assert_contains() {
  local name="$1" needle="$2"
  if grep -Fq -- "$needle" "$WORKFLOW"; then ok "$name"; else nok "$name"; fi
}

assert_not_contains() {
  local name="$1" needle="$2"
  if grep -Fq -- "$needle" "$WORKFLOW"; then nok "$name" "$(grep -Fn -- "$needle" "$WORKFLOW")"; else ok "$name"; fi
}

# Non-comment lines of the workflow, prefixed with their line number.
noncomment() {
  grep -nEv '^[[:space:]]*#' "$WORKFLOW" || true
}

# Emit the step blocks of the workflow as NUL-separated records. A step
# starts at a `- name:` list item under `steps:`.
step_blocks() {
  awk '
    /^[[:space:]]*- name:/ { if (buf != "") printf "%s\0", buf; buf = $0; next }
    { if (buf != "") buf = buf "\n" $0 }
    END { if (buf != "") printf "%s\0", buf }
  ' "$WORKFLOW"
}

block_has() { grep -Fq -- "$2" <<<"$1"; }
block_name() { sed -n '1s/^[[:space:]]*- name:[[:space:]]*//p' <<<"$1"; }
# Entries of the block's `sparse-checkout: |` list, one per line.
sparse_entries() {
  awk '/sparse-checkout: \|/{f=1;next} f&&/^[[:space:]]{12}[^[:space:]]/{sub(/^[[:space:]]+/,"");print;next} f{f=0}' <<<"$1"
}

# ---------------------------------------------------------------------------
# 1. Classify every checkout of qwickapps/ci-workflows.
# ---------------------------------------------------------------------------
helper_checkouts=0
policy_checkouts=0
bad_checkouts=()
while IFS= read -r -d '' block; do
  block_has "$block" "repository: qwickapps/ci-workflows" || continue
  name="$(block_name "$block")"
  if grep -Eq "^[[:space:]]*path: ${HELPER_PATH}[[:space:]]*$" <<<"$block"; then
    helper_checkouts=$((helper_checkouts + 1))
    block_has "$block" "$PINNED_REF" || bad_checkouts+=("helper checkout '$name' is not pinned to github.job_workflow_sha")
    entries="$(sparse_entries "$block")"
    [ "$entries" = "scripts" ] || bad_checkouts+=("helper checkout '$name' must sparse-check exactly 'scripts' (got: ${entries:-<none>})")
  elif grep -Eq "^[[:space:]]*path: ${POLICY_PATH}[[:space:]]*$" <<<"$block"; then
    policy_checkouts=$((policy_checkouts + 1))
    # Documented exception (ci-workflows#239): main-tracked policy data only.
    # It must never become a side door for the pinned helpers or caller assets.
    entries="$(sparse_entries "$block")"
    [ -n "$entries" ] || bad_checkouts+=("policy checkout '$name' is not a sparse checkout")
    while IFS= read -r entry; do
      [ -z "$entry" ] && continue
      case "$entry" in
        config/stable-host-policy.json|scripts/stable-host-policy.sh) ;;
        *) bad_checkouts+=("policy checkout '$name' sparse-checks undocumented entry: $entry") ;;
      esac
    done <<<"$entries"
  else
    bad_checkouts+=("ci-workflows checkout '$name' uses an undocumented path (expected ${HELPER_PATH} or ${POLICY_PATH})")
  fi
done < <(step_blocks)

if [ "$helper_checkouts" -eq 2 ]; then
  ok "pinned helper checkout follows both caller checkouts of the promote job (2 found)"
else
  nok "pinned helper checkout follows both caller checkouts of the promote job (expected 2, got $helper_checkouts)"
fi
if [ "${#bad_checkouts[@]}" -eq 0 ]; then
  ok "every ci-workflows checkout is the pinned helper checkout or the documented policy exception"
else
  nok "every ci-workflows checkout is the pinned helper checkout or the documented policy exception" "${bad_checkouts[@]}"
fi
# The helper checkout is a plain `scripts` sparse cone, so the helpers it has
# to provide must exist at this revision of the repository.
for helper in "${PINNED_HELPERS[@]}"; do
  if [ -f "$ROOT/scripts/$helper" ]; then ok "pinned helper scripts/$helper exists at this revision"; else nok "pinned helper scripts/$helper exists at this revision"; fi
done

# ---------------------------------------------------------------------------
# 2. Universal: every invoked *.sh resolves to a documented source.
# ---------------------------------------------------------------------------
# Sparse-checkout entries are not invocations; drop those lines.
invocations="$(noncomment | grep -E '\.sh([^A-Za-z0-9_./-]|$)' | grep -Ev '^[0-9]+:[[:space:]]{12}(scripts|config)/[^[:space:]]+$' || true)"
bad_invocations=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  while IFS= read -r token; do
    [ -z "$token" ] && continue
    # shellcheck disable=SC2088 # Literal workflow path intentionally begins with a tilde.
    case "$token" in
      "${HELPER_PATH}"/scripts/*.sh) ;;
      "${POLICY_PATH}"/scripts/stable-host-policy.sh) ;;
      .github/scripts/*.sh) ;;
      '~/.qwickapps/protocols/scripts/check-runtime-drift.sh') ;;
      *) bad_invocations+=("$line  <-- $token") ;;
    esac
  done < <(grep -oE '(~|\.)?[A-Za-z0-9_./*-]*\.sh' <<<"${line#*:}")
done <<<"$invocations"
if [ "${#bad_invocations[@]}" -eq 0 ]; then
  ok "every invoked script resolves to the pinned helper checkout, the policy exception, caller-owned deploy scripts, or the runner-owned drift checker"
else
  nok "every invoked script resolves to a documented source" "${bad_invocations[@]}"
fi

# Shared helpers must be invoked at least once (otherwise the pin protects
# nothing) and only via the pinned helper checkout.
for helper in "${PINNED_HELPERS[@]}"; do
  uses="$(noncomment | grep -F -- "$helper" | grep -Ev '^[0-9]+:[[:space:]]{12}scripts/' || true)"
  stray="$(grep -Fv -- "${HELPER_PATH}/scripts/${helper}" <<<"$uses" | sed '/^$/d' || true)"
  if [ -n "$uses" ]; then ok "$helper is invoked by the promote workflow"; else nok "$helper is invoked by the promote workflow"; fi
  if [ -z "$stray" ]; then ok "every $helper use comes from the pinned helper checkout"; else nok "every $helper use comes from the pinned helper checkout" "$stray"; fi
done

# ---------------------------------------------------------------------------
# 3. Caller-owned assets stay caller-owned; drift manifest is explicit.
# ---------------------------------------------------------------------------
assert_contains "caller deployment script remains caller-owned" ".github/scripts/deploy-from-ghcr.sh"
for prefix in "$HELPER_PATH" "$POLICY_PATH"; do
  for asset in "${CALLER_OWNED[@]}"; do
    assert_not_contains "$prefix never supplies caller-owned $asset" "${prefix}/${asset}"
  done
done
assert_contains "caller runtime manifest input defaults to caller path" "default: '.qwickapps/runtime.env.manifest.yml'"
# shellcheck disable=SC2016 # Literal workflow fragments contain shell variables.
assert_contains "caller runtime manifest is checked before drift check" 'if [[ ! -f "$MANIFEST_PATH" ]]; then'
# shellcheck disable=SC2016 # Literal workflow fragments contain shell variables.
assert_contains "missing caller runtime manifest reports its path" '::error::Caller runtime manifest not found: $MANIFEST_PATH'
# shellcheck disable=SC2016 # Literal workflow fragments contain shell variables.
assert_contains "caller runtime manifest remains caller-owned" '--manifest-path "$MANIFEST_PATH"'
assert_not_contains "drift check never hardcodes the manifest path" '--manifest-path .qwickapps/runtime.env.manifest.yml'
assert_contains "runner-owned drift helper is explicitly verified" "Verify protocols runtime available"
# shellcheck disable=SC2088 # Literal workflow path intentionally begins with a tilde.
assert_contains "runner-owned drift helper remains explicit" "~/.qwickapps/protocols/scripts/check-runtime-drift.sh"

echo
echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
