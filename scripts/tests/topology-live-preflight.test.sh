#!/usr/bin/env bash
# Tests for scripts/topology-live-preflight.py using:
#   - a fake `ssh` binary on PATH (simulates docker service ls/inspect on
#     each CapRover host)
#   - a local HTTP mock server (simulates the Tailscale + Coolify APIs)
#
# Fixture replays the real 2026-10-08 finding: a hand-made swarm service
# "qwickapps-mcp-gateway-canary-20261003" owns qwickapps-mcp live, while the
# registered srv-captain--qwickapps-mcp sits at replicas=0. A deploy of
# srv-captain--qwickapps-mcp must be DENIED until the other claimant is
# scaled to 0.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [[ -n "${MOCK_PID:-}" ]] && kill "$MOCK_PID" 2>/dev/null || true' EXIT

pass=0; fail=0
expect_pass() { local label="$1"; shift; if "$@" >"$TMP/out.$label.log" 2>&1; then echo "PASS $label"; pass=$((pass+1)); else echo "FAIL expected pass: $label"; cat "$TMP/out.$label.log" >&2; fail=$((fail+1)); fi; }
expect_deny() { local label="$1"; shift; if "$@" >"$TMP/out.$label.log" 2>&1; then echo "FAIL expected deny: $label"; cat "$TMP/out.$label.log" >&2; fail=$((fail+1)); else echo "PASS denied $label"; pass=$((pass+1)); fi; }

# --- fake ssh: simulates `docker service ls` / `docker service inspect` ---
# Scenario is selected via $FAKE_SWARM_SCENARIO so different tests can set
# different live states without re-writing the binary.
cat > "$TMP/ssh" <<'FAKESSH'
#!/usr/bin/env bash
# args: -o ... -o ... user@host "command"
host=""
cmd=""
for a in "$@"; do
  case "$a" in
    *@*) host="${a#*@}" ;;
  esac
done
cmd="${*: -1}"

case "$FAKE_SWARM_SCENARIO" in
  conflict)
    if [[ "$host" == "oci-gateway" ]]; then
      if [[ "$cmd" == *"service ls"* ]]; then
        echo "qwickapps-mcp-gateway-canary-20261003"
        echo "srv-captain--qwickapps-mcp"
      elif [[ "$cmd" == *"service inspect"* ]]; then
        cat <<'JSON'
[
  {"Spec":{"Name":"qwickapps-mcp-gateway-canary-20261003","Mode":{"Replicated":{"Replicas":1}},"TaskTemplate":{"ContainerSpec":{"Image":"ghcr.io/qwickapps/qwickway:canary","Env":["TS_HOSTNAME=qwickapps-mcp"]}}}},
  {"Spec":{"Name":"srv-captain--qwickapps-mcp","Mode":{"Replicated":{"Replicas":0}},"TaskTemplate":{"ContainerSpec":{"Image":"ghcr.io/qwickapps/qwickway:latest","Env":["TS_HOSTNAME=qwickapps-mcp"]}}}}
]
JSON
      fi
    else
      [[ "$cmd" == *"service ls"* ]] && echo -n ""
    fi
    ;;
  clean)
    if [[ "$host" == "oci-gateway" ]]; then
      if [[ "$cmd" == *"service ls"* ]]; then
        echo "srv-captain--qwickapps-mcp"
      elif [[ "$cmd" == *"service inspect"* ]]; then
        cat <<'JSON'
[
  {"Spec":{"Name":"srv-captain--qwickapps-mcp","Mode":{"Replicated":{"Replicas":1}},"TaskTemplate":{"ContainerSpec":{"Image":"ghcr.io/qwickapps/qwickway:latest","Env":["TS_HOSTNAME=qwickapps-mcp"]}}}}
]
JSON
      fi
    else
      [[ "$cmd" == *"service ls"* ]] && echo -n ""
    fi
    ;;
  equivalent_claimant)
    if [[ "$host" == "oci-gateway" ]]; then
      if [[ "$cmd" == *"service ls"* ]]; then
        echo "qwickapps-mcp"
        echo "srv-captain--qwickapps-mcp"
      elif [[ "$cmd" == *"service inspect"* ]]; then
        cat <<'JSON'
