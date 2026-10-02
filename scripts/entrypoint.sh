#!/usr/bin/env bash
# Starts the worker in the right mode for how Vast.ai launched this container.
#
#   serverless  A serverless workergroup sets REPORT_ADDR. Vast's PyWorker is the foreground process;
#               it starts SwarmUI and hands out per-lease tokens through Vast sessions.
#   instance    Anything else (a rented instance). The base image's standalone supervisor runs
#               SwarmUI behind the gateway with a fixed token (SWARMUI_WORKER_TOKEN).
#
# Set SWARM_MODE=serverless or SWARM_MODE=instance to force a mode.
set -euo pipefail

MODE="${SWARM_MODE:-auto}"
if [ "$MODE" = "auto" ]; then
    if [ -n "${REPORT_ADDR:-}" ]; then MODE=serverless; else MODE=instance; fi
fi

# Vast signs a certificate for this instance on request, the way Vast's own images get theirs: a key and CSR made
# here, posted to the console with the instance's ID. Kept only if the answer is a certificate for that key; on any
# failure the worker carries on without TLS (an instance serves plain HTTP; a serverless worker refuses to start).
request_vast_cert() {
    local label="${VAST_CONTAINERLABEL:-}" id dir
    id="${CONTAINER_ID:-${label#C.}}"
    [ -n "$id" ] && command -v openssl > /dev/null && command -v curl > /dev/null || return 1
    dir="$(mktemp -d)"
    if openssl req -newkey rsa:2048 -nodes -sha256 -subj "/C=US/ST=CA/CN=pyworker.vast.ai/" \
            -addext "subjectAltName=IP:0.0.0.0" -keyout "$dir/instance.key" -out "$dir/instance.csr" 2> /dev/null \
        && curl -fsS --retry 4 --retry-connrefused --retry-delay 2 --max-time 30 \
            -H 'Content-Type: application/octet-stream' --data-binary "@$dir/instance.csr" \
            -o "$dir/instance.crt" "https://console.vast.ai/api/v0/sign_cert/?instance_id=$id" \
        && [ "$(openssl x509 -in "$dir/instance.crt" -noout -pubkey 2> /dev/null)" = "$(openssl pkey -in "$dir/instance.key" -pubout 2> /dev/null)" ]; then
        install -m 644 "$dir/instance.crt" /etc/instance.crt
        install -m 600 "$dir/instance.key" /etc/instance.key
        rm -rf "$dir"
        return 0
    fi
    rm -rf "$dir"
    return 1
}
if [ "$(id -u)" = "0" ] && [ ! -f /etc/instance.crt ]; then
    if request_vast_cert; then
        echo "Got this instance's TLS certificate from Vast.ai"
    else
        echo "Could not get a TLS certificate from Vast.ai" >&2
    fi
fi

# Serve the gateway (and the PyWorker) over Vast's instance certificate whenever it is present, so tokens never
# cross the network in the clear. The key is typically readable by root only, and the worker runs unprivileged, so this part runs as root:
# the gateway gets a private copy, and the PyWorker (which only ever reads /etc/instance.key) gets
# group read access to Vast's file. Everything after this runs as the unprivileged `swarm` user.
if [ "$(id -u)" = "0" ] && [ -f /etc/instance.crt ] && [ -f /etc/instance.key ]; then
    if [ -z "${SWARMUI_TLS_CERT:-}" ]; then
        install -d -m 700 -o swarm -g swarm /run/swarmui-tls
        install -m 644 -o swarm -g swarm /etc/instance.crt /run/swarmui-tls/instance.crt
        install -m 600 -o swarm -g swarm /etc/instance.key /run/swarmui-tls/instance.key
        export SWARMUI_TLS_CERT=/run/swarmui-tls/instance.crt SWARMUI_TLS_KEY=/run/swarmui-tls/instance.key
    fi
    # The PyWorker only ever reads /etc/instance.key, whatever certificate the gateway uses.
    if chgrp swarm /etc/instance.key /etc/instance.crt 2> /dev/null && chmod g+r /etc/instance.key /etc/instance.crt 2> /dev/null; then
        export USE_SSL=true
    fi
fi

# Fail closed: a serverless worker hands out gateway tokens from the PyWorker's /lease route, so it must never
# serve that route, or the gateway, without TLS.
if [ "$MODE" = "serverless" ] && { [ "${USE_SSL:-}" != "true" ] || [ -z "${SWARMUI_TLS_CERT:-}" ]; }; then
    echo "Refusing to start a serverless worker without TLS: Vast.ai's /etc/instance.crt and /etc/instance.key must exist and be usable (the container must start as root to hand them to the worker)." >&2
    exit 1
fi

# Drop root for everything that follows.
run() {
    if [ "$(id -u)" = "0" ]; then
        exec setpriv --reuid=swarm --regid=swarm --init-groups "$@"
    fi
    exec "$@"
}

# Instances may have a volume (Vast serverless cannot); use its models if it has any.
if [ -z "${SWARMUI_MODEL_ROOT:-}" ]; then
    for candidate in "${VOLUME_PATH:-/workspace}/SwarmUI/Models" "${VOLUME_PATH:-/workspace}/Models"; do
        if [ -d "$candidate" ]; then export SWARMUI_MODEL_ROOT="$candidate"; break; fi
    done
fi
echo "SwarmUI worker (Vast.ai) starting in '$MODE' mode; TLS: ${SWARMUI_TLS_CERT:-off}; models: ${SWARMUI_MODEL_ROOT:-<baked into image>}"

case "$MODE" in
    serverless)
        run /opt/worker/venv/bin/python -u /opt/worker/worker.py
        ;;
    instance)
        run /opt/worker/venv/bin/python -u -m swarmui_worker
        ;;
    *)
        echo "SWARM_MODE must be 'serverless', 'instance', or 'auto' (got '$MODE')" >&2
        exit 1
        ;;
esac
