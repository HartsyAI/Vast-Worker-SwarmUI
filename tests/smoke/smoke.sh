#!/usr/bin/env bash
# CPU smoke test for a built Vast worker image. Usage: tests/smoke/smoke.sh <image>
# Vast's control plane is not reachable from CI, so this covers everything that can be checked
# offline:
#   1. Instance mode serves the gateway over TLS from /etc/instance.crt and enforces the token.
#   2. Serverless mode refuses to start outside Vast, and refuses UNSECURED.
#   3. The PyWorker wiring builds inside the image against the pinned vastai SDK.
set -euo pipefail

IMAGE="$1"
LOG=smoke-container.log
: > "$LOG"
WORK="$(mktemp -d)"
NAME="swarmui-vast-smoke-$$"

fail() {
    echo "SMOKE FAIL: $*" >&2
    exit 1
}
cleanup() {
    docker logs "$NAME" >> "$LOG" 2>&1 || true
    docker rm -f "$NAME" > /dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "== Instance mode over TLS =="
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" \
    -keyout "$WORK/instance.key" -out "$WORK/instance.crt" 2> /dev/null
chmod 644 "$WORK/instance.key" "$WORK/instance.crt"
TOKEN="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 48)"
docker run -d --name "$NAME" -p 127.0.0.1:17803:7801 -e SWARMUI_WORKER_TOKEN="$TOKEN" \
    -v "$WORK/instance.crt:/etc/instance.crt:ro" -v "$WORK/instance.key:/etc/instance.key:ro" "$IMAGE" > /dev/null
for _ in $(seq 1 180); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$WORK/instance.crt" -X POST \
        -H "Authorization: Bearer $TOKEN" -d '{}' https://127.0.0.1:17803/API/GetNewSession || true)"
    [ "$code" = "200" ] && break
    sleep 5
done
[ "$code" = "200" ] || fail "instance-mode SwarmUI never answered over TLS (HTTP $code)"
code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$WORK/instance.crt" -X POST -d '{}' https://127.0.0.1:17803/API/GetNewSession)"
[ "$code" = "401" ] || fail "instance mode accepted a request without the token (HTTP $code)"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' http://127.0.0.1:17803/API/GetNewSession || true)"
[ "$code" != "200" ] || fail "gateway answered over plain HTTP while TLS was configured"
docker logs "$NAME" 2>&1 | grep -q "$TOKEN" && fail "worker token appears in container logs"
docker rm -f "$NAME" > /dev/null

echo "== Serverless refusals =="
set +e
docker run --rm -e SWARM_MODE=serverless "$IMAGE" >> "$LOG" 2>&1
[ $? -eq 2 ] || fail "serverless mode started without Vast's environment"
docker run --rm -e SWARM_MODE=serverless -e UNSECURED=true -e PUBLIC_IPADDR=1.2.3.4 -e WORKER_PORT=8000 \
    -e VAST_TCP_PORT_8000=40000 -e CONTAINER_ID=1 -e REPORT_ADDR=http://127.0.0.1:1 "$IMAGE" >> "$LOG" 2>&1
[ $? -eq 2 ] || fail "serverless mode started with UNSECURED=true"
set -e

echo "== PyWorker wiring =="
docker run --rm -e PUBLIC_IPADDR=1.2.3.4 -e WORKER_PORT=8000 -e VAST_TCP_PORT_8000=40000 -e CONTAINER_ID=1 \
    -e REPORT_ADDR=http://127.0.0.1:1 --entrypoint /opt/worker/venv/bin/python "$IMAGE" -c '
import asyncio, worker
from swarmui_worker.config import WorkerConfig
async def main():
    w, ctrl, sup = worker.build(WorkerConfig.from_env())
    assert sorted(r.path for r in w.routes) == ["/bench", "/lease"], w.routes
    assert w.backend.max_sessions == 1
    assert w.backend.benchmark_handler.endpoint == "/bench"
    assert isinstance(w.backend.sessions, dict)
    print("WIRING OK")
asyncio.run(main())
' 2>&1 | tee -a "$LOG" | grep -q "WIRING OK" || fail "PyWorker wiring check failed"

echo "SMOKE PASS"
