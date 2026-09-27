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
# PyWorker) over it whenever it is present, so tokens never cross the network in the clear.
if [ -z "${SWARMUI_TLS_CERT:-}" ] && [ -f /etc/instance.crt ] && [ -f /etc/instance.key ]; then
    export SWARMUI_TLS_CERT=/etc/instance.crt SWARMUI_TLS_KEY=/etc/instance.key USE_SSL=true
fi

# Instances may have a volume (Vast serverless cannot); use its models if it has any.
if [ -z "${SWARMUI_MODEL_ROOT:-}" ]; then
    for candidate in "${VOLUME_PATH:-/workspace}/SwarmUI/Models" "${VOLUME_PATH:-/workspace}/Models"; do
        if [ -d "$candidate" ]; then export SWARMUI_MODEL_ROOT="$candidate"; break; fi
    done
fi
echo "SwarmUI worker (Vast.ai) starting in '$MODE' mode; TLS: ${SWARMUI_TLS_CERT:-off}; models: ${SWARMUI_MODEL_ROOT:-<baked into image>}"

case "$MODE" in
    serverless)
        exec /opt/worker/venv/bin/python -u /opt/worker/worker.py
        ;;
    instance)
        exec /opt/worker/venv/bin/python -u -m swarmui_worker
        ;;
    *)
        echo "SWARM_MODE must be 'serverless', 'instance', or 'auto' (got '$MODE')" >&2
        exit 1
        ;;
esac
