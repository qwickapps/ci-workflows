#!/usr/bin/env bash
# Unit tests for scripts/verify-multiarch-manifest.sh's parse_platforms()
# (ci-workflows#200 -- the promote-to-stable manifest-flattening bug).
# Pure jq-level tests against fixture JSON shaped like
# `docker buildx imagetools inspect --format '{{json .}}'` output --
# no real docker or registry calls.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT

# Source only the function definitions -- main() is guarded and never runs
# because BASH_SOURCE != $0 when sourced.
# shellcheck source=/dev/null
source "$ROOT/scripts/verify-multiarch-manifest.sh"

pass=0
fail=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $name"
    pass=$((pass + 1))
  else
    echo "not ok - $name"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    fail=$((fail + 1))
  fi
}

# ── Fixture 1: a genuine two-platform manifest list ────────────────────────
FIXTURE_MULTIARCH='{
  "manifest": {
    "mediaType": "application/vnd.oci.image.index.v1+json",
    "manifests": [
      {"digest": "sha256:aaa", "platform": {"architecture": "amd64", "os": "linux"}},
      {"digest": "sha256:bbb", "platform": {"architecture": "arm64", "os": "linux"}}
    ]
  }
}'
RESULT_MULTIARCH="$(parse_platforms "$FIXTURE_MULTIARCH" | tr '\n' ',')"
assert_eq "two real platforms -> both listed, sorted" "linux/amd64,linux/arm64," "$RESULT_MULTIARCH"

# ── Fixture 2: a genuine single-platform image (no .manifest.manifests at
# all -- the real shape buildx reports for a single-arch tag). This must
# resolve to its ONE platform, not be treated as "no platforms" -- most of
# the fleet is legitimately single-arch today, and this script must not
# refuse promoting them. ─────────────────────────────────────────────────
FIXTURE_SINGLEARCH='{
  "manifest": {
    "mediaType": "application/vnd.oci.image.manifest.v1+json"
  },
  "image": {
    "architecture": "arm64",
    "os": "linux"
  }
}'
RESULT_SINGLEARCH="$(parse_platforms "$FIXTURE_SINGLEARCH" | tr '\n' ',')"
assert_eq "single-platform image -> its one platform" "linux/arm64," "$RESULT_SINGLEARCH"

# ── Fixture 3: multi-arch plus an attestation/provenance manifest
# (unknown/unknown) -- must be ignored, not counted as a third platform ───
FIXTURE_WITH_ATTESTATION='{
  "manifest": {
    "manifests": [
      {"digest": "sha256:aaa", "platform": {"architecture": "amd64", "os": "linux"}},
      {"digest": "sha256:bbb", "platform": {"architecture": "arm64", "os": "linux"}},
      {"digest": "sha256:ccc", "platform": {"architecture": "unknown", "os": "unknown"}}
    ]
  }
}'
RESULT_ATTESTATION="$(parse_platforms "$FIXTURE_WITH_ATTESTATION" | tr '\n' ',')"
assert_eq "attestation manifest ignored" "linux/amd64,linux/arm64," "$RESULT_ATTESTATION"

# ── Fixture 4: duplicate platform entries collapse to one ──────────────────
FIXTURE_DUPES='{
  "manifest": {
    "manifests": [
      {"digest": "sha256:aaa", "platform": {"architecture": "amd64", "os": "linux"}},
      {"digest": "sha256:aaa-variant", "platform": {"architecture": "amd64", "os": "linux"}}
    ]
  }
}'
RESULT_DUPES="$(parse_platforms "$FIXTURE_DUPES" | tr '\n' ',')"
assert_eq "duplicate platform entries dedupe" "linux/amd64," "$RESULT_DUPES"

# ── Fixture 5: empty manifests array and no usable .image platform ─────────
FIXTURE_EMPTY='{"manifest": {"manifests": []}, "image": {}}'
RESULT_EMPTY="$(parse_platforms "$FIXTURE_EMPTY" | tr '\n' ',')"
assert_eq "nothing usable -> no platforms" "" "$RESULT_EMPTY"

# ── Fixture 6: single-platform image whose .image.architecture is itself
# "unknown" (a genuinely broken/unusable manifest) -- must not be reported
# as a real platform. ───────────────────────────────────────────────────
FIXTURE_UNKNOWN_SINGLE='{
  "manifest": {"mediaType": "application/vnd.oci.image.manifest.v1+json"},
  "image": {"architecture": "unknown", "os": "unknown"}
}'
RESULT_UNKNOWN_SINGLE="$(parse_platforms "$FIXTURE_UNKNOWN_SINGLE" | tr '\n' ',')"
assert_eq "single-platform unknown/unknown -> no platforms" "" "$RESULT_UNKNOWN_SINGLE"