[
  {"Spec":{"Name":"qwickapps-mcp","Mode":{"Replicated":{"Replicas":1}},"TaskTemplate":{"ContainerSpec":{"Image":"ghcr.io/example/plain-service:latest","Env":[]}}}},
  {"Spec":{"Name":"srv-captain--qwickapps-mcp","Mode":{"Replicated":{"Replicas":1}},"TaskTemplate":{"ContainerSpec":{"Image":"ghcr.io/qwickapps/qwickway:latest","Env":["TS_HOSTNAME=qwickapps-mcp"]}}}}
]
JSON
      fi
    else
      [[ "$cmd" == *"service ls"* ]] && echo -n ""
    fi
    ;;
  unreachable)
    echo "ssh: connect to host $host port 22: Connection timed out" >&2
    exit 255
    ;;
esac
exit 0
FAKESSH
chmod +x "$TMP/ssh"

# --- mock HTTP server for Tailscale + Coolify APIs ---
cat > "$TMP/mock_server.py" <<'PYEOF'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SCENARIO = sys.argv[1]

TS_DEVICES_CLEAN = {"devices": [
    {"name": "qwickapps-mcp.taile324e7.ts.net", "authorized": True, "online": True},
]}
TS_DEVICES_GHOST_ONLINE = {"devices": [
    {"name": "qwickapps-mcp.taile324e7.ts.net", "authorized": True, "online": False},
    {"name": "qwickapps-mcp-2.taile324e7.ts.net", "authorized": True, "online": True},
]}
COOLIFY_APPS_NO_CONFLICT = [{"uuid": "u1", "name": "agent-mail-clamd"}]
COOLIFY_ENVS_NO_CONFLICT = [{"key": "TS_HOSTNAME", "value": "agent-mail-clamd"}]
COOLIFY_APPS_CONFLICT = [{"uuid": "u2", "name": "rogue-momo-app"}]
COOLIFY_ENVS_CONFLICT = [{"key": "TS_HOSTNAME", "value": "qwickapps-mcp"}]


class Handler(BaseHTTPRequestHandler):
    def _send(self, body):
        payload = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if "/tailnet/" in self.path:
            self._send(TS_DEVICES_GHOST_ONLINE if SCENARIO == "ts_ghost" else TS_DEVICES_CLEAN)
        elif self.path.endswith("/applications"):
            self._send(COOLIFY_APPS_CONFLICT if SCENARIO == "coolify_conflict" else COOLIFY_APPS_NO_CONFLICT)
        elif self.path.endswith("/envs"):
            self._send(COOLIFY_ENVS_CONFLICT if SCENARIO == "coolify_conflict" else COOLIFY_ENVS_NO_CONFLICT)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *a):
        pass


port = int(sys.argv[2])
HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PYEOF

start_mock() {
  local scenario="$1"
  local port="$2"
  python3 "$TMP/mock_server.py" "$scenario" "$port" &
  MOCK_PID=$!
  for _ in $(seq 1 20); do
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), timeout=0.2).close()" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "mock server failed to start" >&2; exit 1
}

PRE="$TMP/registry.json"
cat > "$PRE" <<'JSON'
{
  "version": 1,
  "change_control": "test",
  "services": [
    {"canonical_hostname": "qwickapps-mcp", "workload_owner": "mcp-platform", "repo": "qwickapps/mcp",
     "platform": "caprover", "app": "srv-captain--qwickapps-mcp", "required_host": "oci-gateway",
     "role": "load-balancer", "state": {"mode": "persistent", "volume": "/var/lib/tailscale"},
     "images": ["ghcr.io/qwickapps/qwickway"]}
  ]
}
JSON

