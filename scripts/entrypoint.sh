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

# Vast gives every instance a TLS certificate signed by Vast's root CA. Serve the gateway (and the
# PyWorker) over it whenever it is present, so tokens never cross the network in the clear. The key
# is typically readable by root only, and the worker runs unprivileged, so this part runs as root:
# the gateway gets a private copy, and the PyWorker (which only ever reads /etc/instance.key) gets
# group read access to Vast's file. Everything after this runs as the unprivileged `swarm` user.
if [ "$(id -u)" = "0" ] && [ -z "${SWARMUI_TLS_CERT:-}" ] && [ -f /etc/instance.crt ] && [ -f /etc/instance.key ]; then
    install -d -m 700 -o swarm -g swarm /run/swarmui-tls
    install -m 644 -o swarm -g swarm /etc/instance.crt /run/swarmui-tls/instance.crt
    install -m 600 -o swarm -g swarm /etc/instance.key /run/swarmui-tls/instance.key
    export SWARMUI_TLS_CERT=/run/swarmui-tls/instance.crt SWARMUI_TLS_KEY=/run/swarmui-tls/instance.key
    if chgrp swarm /etc/instance.key /etc/instance.crt 2> /dev/null && chmod g+r /etc/instance.key /etc/instance.crt 2> /dev/null; then
        export USE_SSL=true
    elif [ "$MODE" = "serverless" ]; then
        echo "Cannot give the PyWorker access to /etc/instance.key; refusing to serve Vast requests without TLS" >&2
        exit 1
    fi
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
