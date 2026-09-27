#!/usr/bin/env bash
#
# Behavioral test for scripts/lib/ghcr-token-select.sh (ci-workflows#204).
#
# Proves the actual regression this library exists to fix: a SET but
# STALE/invalid legacy PAT must never beat a VALID ephemeral github.token,
# no matter which order the caller lists them in, because the selection is
# driven by an actual ghcr.io probe (token endpoint + manifest fetch), not
# by "is the secret merely set" (the old `secrets.X || secrets.Y` bug).
#
# curl is stubbed with a bash function (this repo's tests run under bash,
# and a function defined before sourcing/calling the library shadows the
# real `curl` binary for every call the library makes) so this test needs
# no real network access and no real GHCR credentials. The stub inspects
# the fake token embedded in each request to decide whether to respond as
# "valid" or "invalid" -- it never needs the real ghcr.io service to exist.
#
# Also proves the no-token-value-in-output invariant: every assertion
# below captures BOTH stdout and stderr from the library call and greps
# for the literal fake token strings, which must never appear.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/ghcr-token-select.sh
source "$SCRIPTS_DIR/lib/ghcr-token-select.sh"

pass=0
fail=0
assert() {
  local desc="$1"; shift
  if "$@"; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc"
    fail=$((fail + 1))
  fi
}
refute() {
  local desc="$1"; shift
  if ! "$@"; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc"
    fail=$((fail + 1))
  fi
}

VALID_TOKEN="valid-secret-token-marker"
INVALID_TOKEN="stale-secret-token-marker"