PREFLIGHT=(python3 "$ROOT/scripts/topology-live-preflight.py" --registry "$PRE"
  --hostname qwickapps-mcp --app srv-captain--qwickapps-mcp --target-host oci-gateway
  --caprover-hosts oci-gateway oci-main server1-qwickforge --ts-api-key dummy --coolify-token dummy)
PREFLIGHT_BARE_APP=(python3 "$ROOT/scripts/topology-live-preflight.py" --registry "$PRE"
  --hostname qwickapps-mcp --app qwickapps-mcp --target-host oci-gateway
  --caprover-hosts oci-gateway oci-main server1-qwickforge --ts-api-key dummy --coolify-token dummy)

echo "== real 2026-10-08 finding: hand-made canary owns hostname live, registered app r=0 =="
start_mock clean 18901
expect_deny "real-finding-replay" env PATH="$TMP:$PATH" FAKE_SWARM_SCENARIO=conflict \
  "${PREFLIGHT[@]}" --tailscale-base-url "http://127.0.0.1:18901" --coolify-base-url "http://127.0.0.1:18901"
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null || true

echo "== clean live state: no other claimant, no ghost, no coolify conflict => admit =="
start_mock clean 18902
STATE_OUT="$TMP/pre-state.json"
expect_pass "clean-state-admitted" env PATH="$TMP:$PATH" FAKE_SWARM_SCENARIO=clean \
  "${PREFLIGHT[@]}" --tailscale-base-url "http://127.0.0.1:18902" --coolify-base-url "http://127.0.0.1:18902" \
  --pre-mutation-state-out "$STATE_OUT"
expect_pass "pre-mutation-snapshot-written" test -s "$STATE_OUT"
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null || true

echo "== online Tailscale ghost (-2 suffix) => deny even with clean docker state =="
start_mock ts_ghost 18903
expect_deny "online-ghost" env PATH="$TMP:$PATH" FAKE_SWARM_SCENARIO=clean \
  "${PREFLIGHT[@]}" --tailscale-base-url "http://127.0.0.1:18903" --coolify-base-url "http://127.0.0.1:18903"
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null || true

echo "== Coolify app on momo claims the same canonical hostname => deny =="
start_mock coolify_conflict 18904
expect_deny "coolify-conflict" env PATH="$TMP:$PATH" FAKE_SWARM_SCENARIO=clean \
  "${PREFLIGHT[@]}" --tailscale-base-url "http://127.0.0.1:18904" --coolify-base-url "http://127.0.0.1:18904"
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null || true

echo "== unreachable SSH source => fail closed (deny), never skip =="
start_mock clean 18905
expect_deny "ssh-unreachable" env PATH="$TMP:$PATH" FAKE_SWARM_SCENARIO=unreachable \
  "${PREFLIGHT[@]}" --tailscale-base-url "http://127.0.0.1:18905" --coolify-base-url "http://127.0.0.1:18905"
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null || true

echo "== missing Coolify token => fail closed (deny), never skip the 3rd source =="
start_mock clean 18906
expect_deny "no-coolify-token" env PATH="$TMP:$PATH" FAKE_SWARM_SCENARIO=clean python3 "$ROOT/scripts/topology-live-preflight.py" --registry "$PRE" \
  --hostname qwickapps-mcp --app srv-captain--qwickapps-mcp --target-host oci-gateway \
  --caprover-hosts oci-gateway oci-main server1-qwickforge --ts-api-key dummy --tailscale-base-url "http://127.0.0.1:18906" \
  --coolify-base-url "http://127.0.0.1:18906"
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null || true

echo "== bare --app name and srv-captain-- target service are the same redeploy claimant => admit =="
start_mock clean 18907
expect_pass "equivalent-claimant-redeploy" env PATH="$TMP:$PATH" FAKE_SWARM_SCENARIO=equivalent_claimant \
  "${PREFLIGHT_BARE_APP[@]}" --tailscale-base-url "http://127.0.0.1:18907" --coolify-base-url "http://127.0.0.1:18907"
kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null || true

echo "Tests: $pass passed, $fail failed"
test "$fail" -eq 0
