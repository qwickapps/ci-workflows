#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="$ROOT/scripts/verify-first-stable-bootstrap.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
SHA=0123456789abcdef0123456789abcdef01234567
DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REF="ghcr.io/qwickapps/img-demo@${DIGEST}"

cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
  *packages/container*/versions*)
    case "${MODE:-happy}" in stable_present) echo '[{"metadata":{"container":{"tags":["stable"]}}}]';; probe_error) echo 'network failed' >&2; exit 1;; *) echo '[{"metadata":{"container":{"tags":["release"]}}}]';; esac;;
  *commits/*/check-runs*)
    if [[ "$url" == *first-stable-build* ]]; then
      case "${MODE:-happy}" in
        missing_build) echo '{"total_count":0,"check_runs":[]}' ;;
        mismatch_build) echo "{\"total_count\":1,\"check_runs\":[{\"conclusion\":\"success\",\"output\":{\"text\":\"{\\\"schema\\\":\\\"first-stable-source-proof/v1\\\",\\\"kind\\\":\\\"build\\\",\\\"repo\\\":\\\"qwickapps/demo\\\",\\\"app_name\\\":\\\"demo\\\",\\\"source_sha\\\":\\\"$SHA\\\",\\\"image_digest\\\":\\\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\\\"}\"},\"app\":{\"slug\":\"github-actions\"},\"external_id\":\"123-1\"}]}" ;;
        *) echo "{\"total_count\":1,\"check_runs\":[{\"conclusion\":\"success\",\"output\":{\"text\":\"{\\\"schema\\\":\\\"first-stable-source-proof/v1\\\",\\\"kind\\\":\\\"build\\\",\\\"repo\\\":\\\"qwickapps/demo\\\",\\\"app_name\\\":\\\"demo\\\",\\\"source_sha\\\":\\\"$SHA\\\",\\\"image_digest\\\":\\\"$DIGEST\\\"}\"},\"app\":{\"slug\":\"github-actions\"},\"external_id\":\"123-1\"}]}" ;;
      esac
    elif [[ "$url" == *first-stable-uat* ]]; then
      case "${MODE:-happy}" in
        missing_uat) echo '{"total_count":0,"check_runs":[]}' ;;
        mismatch_uat) echo "{\"total_count\":1,\"check_runs\":[{\"conclusion\":\"success\",\"output\":{\"text\":\"{\\\"schema\\\":\\\"first-stable-source-proof/v1\\\",\\\"kind\\\":\\\"uat\\\",\\\"repo\\\":\\\"qwickapps/demo\\\",\\\"app_name\\\":\\\"demo\\\",\\\"source_sha\\\":\\\"$SHA\\\",\\\"image_digest\\\":\\\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\\\",\\\"stage\\\":\\\"uat\\\"}\"},\"app\":{\"slug\":\"github-actions\"},\"external_id\":\"123-1\"}]}" ;;
        *) echo "{\"total_count\":1,\"check_runs\":[{\"conclusion\":\"success\",\"output\":{\"text\":\"{\\\"schema\\\":\\\"first-stable-source-proof/v1\\\",\\\"kind\\\":\\\"uat\\\",\\\"repo\\\":\\\"qwickapps/demo\\\",\\\"app_name\\\":\\\"demo\\\",\\\"source_sha\\\":\\\"$SHA\\\",\\\"image_digest\\\":\\\"$DIGEST\\\",\\\"stage\\\":\\\"uat\\\"}\"},\"app\":{\"slug\":\"github-actions\"},\"external_id\":\"123-1\"}]}" ;;
      esac
    elif [ "${MODE:-happy}" = marker_present ]; then
      echo "{\"total_count\":1,\"check_runs\":[{\"conclusion\":\"success\",\"output\":{\"text\":\"{\\\"repo\\\":\\\"qwickapps/demo\\\",\\\"app_name\\\":\\\"demo\\\",\\\"sha\\\":\\\"$SHA\\\",\\\"source_digest\\\":\\\"$DIGEST\\\",\\\"release_digest\\\":\\\"$DIGEST\\\"}\"},\"app\":{\"slug\":\"github-actions\"},\"external_id\":\"123-1\"}]}"
    else echo '{"total_count":0,"check_runs":[]}' ; fi;;
  *actions/runs/*/attempts/*/jobs*) echo '{"total_count":2,"jobs":[{"name":"deploy / deploy-caprover","conclusion":"success","steps":[{"name":"Record first-stable build proof","conclusion":"success"},{"name":"Record first-stable UAT proof","conclusion":"success"}]},{"name":"deploy / deploy-stable","conclusion":"success","steps":[{"name":"Record first-stable bootstrap authorization","conclusion":"success"}]}]}' ;;
  *actions/runs/*) echo "{\"head_sha\":\"0123456789abcdef0123456789abcdef01234567\",\"repository\":{\"full_name\":\"qwickapps/demo\"},\"status\":\"completed\",\"event\":\"push\",\"head_branch\":\"main\",\"referenced_workflows\":[{\"path\":\"qwickapps/ci-workflows/.github/workflows/deploy-app.yml@refs/heads/main\",\"ref\":\"refs/heads/main\"}]}" ;;
  *) echo "unexpected gh: $*" >&2; exit 1;; esac
EOF
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [ "${MODE:-happy}" = digest_mismatch ] && [[ "$*" == *:release* ]]; then echo 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; else echo 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; fi
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/docker"
run(){ MODE="$1" SHA="$SHA" DIGEST="$DIGEST" PATH="$TMP/bin:$PATH" bash "$SUT" --github-token x --repo qwickapps/demo --app-name demo --sha "$SHA" --image-ref "$2" --image-base ghcr.io/qwickapps/img-demo >"$TMP/out" 2>&1; }
pass=0; fail=0
expect_ok(){ if run "$1" "$2"; then echo "PASS $3"; pass=$((pass+1)); else echo "FAIL $3"; cat "$TMP/out"; fail=$((fail+1)); fi; }
expect_fail(){ if ! run "$1" "$2" && grep -q "$3" "$TMP/out"; then echo "PASS $4"; pass=$((pass+1)); else echo "FAIL $4"; cat "$TMP/out"; fail=$((fail+1)); fi; }
expect_ok happy "$REF" happy
expect_fail missing_build "$REF" missing_build_proof missing-build-proof
expect_fail missing_uat "$REF" missing_uat_proof missing-uat-proof
expect_fail mismatch_build "$REF" missing_build_proof mismatched-build-proof
expect_fail mismatch_uat "$REF" missing_uat_proof mismatched-uat-proof
expect_fail stable_present "$REF" stable_tag_already_exists stable-present
expect_fail probe_error "$REF" stable_tag_probe_failed probe-error
expect_fail digest_mismatch "$REF" release_digest_mismatch digest-mismatch
expect_fail marker_present "$REF" bootstrap_already_used marker-present
expect_fail happy ghcr.io/qwickapps/img-demo:release image_not_digest_pinned mutable-tag
python3 - <<'PY'
import yaml
p='.github/workflows/deploy-app.yml'; d=yaml.safe_load(open(p)); inp=d[True]['workflow_call']['inputs']
assert inp['bootstrap_first_stable']['default'] is False
run=next(s['run'] for s in d['jobs']['resolve-stage']['steps'] if s.get('id')=='meta')
assert 'stage stable' in run and 'bootstrap_first_stable' in run
print('PASS workflow default-false and stable-only wiring')
PY
pass=$((pass+1))
echo "Tests: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
