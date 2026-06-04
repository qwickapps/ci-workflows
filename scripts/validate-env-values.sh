#!/usr/bin/env bash
#
# validate-env-values.sh — reject placeholder, garbage, or format-invalid
# environment-variable values before any build or deploy work begins.
#
# Closes qwickapps/ci-workflows#36. The MCP server crash-looped for ~30h
# because the GitHub secret TS_EPHEMERAL_AUTHKEY had been set to the literal
# value `-` to satisfy a naive "non-empty" check. The container then ran
# `tailscale up --authkey=-`, which fails, so the container exited and 502'd.
# A non-empty check is not enough: we must reject known placeholder tokens
# and assert a real format for typed keys (auth keys, URLs, API/service keys).
#
# Usage:
#   validate-env-values.sh <path/to/app-env-<env>-<app>.env>
#
# The env file is KEY=VALUE per line. Blank lines and `#` comments are
# skipped. Values may themselves contain `=` (we split on the first one).
#
# Exits 1 (printing every offending KEY with the reason) if ANY value is:
#   - empty or whitespace-only;
#   - a known placeholder (case-insensitive exact match) or matches a
#     placeholder regex;
#   - format-invalid for a typed key.
# On success prints `validate-env-values: all N values valid`.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  validate-env-values.sh <env-file>

Validates that every KEY=VALUE in <env-file> carries a real value:
non-empty, not a known placeholder, and well-formed for typed keys
(*AUTHKEY*/TS_*KEY auth keys, *_URL URLs, *_API_KEY / *_SERVICE_KEY keys).

Exits non-zero and prints every offending key with a reason on failure.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ENV_FILE="${1:-}"
if [ -z "$ENV_FILE" ]; then
  echo "::error::validate-env-values: missing env-file argument" >&2
  usage >&2
  exit 2
fi
if [ ! -f "$ENV_FILE" ]; then
  echo "::error::validate-env-values: env file not found: $ENV_FILE" >&2
  exit 2
fi

# Known placeholder tokens. Matched case-insensitively against the whole
# (trimmed) value. These are values an operator might type to satisfy a
# naive non-empty check without supplying a real secret.
PLACEHOLDERS=(
  "-"
  "changeme"
  "change-me"
  "set-the-correct-value"
  "todo"
  "tbd"
  "xxx"
  "none"
  "null"
  "placeholder"
  "your-key-here"
)

# Trim leading/trailing whitespace from a value.
trim() {
  local s="$1"
  # Strip leading whitespace.
  s="${s#"${s%%[![:space:]]*}"}"
  # Strip trailing whitespace.
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

failed=0
count=0

report() {
  # report <key> <reason>
  failed=1
  echo "::error::validate-env-values: ${1}: ${2}"
}

# Lowercase helper that is safe on bash 3.2 (macOS self-hosted runner ships
# bash 3.2, which lacks the ${var,,} expansion).
lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

while IFS= read -r line || [ -n "$line" ]; do
  # Skip blank / whitespace-only lines.
  trimmed_line="$(trim "$line")"
  [ -n "$trimmed_line" ] || continue
  # Skip comments.
  case "$trimmed_line" in
    \#*) continue ;;
  esac
  # Require a KEY=VALUE shape.
  case "$line" in
    *=*) ;;
    *)
      report "$trimmed_line" "not a KEY=VALUE line"
      continue
      ;;
  esac

  # Split on the FIRST `=` only; the value may contain further `=`.
  key="${line%%=*}"
  value="${line#*=}"
  key="$(trim "$key")"
  value_trimmed="$(trim "$value")"

  [ -n "$key" ] || { report "<blank>" "empty key"; continue; }

  count=$((count + 1))

  # 1. Empty / whitespace-only value.
  if [ -z "$value_trimmed" ]; then
    report "$key" "value is empty or whitespace-only"
    continue
  fi

  # 2. Known placeholder tokens (case-insensitive exact match).
  value_lc="$(lower "$value_trimmed")"
  is_placeholder=0
  for ph in "${PLACEHOLDERS[@]}"; do
    if [ "$value_lc" = "$(lower "$ph")" ]; then
      report "$key" "value is a known placeholder ('${value_trimmed}')"
      is_placeholder=1
      break
    fi
  done
  [ "$is_placeholder" -eq 0 ] || continue

  # 2b. Placeholder regexes: ^your-.*-here$, ^replace.*, .*-here$ (on lowercased).
  if [[ "$value_lc" =~ ^your-.*-here$ ]] \
    || [[ "$value_lc" =~ ^replace.* ]] \
    || [[ "$value_lc" =~ .*-here$ ]]; then
    report "$key" "value matches a placeholder pattern ('${value_trimmed}')"
    continue
  fi

  # 3. Format checks for typed keys. The value used for format checks is the
  # trimmed value (callers should not store leading/trailing whitespace).
  key_uc="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"

  # 3a. Tailscale-style auth keys.
  #   - TS_API_KEY must start with `tskey-api-`.
  #   - Any other *AUTHKEY* or TS_*KEY must start with `tskey-`.
  if [ "$key_uc" = "TS_API_KEY" ]; then
    case "$value_trimmed" in
      tskey-api-*) ;;
      *) report "$key" "Tailscale API key must start with 'tskey-api-'" ; continue ;;
    esac
  elif [[ "$key_uc" == *AUTHKEY* ]] || [[ "$key_uc" == TS_*KEY ]]; then
    case "$value_trimmed" in
      tskey-*) ;;
      *) report "$key" "Tailscale auth key must start with 'tskey-'" ; continue ;;
    esac
  fi

  # 3b. URLs must contain a scheme (scheme://). Allows http, https, postgres,
  # postgresql, redis, mysql, etc. — rejects bare hostnames with no scheme.
  if [[ "$key_uc" == *_URL ]]; then
    case "$value_trimmed" in
      *://*) ;;
      *) report "$key" "URL must contain a scheme (e.g. https://, postgres://)" ; continue ;;
    esac
  fi

  # 3c. API / service keys (that are not URLs) must be at least 16 chars.
  if [[ "$key_uc" != *_URL ]] \
    && { [[ "$key_uc" == *_SERVICE_KEY ]] || [[ "$key_uc" == *_API_KEY ]]; }; then
    if [ "${#value_trimmed}" -lt 16 ]; then
      report "$key" "secret/API key must be at least 16 characters (got ${#value_trimmed})"
      continue
    fi
  fi
done < "$ENV_FILE"

if [ "$failed" -ne 0 ]; then
  echo "::error::validate-env-values: one or more values are invalid — see errors above; refusing to deploy" >&2
  exit 1
fi

echo "validate-env-values: all ${count} values valid"
