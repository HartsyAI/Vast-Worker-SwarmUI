"""Vast.ai Serverless worker for Hartsy's SwarmUI worker image.

Built on Vast's official PyWorker (the `vastai` SDK's serverless server), as Vast's serverless docs
require: only a PyWorker registers with the autoscaler, verifies Vast's signed request grants, and
reports load.

How a Swarm client uses it (the Cloud Backends extension does all of this):
  1. `/route/` then `/session/create` with cost SESSION_COST and lifetime = the idle window. One
     session per worker (max_sessions=1), and an open session counts as a full worker's load, so the
     next session goes to (or recruits) another worker. That is how the endpoint scales out.
  2. `/lease` with the session id returns the worker's HTTPS address and a per-lease token for the
     SwarmUI gateway. Repeating it (sparingly: each call extends the session by a full lifetime)
     keeps the session alive while in use.
  3. When the client stops renewing, the session expires, the lease's token is revoked, the load
     drops to zero, and Vast scales the worker down. A crashed client costs at most one lifetime.
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys
from contextlib import asynccontextmanager

from aiohttp import web
from vastai.serverless.server.worker import BenchmarkConfig, HandlerConfig, Worker, WorkerConfig as VastConfig

from lease_controller import BENCH_SECONDS, BENCH_WORKLOAD, LeaseController
from swarmui_worker import logs
from swarmui_worker.config import ConfigError, WorkerConfig
from swarmui_worker.supervisor import BackgroundSupervisor

log = logging.getLogger("vast_worker")
CONTROL_PORT = int(os.environ.get("LEASE_CONTROL_PORT", "18000"))


def public_url(config: WorkerConfig) -> str:
    """The gateway's public address, as Vast maps it (VAST_TCP_PORT_<internal port>)."""
    ip = os.environ["PUBLIC_IPADDR"]
    port = os.environ.get(f"VAST_TCP_PORT_{config.public_port}", str(config.public_port))
    scheme = "https" if config.tls_cert else "http"
    return f"{scheme}://{ip}:{port}"


def build(config: WorkerConfig) -> tuple[Worker, LeaseController, BackgroundSupervisor]:
    supervisor = BackgroundSupervisor(config)
    worker_ref: dict[str, Worker] = {}

    async def live_sessions() -> set[str]:
        backend = worker_ref["worker"].backend
        return set(getattr(backend, "sessions", {}).keys())

    controller = LeaseController(supervisor, public_url(config), os.environ.get("CONTAINER_ID", "unknown"),
                                 config.idle_seconds, live_sessions=live_sessions)

    @asynccontextmanager
    async def lifecycle():
        # The worker reports "loading" to the autoscaler until SwarmUI answers.
        await asyncio.to_thread(supervisor.start)
        yield

    vast_config = VastConfig(
        model_server_url="http://127.0.0.1",
        model_server_port=CONTROL_PORT,
        max_sessions=1,
        lifecycle=lifecycle,
        handlers=[
            HandlerConfig(route="/lease", allow_parallel_requests=False, max_queue_time=60.0,
                          workload_calculator=lambda payload: 1.0),
            HandlerConfig(route="/bench", allow_parallel_requests=False,
                          workload_calculator=lambda payload: BENCH_WORKLOAD,
                          benchmark_config=BenchmarkConfig(dataset=[{}], runs=3, concurrency=1, do_warmup=False)),
        ],
    )
    worker = Worker(vast_config)
    worker_ref["worker"] = worker
    return worker, controller, supervisor


async def run(config: WorkerConfig) -> None:
    worker, controller, supervisor = build(config)
    # Vast's Worker forces DEBUG on the root logger; restore ours (keeps redaction in place).
    logs.setup(config.log_level, config.log_json)
    runner = web.AppRunner(controller.make_app(), access_log=None)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", CONTROL_PORT).start()
    log.info("Lease controller on 127.0.0.1:%d (benchmark: %.1fs at workload %.0f)",
             CONTROL_PORT, BENCH_SECONDS, BENCH_WORKLOAD)
    try:
        await worker.run_async()
    finally:
        await runner.cleanup()
        supervisor.stop()


def main() -> int:
    try:
        config = WorkerConfig.from_env()
    except ConfigError as ex:
        logs.setup()
        log.error("Invalid configuration: %s", ex)
        return 2
    logs.setup(config.log_level, config.log_json)
    if config.token:
        log.error("SWARMUI_WORKER_TOKEN must not be set for serverless workers; each lease gets its own")
        return 2
    if os.environ.get("UNSECURED", "").lower() in ("1", "true", "yes"):
        log.error("UNSECURED is set, which disables verification of Vast's signed requests; refusing to start")
        return 2
    port_var = f"VAST_TCP_PORT_{os.environ.get('WORKER_PORT', '')}"
    for required in ("PUBLIC_IPADDR", "WORKER_PORT", "CONTAINER_ID", "REPORT_ADDR", port_var):
        if not os.environ.get(required):
            log.error("%s is not set; this worker only runs on Vast.ai Serverless", required)
            return 2
    asyncio.run(run(config))
    return 0


if __name__ == "__main__":
    sys.exit(main())
