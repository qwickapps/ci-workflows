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

echo
echo "== ${pass} passed, ${fail} failed =="
[ "$fail" -eq 0 ]