# Fake ghcr.io: the token endpoint issues a bearer named after whichever
# credential was presented (so the manifest stage below can tell them
# apart), and the manifest endpoint only returns 200 for the bearer
# derived from VALID_TOKEN. Mirrors the real two-request flow
# (ghcr_probe_pull_token) exactly, just against fake state instead of a
# real registry.
curl() {
  local args=("$@")
  local url=""
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
      https://*) url="${args[$i]}" ;;
    esac
  done

  case "$url" in
    https://ghcr.io/token\?*)
      local user_pass=""
      for ((i = 0; i < ${#args[@]}; i++)); do
        if [ "${args[$i]}" = "-u" ]; then
          user_pass="${args[$((i + 1))]}"
        fi
      done
      local presented_token="${user_pass#*:}"
      if [ "$presented_token" = "$VALID_TOKEN" ]; then
        printf '{"token":"bearer-for-valid"}'
        return 0
      elif [ "$presented_token" = "$INVALID_TOKEN" ]; then
        # Real ghcr.io returns 401 for a genuinely bad credential; -f
        # makes curl itself fail (non-zero exit, no stdout) on that, same
        # as the real binary would.
        return 22
      else
        return 22
      fi
      ;;
    https://ghcr.io/v2/*/manifests/*)
      local auth_header=""
      for ((i = 0; i < ${#args[@]}; i++)); do
        if [ "${args[$i]}" = "-H" ] && [[ "${args[$((i + 1))]}" == Authorization:* ]]; then
          auth_header="${args[$((i + 1))]}"
        fi
      done
      if [[ "$auth_header" == *bearer-for-valid* ]]; then
        printf '200'
      else
        printf '403'
      fi
      return 0
      ;;
    *)
      echo "unexpected curl invocation in test stub: ${args[*]}" >&2
      return 1
      ;;
  esac
}

echo "== ghcr_probe_pull_token: valid vs invalid vs empty =="

assert "valid token probes successfully" \
  ghcr_probe_pull_token "actor" "$VALID_TOKEN" "qwickapps" "img-secrets" "sha-abc123"

refute "invalid (stale) token fails the probe" \
  ghcr_probe_pull_token "actor" "$INVALID_TOKEN" "qwickapps" "img-secrets" "sha-abc123"

refute "empty token fails the probe without ever calling curl" \
  ghcr_probe_pull_token "actor" "" "qwickapps" "img-secrets" "sha-abc123"

echo "== ghcr_select_token: a set-but-invalid PAT never beats a valid github.token =="

OUT="$(ghcr_select_token "actor" "qwickapps" "img-secrets" "sha-abc123" \
  "github.token" "$VALID_TOKEN" \
  "GHCR_PULL_TOKEN" "$INVALID_TOKEN" 2>&1)"
RC=$?
assert "github.token first, valid: selection succeeds" \
  test "$RC" -eq 0
assert "github.token first, valid: selects the ephemeral token, not the stale PAT" \
  test "$OUT" = "github.token"

OUT="$(ghcr_select_token "actor" "qwickapps" "img-secrets" "sha-abc123" \
  "GHCR_PULL_TOKEN" "$INVALID_TOKEN" \
  "github.token" "$VALID_TOKEN" 2>&1)"
RC=$?
assert "stale PAT listed FIRST still loses to a valid github.token listed second" \
  test "$RC" -eq 0
assert "stale PAT listed FIRST: selected label is github.token, not GHCR_PULL_TOKEN" \
  test "$OUT" = "github.token"

set +e
OUT="$(ghcr_select_token "actor" "qwickapps" "img-secrets" "sha-abc123" \
  "GHCR_PULL_TOKEN" "$INVALID_TOKEN" \
  "github.token" "$INVALID_TOKEN" 2>&1)"
RC=$?
set -e
assert "neither candidate works: selection fails (non-zero) rather than picking a bad token" \
  test "$RC" -ne 0
assert "neither candidate works: no label printed to stdout" \
  test -z "$OUT"

echo "== token values are never present in captured output =="

FULL_OUTPUT="$(
  {
    ghcr_select_token "actor" "qwickapps" "img-secrets" "sha-abc123" \
      "GHCR_PULL_TOKEN" "$INVALID_TOKEN" \
      "github.token" "$VALID_TOKEN"
    ghcr_probe_auth_only_result=0
    ghcr_probe_pull_token "actor" "$VALID_TOKEN" "qwickapps" "img-secrets" "sha-abc123" || ghcr_probe_auth_only_result=$?
    echo "auth-only-check-exit=$ghcr_probe_auth_only_result"
  } 2>&1
)"

refute "the valid token's literal value never appears in output" \
  grep -qF "$VALID_TOKEN" <<<"$FULL_OUTPUT"

refute "the invalid token's literal value never appears in output" \
  grep -qF "$INVALID_TOKEN" <<<"$FULL_OUTPUT"

echo "== ghcr_probe_auth_only: package-agnostic credential check =="

assert "auth-only probe succeeds for a token the token endpoint accepts" \
  ghcr_probe_auth_only "actor" "$VALID_TOKEN" "qwickapps"

refute "auth-only probe fails for a token the token endpoint rejects" \
  ghcr_probe_auth_only "actor" "$INVALID_TOKEN" "qwickapps"

refute "auth-only probe fails on an empty token without calling curl" \
  ghcr_probe_auth_only "actor" "" "qwickapps"

echo "== ghcr_parse_image_ref: tag, digest, no-tag and nested-path refs =="

assert_parsed() {
  local desc="$1" ref="$2" expected_owner="$3" expected_package="$4" expected_reference="$5"
  local out owner package reference
  out="$(ghcr_parse_image_ref "$ref")"
  owner="$(sed -n '1p' <<<"$out")"
  package="$(sed -n '2p' <<<"$out")"
  reference="$(sed -n '3p' <<<"$out")"
  if [ "$owner" = "$expected_owner" ] && [ "$package" = "$expected_package" ] && [ "$reference" = "$expected_reference" ]; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc (got owner='$owner' package='$package' reference='$reference', want owner='$expected_owner' package='$expected_package' reference='$expected_reference')"
    fail=$((fail + 1))
  fi
}

assert_parsed "tagged ref" \
  "ghcr.io/qwickapps/img-secrets:sha-abc123" "qwickapps" "img-secrets" "sha-abc123"

assert_parsed "digest-pinned ref keeps the sha256: prefix (the #204 regression)" \
  "ghcr.io/qwickapps/img-secrets@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd" \
  "qwickapps" "img-secrets" "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd"

assert_parsed "no-tag ref defaults to latest" \
  "ghcr.io/qwickapps/img-secrets" "qwickapps" "img-secrets" "latest"

assert_parsed "nested package path keeps slashes, owner is only the first segment" \
  "ghcr.io/qwickapps/team/img-secrets:release" "qwickapps" "team/img-secrets" "release"

assert_parsed "ref with both a tag and a digest: digest wins over the tag" \
  "ghcr.io/qwickapps/img-secrets:stale-tag@sha256:aaaa" "qwickapps" "img-secrets" "sha256:aaaa"

echo "== ghcr_probe_pull_token: single-arch OCI image manifest Accept header (live-registry regression) =="

# ghcr.io 404s a manifest GET for a single-arch OCI image (buildx,
# provenance: false -- e.g. ghcr.io/qwickapps/img-secrets:sha-e5b8c6f)
# unless application/vnd.oci.image.manifest.v1+json is in the Accept
# header; it 200s once it is. This stub reproduces exactly that: it scans
# every "-H Accept: ..." value the library sent (there may be several, if
# the library still sends one -H per media type) and only answers 200 if
# that type shows up somewhere in there.
curl() {
  local args=("$@")
  local url="" accept_headers=""
  for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
      https://*) url="${args[$i]}" ;;
    esac
    if [ "${args[$i]}" = "-H" ]; then
      case "${args[$((i + 1))]}" in
        Accept:*) accept_headers="${accept_headers}${args[$((i + 1))]}"$'\n' ;;
      esac
    fi
  done

  case "$url" in
    https://ghcr.io/token\?*)
      printf '{"token":"bearer-oci-probe"}'
      return 0
      ;;
    https://ghcr.io/v2/*/manifests/*)
      if [[ "$accept_headers" == *"application/vnd.oci.image.manifest.v1+json"* ]]; then
        printf '200'
      else
        printf '404'
      fi
      return 0
      ;;
    *)
      echo "unexpected curl invocation in test stub: ${args[*]}" >&2
      return 1
      ;;
  esac
}

assert "probe succeeds for a single-arch OCI image once Accept includes application/vnd.oci.image.manifest.v1+json" \
  ghcr_probe_pull_token "actor" "some-token" "qwickapps" "img-secrets" "sha-e5b8c6f"

echo ""
echo "Tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
