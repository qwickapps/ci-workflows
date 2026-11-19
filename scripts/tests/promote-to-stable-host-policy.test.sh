#!/usr/bin/env bash
# Dynamic regression test for ci-workflows#236 / infra#41. It executes the
# real drift-check credential-resolution step after replacing GitHub Actions
# expressions with controlled inputs, proving the guard runs before any
# registry or CapRover write path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/promote-to-stable.yml"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0

extract_script() {
  python3 -c "
import yaml
with open('$WORKFLOW') as f:
    doc = yaml.safe_load(f)
for step in doc['jobs']['drift-check']['steps']:
    if step.get('name') == 'Resolve CapRover credentials for drift check':
        print(step['run'])
        break
else:
    raise SystemExit('drift-check resolution step not found')
" | sed -E \
    -e 's#\.ci-workflows-policy/scripts/stable-host-policy\.sh#'"$ROOT_DIR"'/scripts/stable-host-policy.sh#g' \
    -e 's/\$\{\{ inputs\.environment \}\}/$IN_ENV/g' \
    -e 's/\$\{\{ inputs\.app_name \}\}/$IN_APP/g' \
    -e 's/\$\{\{ inputs\.caprover_url \|\| secrets\.OCI_DEV_CAPROVER_URL \}\}/$IN_CAPROVER_URL/g' \
    -e 's/\$\{\{ inputs\.caprover_url \|\| secrets\.OCI_MAIN_CAPROVER_URL \}\}/$IN_CAPROVER_URL/g' \
    -e 's/\$\{\{ secrets\.OCI_DEV_CAPROVER_PASSWORD \}\}/$IN_CAPROVER_PASSWORD/g' \
    -e 's/\$\{\{ secrets\.OCI_MAIN_CAPROVER_PASSWORD \}\}/$IN_CAPROVER_PASSWORD/g'
}

extract_script > "$TMPDIR/drift-resolution.sh"
if grep -q '\${{' "$TMPDIR/drift-resolution.sh"; then
  echo "FAIL: extraction left unsubstituted GitHub Actions expressions"
  exit 1
fi

mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [ -n "${CURL_MARKER:-}" ]; then
  : > "$CURL_MARKER"
fi
printf '%s' '{"token":"fixture-token"}'
EOF
chmod +x "$TMPDIR/bin/curl"

run_case() {
  local output="$1"
  (
    export IN_ENV IN_APP IN_CAPROVER_URL IN_CAPROVER_PASSWORD
    export GITHUB_ENV="$TMPDIR/github-env-$$"
    export CURL_MARKER="$output.curl"
    rm -f "$CURL_MARKER"
    : > "$GITHUB_ENV"
    export PATH="$TMPDIR/bin:$PATH"
    bash "$TMPDIR/drift-resolution.sh"
  ) > "$output" 2>&1
}

assert_fails_with() {
  local description="$1" needle="$2" output="$TMPDIR/out-$RANDOM"
  set +e
  run_case "$output"
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ] && grep -qF "$needle" "$output" && [ ! -e "$output.curl" ]; then
    echo "  PASS (red): $description"
    pass=$((pass + 1))
  else
    echo "  FAIL (red): $description"
    sed 's/^/    /' "$output"
    fail=$((fail + 1))
  fi
}

assert_succeeds() {
  local description="$1" output="$TMPDIR/out-$RANDOM"
  set +e
  run_case "$output"
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "  PASS (green): $description"
    pass=$((pass + 1))
  else
    echo "  FAIL (green): $description"
    sed 's/^/    /' "$output"
    fail=$((fail + 1))
  fi
}

echo "== promote-to-stable: Forge stable placement policy =="
IN_CAPROVER_URL=https://captain.app.qwickforge.com IN_CAPROVER_PASSWORD=test \
  IN_ENV=prod IN_APP=qwickapps-forge \
  assert_fails_with "Forge prod is refused before credentials are used" \
  "infra#41: qwickapps-forge-stable must run on macmini-devserver, not oci-main"

IN_CAPROVER_URL=https://captain.app.qwickforge.com IN_CAPROVER_PASSWORD=test \
  IN_ENV=uat IN_APP=qwickapps-forge \
  assert_fails_with "Forge uat is refused before credentials are used" \
  "infra#41: qwickapps-forge-stable must run on macmini-devserver, not oci-main"

IN_CAPROVER_URL=https://unapproved.example.test IN_CAPROVER_PASSWORD=test \
  IN_ENV=prod IN_APP=qwickapps-forge \
  assert_fails_with "Forge cannot bypass policy with an arbitrary host override" \
  "infra#41: qwickapps-forge-stable must run on MACMINI_DEVSERVER; resolved: UNKNOWN"

IN_CAPROVER_URL=https://captain.app.qwickforge.com IN_CAPROVER_PASSWORD=test \
  IN_ENV=prod IN_APP=Qwickapps-Forge \
  assert_fails_with "mixed-case Forge app name is rejected before credentials" \
  "ERROR: app_name must be a lowercase slug"

IN_CAPROVER_URL=https://captain.app.qwickforge.com IN_CAPROVER_PASSWORD=test \
  IN_ENV=prod IN_APP='qwickapps-forge ' \
  assert_fails_with "whitespace-suffixed Forge app name is rejected before credentials" \
  "ERROR: app_name must be a lowercase slug"

IN_CAPROVER_URL=https://captain.app.qwickforge.com IN_CAPROVER_PASSWORD=test \
  IN_ENV=prod IN_APP=qwickapps-forge-live \
  assert_fails_with "Forge alias is refused before credentials" \
  "infra#41: qwickapps-forge-stable must run on macmini-devserver, not oci-main"

IN_CAPROVER_URL=https://captain.app.qwickforge.com IN_CAPROVER_PASSWORD=test \
  IN_ENV=prod IN_APP=qwickapps-unlisted \
  assert_succeeds "unlisted prod promotion remains allowed"

IN_CAPROVER_URL=https://captain.app.qwickforge.com IN_CAPROVER_PASSWORD=test \
  IN_ENV=prod IN_APP=qwickapps-memories \
  assert_succeeds "non-Forge prod promotion remains allowed"

echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]