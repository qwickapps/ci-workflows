#!/usr/bin/env bash
#
# verify-multiarch-manifest.sh -- ci-workflows#200: fails when a tag does
# not carry the platform(s) it is supposed to.
#
# `docker pull` of a multi-arch reference resolves the manifest list to
# ONE platform (the puller's), and a subsequent `docker tag`/`docker push`
# publishes only that single platform -- the manifest list itself never
# survives a pull/tag/push round trip. Every promote-to-stable-shaped
# workflow that re-tags an already-built image this way silently produces
# a single-arch tag regardless of how carefully the source was built, and
# every step along the way reports success. This script is the fail-
# closed check for exactly that: it reads the manifest straight off the
# registry (`docker buildx imagetools inspect`, never pulling or
# materializing the image), so it sees what a puller would actually get,
# not what the workflow source claims to have built.
#
# Two modes:
#   --require <comma-separated os/arch list>   fixed requirement, e.g. a
#       build step asserting it produced linux/amd64,linux/arm64.
#   --source-ref <ref>   derive the requirement from another image's own
#       platform set instead of a fixed list -- what a promote/retag step
#       needs: the target must carry at least every platform the SOURCE
#       actually has, whatever that set is today. If the source is itself
#       single-platform, the requirement is just that one platform --
#       this script does not demand every image in the fleet be
#       multi-arch, only that promotion never LOSES platforms a source
#       already had.
# Exactly one of the two must be given.
#
# Any platform entry with os or architecture == "unknown" is ignored on
# both sides -- buildx attestation/provenance manifests are commonly
# attached alongside the real platforms and are not runnable images; they
# must never count as, or be required as, platform coverage.
#
# Usage:
#   verify-multiarch-manifest.sh --ref <image_ref> --require linux/amd64,linux/arm64 [--config <docker_config_dir>]
#   verify-multiarch-manifest.sh --ref <image_ref> --source-ref <source_image_ref> [--config <docker_config_dir>]
#
# Exit 0 and a PASS line on stderr when every required platform is present.
# Exit 1 with a specifically-named ::error:: on any failure. Exit 2 on
# usage errors.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  verify-multiarch-manifest.sh --ref <image_ref> [--config <docker_config_dir>] \
    (--require <comma-separated os/arch list> | --source-ref <image_ref>)
EOF
}

# Pure: extracts a sorted, deduped "os/arch" list from
# `docker buildx imagetools inspect --format '{{json .}}'`'s normalized
# JSON (as $1), handling both shapes that command produces:
#   - multi-platform: .manifest.manifests[] each carry their own .platform
#   - single-platform: no .manifest.manifests at all; the one platform is
#     .image.architecture / .image.os directly
# Drops "unknown/unknown" attestation entries. No network, no docker --
# safe to unit test against fixture JSON.
parse_platforms() {
  local blob="$1"
  printf '%s' "$blob" | jq -r '
    ( (.manifest.manifests // []) ) as $ms
    | if ($ms | length) > 0 then
        $ms
        | map(select(.platform != null and .platform.os != "unknown" and .platform.architecture != "unknown"))
        | map("\(.platform.os)/\(.platform.architecture)")
      elif (.image.os // null) != null and (.image.architecture // null) != null
           and .image.os != "unknown" and .image.architecture != "unknown" then
        ["\(.image.os)/\(.image.architecture)"]
      else
        []
      end
    | unique | sort | .[]
  '
}

# Impure: fetches a ref's normalized inspect JSON from the registry
# without pulling or materializing it. $1 = ref, remaining args = extra
# `docker` args (e.g. --config <dir>).
fetch_inspect_json() {
  local ref="$1"; shift
  docker "$@" buildx imagetools inspect --format '{{json .}}' "$ref"
}

# $1 = ref, remaining args = extra docker args. Prints the platform list
# (one per line) on success; on failure prints nothing and returns 1.
platforms_of() {
  local ref="$1"; shift
  local blob
  if ! blob="$(fetch_inspect_json "$ref" "$@" 2>&1)"; then
    echo "::error::failed to inspect manifest for ${ref}: ${blob}" >&2
    return 1
  fi
  parse_platforms "$blob"
}

main() {
  local ref="" source_ref="" require="" docker_config_dir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ref) ref="$2"; shift 2 ;;
      --source-ref) source_ref="$2"; shift 2 ;;
      --require) require="$2"; shift 2 ;;
      --config) docker_config_dir="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "::error::unknown option: $1" >&2; usage; exit 2 ;;
    esac
  done

  if [ -z "$ref" ]; then
    echo "::error::--ref is required" >&2
    usage
    exit 2
  fi
  if [ -z "$source_ref" ] && [ -z "$require" ]; then
    echo "::error::exactly one of --source-ref or --require is required" >&2
    usage
    exit 2
  fi
  if [ -n "$source_ref" ] && [ -n "$require" ]; then
    echo "::error::--source-ref and --require are mutually exclusive" >&2
    usage
    exit 2
  fi

  local docker_args=()
  if [ -n "$docker_config_dir" ]; then
    docker_args=(--config "$docker_config_dir")
  fi

  local target_platforms
  target_platforms="$(platforms_of "$ref" "${docker_args[@]}")" || exit 1
  if [ -z "$target_platforms" ]; then
    echo "::error::could not determine any platform for ${ref} (unreadable manifest, or every entry was an unknown/unknown attestation) -- refusing" >&2
    exit 1
  fi

  local required_platforms
  if [ -n "$source_ref" ]; then
    required_platforms="$(platforms_of "$source_ref" "${docker_args[@]}")" || exit 1
    if [ -z "$required_platforms" ]; then
      echo "::error::could not determine any platform for --source-ref ${source_ref} -- cannot derive a requirement from it" >&2
      exit 1
    fi
  else
    required_platforms="$(printf '%s\n' "${require//,/$'\n'}" | sed '/^$/d' | sort -u)"
  fi

  local missing="" plat
  while IFS= read -r plat; do
    [ -z "$plat" ] && continue
    if ! printf '%s\n' "$target_platforms" | grep -qxF "$plat"; then
      missing="${missing}${missing:+, }${plat}"
    fi
  done <<< "$required_platforms"

  if [ -n "$missing" ]; then
    echo "::error::${ref} is missing required platform(s): ${missing}" >&2
    echo "::error::${ref} actually carries: $(printf '%s' "$target_platforms" | tr '\n' ' ')" >&2
    exit 1
  fi

  echo "verify-multiarch-manifest: PASS -- ${ref} carries: $(printf '%s' "$target_platforms" | tr '\n' ' ')" >&2
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