assert_status() {
  local name="$1" expected="$2" actual="$3"
  assert_eq "$name" "$expected" "$actual"
}

# ── End-to-end main() tests against a stubbed `docker` ──────────────────────
# The tests above exercise the pure parsing logic; these exercise the whole
# CLI (exit codes, error messages) without any real docker/registry call --
# review feedback on ci-workflows#200/#201: "the failure path of the verify
# script is validated by inspection rather than by a test", which matters
# because this script's entire job is to fail correctly.
#
# `docker` is overridden as a shell function (shadowing the real binary for
# the remainder of this sourced process) that returns canned
# `buildx imagetools inspect --format '{{json .}}'` output keyed by ref.
docker() {
  # Drop any leading `--config <dir>` args the way the real invocation does.
  while [ "$1" = "--config" ]; do shift 2; done
  local ref="${*: -1}"  # last argument is always the ref
  case "$ref" in
    multiarch-ref)
      echo '{"manifest":{"manifests":[
        {"platform":{"architecture":"amd64","os":"linux"}},
        {"platform":{"architecture":"arm64","os":"linux"}}
      ]}}'
      ;;
    singlearch-arm64-ref)
      echo '{"manifest":{"mediaType":"application/vnd.oci.image.manifest.v1+json"},"image":{"architecture":"arm64","os":"linux"}}'
      ;;
    unreachable-ref)
      echo "Error: manifest for unreachable-ref: not found" >&2
      return 1
      ;;
    *)
      echo "docker stub: unknown ref $ref" >&2
      return 1
      ;;
  esac
}

run_main() {
  # main() calls `exit` on failure, which would kill the test runner --
  # invoke it in a subshell so a failing case's exit code is captured
  # instead of ending this script.
  ( main "$@" ) >/tmp/verify-mam-test-stdout.$$ 2>/tmp/verify-mam-test-stderr.$$
  echo "$?"
}

# 1. --require satisfied by a genuinely multi-arch ref -> exit 0
STATUS="$(run_main --ref multiarch-ref --require linux/amd64,linux/arm64)"
assert_status "multi-arch ref satisfies --require -> exit 0" "0" "$STATUS"

# 2. --require NOT satisfied by a single-arch ref -> exit 1, specific message
STATUS="$(run_main --ref singlearch-arm64-ref --require linux/amd64,linux/arm64)"
assert_status "single-arch ref fails --require -> exit 1" "1" "$STATUS"
grep -q "missing required platform(s): linux/amd64" /tmp/verify-mam-test-stderr.$$ \
  && { echo "ok - failure names the missing platform"; pass=$((pass + 1)); } \
  || { echo "not ok - failure names the missing platform"; fail=$((fail + 1)); }

# 3. --source-ref mode: target missing a platform the source has -> exit 1
STATUS="$(run_main --ref singlearch-arm64-ref --source-ref multiarch-ref)"
assert_status "target missing source's platform -> exit 1" "1" "$STATUS"

# 4. --source-ref mode: single-arch source, matching single-arch target -> 0
STATUS="$(run_main --ref singlearch-arm64-ref --source-ref singlearch-arm64-ref)"
assert_status "single-arch source == single-arch target -> exit 0" "0" "$STATUS"

# 5. docker/registry call itself fails (unreachable ref) -> exit 1, not a
# crash and not a false pass.
STATUS="$(run_main --ref unreachable-ref --require linux/amd64,linux/arm64)"
assert_status "registry inspect failure -> exit 1 (fails closed)" "1" "$STATUS"
grep -q "failed to inspect manifest" /tmp/verify-mam-test-stderr.$$ \
  && { echo "ok - failure names the inspect error"; pass=$((pass + 1)); } \
  || { echo "not ok - failure names the inspect error"; fail=$((fail + 1)); }

# 6. Usage errors -> exit 2, not 0 or 1
STATUS="$(run_main --require linux/amd64,linux/arm64)"  # missing --ref
assert_status "missing --ref -> exit 2" "2" "$STATUS"

STATUS="$(run_main --ref multiarch-ref)"  # neither --require nor --source-ref
assert_status "neither --require nor --source-ref -> exit 2" "2" "$STATUS"

STATUS="$(run_main --ref multiarch-ref --require linux/amd64 --source-ref multiarch-ref)"  # both
assert_status "both --require and --source-ref -> exit 2" "2" "$STATUS"

rm -f /tmp/verify-mam-test-stdout.$$ /tmp/verify-mam-test-stderr.$$

echo
echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
