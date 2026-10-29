#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADMIT=(python3 "$ROOT/scripts/topology-admission.py" --registry "$ROOT/config/service-identities.json")
pass=0; fail=0
expect_pass() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS $label"; pass=$((pass+1)); else echo "FAIL expected pass: $label"; fail=$((fail+1)); fi; }
expect_deny() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL expected deny: $label"; fail=$((fail+1)); else echo "PASS denied $label"; pass=$((pass+1)); fi; }
# Exact replay: stale issue requests a second MCP LB on oci-main. Must stop pre-mutation.
expect_deny "mcp wrong host" "${ADMIT[@]}" --host oci-main --platform caprover --app qwickapps-mcp-lb --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-sha 0123456789012345678901234567890123456789 --source-merged true
expect_deny "duplicate canonical claimant" "${ADMIT[@]}" --host oci-gateway --platform caprover --app qwickapps-mcp-lb --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-sha 0123456789012345678901234567890123456789 --source-merged true
expect_deny "unmerged source" "${ADMIT[@]}" --host oci-gateway --platform caprover --app srv-captain--qwickapps-mcp --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-sha 0123456789012345678901234567890123456789 --source-merged false
expect_deny "direct untraceable deploy" "${ADMIT[@]}" --host oci-gateway --platform caprover --app srv-captain--qwickapps-mcp --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-merged true
expect_deny "attempted canonical rename" "${ADMIT[@]}" --host oci-gateway --platform caprover --app qwickapps-mcp-gateway-retired --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-sha 0123456789012345678901234567890123456789 --source-merged true
expect_pass "canonical owner" "${ADMIT[@]}" --host oci-gateway --platform caprover --app srv-captain--qwickapps-mcp --hostname qwickapps-mcp --image-ref ghcr.io/qwickapps/qwickway:latest --production --source-sha 0123456789012345678901234567890123456789 --source-merged true
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Live-state replay of the 2026-10-08 finding. Static admission accepts the
# registered owner, but the companion live preflight must deny mutation while
# a hand-made Docker service owns the same Tailscale hostname at r=1. Keep
# the Docker/HTTP mocks in this suite so a future change cannot reduce the
# admission contract to registry input validation alone.
cat > "$TMP/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
host=""
for arg in "$@"; do [[ "$arg" == *@* ]] && host="${arg#*@}"; done
command="${*: -1}"
if [[ "$host" != "oci-gateway" ]]; then exit 0; fi
if [[ "$command" == *"service ls"* ]]; then
  printf '%s\n' qwickapps-mcp-gateway-canary-20261003 srv-captain--qwickapps-mcp
elif [[ "$command" == *"service inspect"* ]]; then
  cat <<'JSON'
[{"Spec":{"Name":"qwickapps-mcp-gateway-canary-20261003","Mode":{"Replicated":{"Replicas":1}},"TaskTemplate":{"ContainerSpec":{"Env":["TS_HOSTNAME=qwickapps-mcp"]}}}},
 {"Spec":{"Name":"srv-captain--qwickapps-mcp","Mode":{"Replicated":{"Replicas":0}},"TaskTemplate":{"ContainerSpec":{"Env":["TS_HOSTNAME=qwickapps-mcp"]}}}}]
JSON
fi
SH
chmod +x "$TMP/ssh"
cat > "$TMP/live-registry.json" <<'JSON'
{"version":1,"change_control":"test","services":[{"canonical_hostname":"qwickapps-mcp","workload_owner":"mcp-platform","repo":"qwickapps/mcp","platform":"caprover","app":"srv-captain--qwickapps-mcp","required_host":"oci-gateway","role":"load-balancer","state":{"mode":"persistent","volume":"/var/lib/tailscale"},"images":["ghcr.io/qwickapps/qwickway"]}]}
JSON
cat > "$TMP/live-api.py" <<'PY'
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if "/tailnet/" in self.path:
            body = {"devices": [{"name": "qwickapps-mcp.taile324e7.ts.net", "authorized": True, "online": True}]}
        elif self.path.endswith("/applications"):
            body = []
        else:
            body = []
        raw = json.dumps(body).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def log_message(self, *_): pass
HTTPServer(("127.0.0.1", int(__import__("sys").argv[1])), Handler).serve_forever()
PY
PORT="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
python3 "$TMP/live-api.py" "$PORT" &
LIVE_API_PID=$!
trap 'kill "${LIVE_API_PID:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
ready=0
for _ in $(seq 1 20); do
  if python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 0.2).close()" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.1
done
if [[ "$ready" -ne 1 ]]; then
  echo "FAIL live fixture API did not start" >&2
  exit 1
fi
expect_deny "live claimant replay" env PATH="$TMP:$PATH" python3 "$ROOT/scripts/topology-live-preflight.py" \
  --registry "$TMP/live-registry.json" --hostname qwickapps-mcp --app srv-captain--qwickapps-mcp \
  --target-host oci-gateway --caprover-hosts oci-gateway oci-main server1-qwickforge \
  --ts-api-key test --tailscale-base-url "http://127.0.0.1:$PORT" \
  --coolify-token test --coolify-base-url "http://127.0.0.1:$PORT"
kill "$LIVE_API_PID" 2>/dev/null || true
wait "$LIVE_API_PID" 2>/dev/null || true

"${ADMIT[@]}" --render-windmill-inventory "$TMP/inventory.json" >/dev/null
python3 - "$TMP/inventory.json" <<'PY'
import json,sys
item=json.load(open(sys.argv[1]))["services"][0]
assert item["hostname"] == "qwickapps-mcp"
assert item["host"] == "oci-gateway"
PY
echo "Tests: $pass passed, $fail failed"
test "$fail" -eq 0
