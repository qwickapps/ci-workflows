#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/lockfile-consistency-guard.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_pass() {
  local name="$1"
  shift
  if "$@" >/tmp/lockfile-guard.out 2>&1; then
    echo "ok - $name"
  else
    cat /tmp/lockfile-guard.out
    echo "not ok - $name"
    exit 1
  fi
}

assert_fail() {
  local name="$1"
  shift
  if "$@" >/tmp/lockfile-guard.out 2>&1; then
    cat /tmp/lockfile-guard.out
    echo "not ok - $name"
    exit 1
  else
    echo "ok - $name"
  fi
}

fresh_case_dir() {
  local dir="$TMPDIR/$1"
  mkdir -p "$dir"
  echo "$dir"
}

# --- Case 1: non-Node repo (no package.json) is a no-op -------------------
CASE1="$(fresh_case_dir case1-non-node)"
cat > "$CASE1/Dockerfile" <<'EOF'
FROM alpine:3.20
RUN echo "not a node repo"
EOF
assert_pass "no-op for a repo with no package.json" "$SCRIPT" --root "$CASE1"

# --- Case 2: single-stage, pnpm Dockerfile + pnpm-lock.yaml -- pass -------
CASE2="$(fresh_case_dir case2-pnpm-clean)"
echo '{"name":"clean"}' > "$CASE2/package.json"
touch "$CASE2/pnpm-lock.yaml"
cat > "$CASE2/Dockerfile" <<'EOF'
FROM node:22-alpine
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN corepack enable
RUN pnpm install --frozen-lockfile
EOF
assert_pass "passes when the single Dockerfile stage matches CI's pnpm lockfile" "$SCRIPT" --root "$CASE2"

# --- Case 3: the mcp#365 / secrets#89 shape --------------------------------
# Both npm (package-lock.json) AND pnpm (pnpm-lock.yaml) lockfiles are
# present -- CI validates pnpm, but BOTH Dockerfile stages install via npm
# against the lockfile CI never reads.
CASE3="$(fresh_case_dir case3-mcp-shape)"
echo '{"name":"mcp","packageManager":"pnpm@9.12.0"}' > "$CASE3/package.json"
touch "$CASE3/pnpm-lock.yaml"
touch "$CASE3/package-lock.json"
cat > "$CASE3/Dockerfile" <<'EOF'
FROM node:22-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm install
COPY src/ ./src/
RUN npm run build

FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm install --omit=dev
COPY --from=builder /app/dist ./dist
EOF
assert_fail "rejects both Dockerfile stages installing via npm while CI validates pnpm (mcp#365 shape)" "$SCRIPT" --root "$CASE3"

# --- Case 4: multi-stage, only the SECOND stage is wrong -------------------
# Regression guard for the issue's explicit note that both prior fixes had
# to catch every stage, not just the first.
CASE4="$(fresh_case_dir case4-second-stage-wrong)"
echo '{"name":"partial","packageManager":"pnpm@9.12.0"}' > "$CASE4/package.json"
touch "$CASE4/pnpm-lock.yaml"
touch "$CASE4/package-lock.json"
cat > "$CASE4/Dockerfile" <<'EOF'
FROM node:22-alpine AS builder
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN corepack enable
RUN pnpm install --frozen-lockfile
COPY src/ ./src/
RUN pnpm run build

FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm install --omit=dev
COPY --from=builder /app/dist ./dist
EOF
assert_fail "rejects a multi-stage Dockerfile whose FIRST stage is correct but SECOND stage still installs via npm" "$SCRIPT" --root "$CASE4"

# --- Case 5: the ci-workflows#139 mirror -----------------------------------
# The repo only has package-lock.json (npm) -- CI's hardcoded pnpm
# assumption has no matching lockfile in this repo at all. No Dockerfile
# needed to reproduce this shape (qwickapps/agents' failure was in the
# lint/test install step, not a Dockerfile).
CASE5="$(fresh_case_dir case5-agents-shape)"
echo '{"name":"agents"}' > "$CASE5/package.json"
touch "$CASE5/package-lock.json"
assert_fail "rejects CI's hardcoded pnpm when the repo only has package-lock.json (ci-workflows#139 shape)" "$SCRIPT" --root "$CASE5" --ci-manager pnpm

# --- Case 6: same repo as case 5, but CI is told the truth -----------------
assert_pass "passes when --ci-manager is told to match the repo's actual npm lockfile" "$SCRIPT" --root "$CASE5" --ci-manager npm

# --- Case 7: npm install -g (global tool install) must not be mistaken ----
# for a project dependency install.
CASE7="$(fresh_case_dir case7-global-install)"
echo '{"name":"global-tool"}' > "$CASE7/package.json"
touch "$CASE7/pnpm-lock.yaml"
cat > "$CASE7/Dockerfile" <<'EOF'
FROM node:22-alpine
RUN npm install -g pnpm
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
EOF
assert_pass "does not mistake 'npm install -g pnpm' (a global tool install) for a project lockfile install" "$SCRIPT" --root "$CASE7"

# --- Case 8: yarn Dockerfile matched against --ci-manager yarn ------------
CASE8="$(fresh_case_dir case8-yarn-clean)"
echo '{"name":"yarn-repo"}' > "$CASE8/package.json"
touch "$CASE8/yarn.lock"
cat > "$CASE8/Dockerfile" <<'EOF'
FROM node:22-alpine
WORKDIR /app
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile
EOF
assert_pass "passes for a yarn repo when --ci-manager is yarn" "$SCRIPT" --root "$CASE8" --ci-manager yarn

# --- Case 9: custom Dockerfile filename (e.g. Dockerfile.ts) is covered --
CASE9="$(fresh_case_dir case9-named-dockerfile)"
echo '{"name":"secrets","packageManager":"pnpm@12.3.4"}' > "$CASE9/package.json"
touch "$CASE9/pnpm-lock.yaml"
touch "$CASE9/package-lock.json"
cat > "$CASE9/Dockerfile.ts" <<'EOF'
FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY src/ ./src/
RUN npm run build

FROM node:20-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --production
COPY --from=builder /app/dist ./dist
EOF
assert_fail "rejects a non-default-named Dockerfile.ts installing via npm ci while CI validates pnpm (secrets#89 shape)" "$SCRIPT" --root "$CASE9"
