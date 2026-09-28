"""Loopback-only "model server" that the Vast PyWorker forwards to.

The PyWorker (Vast's SDK) owns everything provider-facing: verifying Vast's signed request grants,
native sessions, TLS, and load reports to the autoscaler. It forwards each verified request's
payload to a local model server at the same route. This is that server. It maps Vast's session to
a worker lease:

- `POST /lease` with `{"session_id": ...}` opens the lease on first call and returns the worker's
  address and token. Later calls with the same session return the same lease. Each call made
  through the PyWorker with the session id also extends Vast's session TTL, so this doubles as the
  client's renewal call.
- `POST /lease/end` is the session's `on_close_route`. Vast's SDK calls it when the session ends
  (explicit `/session/end`, or TTL expiry). The lease's token is revoked at once.
- `POST /bench` is the capacity benchmark. It takes a fixed time, so that measured capacity equals
  exactly one session (see BENCH_SECONDS).

A watchdog also compares against the SDK's live session table, so a lost on_close callback can never
leave a token valid after its session is gone.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any, Awaitable, Callable, Optional, Protocol

from aiohttp import web

log = logging.getLogger("vast_worker.lease")

PROTOCOL_VERSION = 2
# The benchmark takes BENCH_SECONDS at workload BENCH_WORKLOAD, so the SDK measures a capacity of
# BENCH_WORKLOAD / BENCH_SECONDS per second. A session opened with cost SESSION_COST therefore reads
# as one fully used worker, and the next session is routed to (or recruits) another worker.
BENCH_SECONDS = 1.0
BENCH_WORKLOAD = 100.0
SESSION_COST = 100


class LeaseSupervisor(Protocol):
    """The subset of swarmui_worker.supervisor.BackgroundSupervisor this controller uses."""

    async def begin_lease(self) -> Any: ...
    async def end_lease(self) -> None: ...


class LeaseController:
    """Maps at most one Vast session to one worker lease."""

    def __init__(self, supervisor: LeaseSupervisor, public_url: str, worker_id: str, idle_seconds: float,
                 live_sessions: Optional[Callable[[], Awaitable[set[str]]]] = None, watchdog_interval: float = 5.0):
        self._supervisor = supervisor
        self._public_url = public_url
        self._worker_id = worker_id
        self._idle_seconds = idle_seconds
        self._live_sessions = live_sessions
        self._watchdog_interval = watchdog_interval
        self._lock = asyncio.Lock()
        self._session_id: Optional[str] = None
        self._token: Optional[str] = None
        self._watchdog: Optional[asyncio.Task] = None

    @property
    def session_id(self) -> Optional[str]:
        return self._session_id

    def make_app(self) -> web.Application:
        app = web.Application()
        app.router.add_post("/lease", self._lease)
        app.router.add_post("/lease/end", self._end)
        app.router.add_post("/bench", self._bench)
        app.on_startup.append(self._start_watchdog)
        app.on_cleanup.append(self._stop_watchdog)
        return app

    async def _lease(self, request: web.Request) -> web.Response:
        body = await _json(request)
        session_id = body.get("session_id")
        if not isinstance(session_id, str) or not session_id:
            return web.json_response({"success": False, "error": "A Vast session is required to lease this worker.",
                                      "error_id": "session_required"}, status=422)
        # The PyWorker verified the request's own session_id, but only forwards the payload; make sure
        # the id the payload names is a session the SDK really holds.
        if self._live_sessions is not None and session_id not in await self._live_sessions():
            return web.json_response({"success": False, "error": "That Vast session does not exist on this worker.",
                                      "error_id": "session_unknown"}, status=410)
        async with self._lock:
            if self._session_id is not None and self._session_id != session_id:
                # The PyWorker allows one session per worker and has already verified this one exists,
                # so the old session is gone even if its on_close callback never arrived.
                log.warning("New session arrived before the previous lease was closed; closing it now")
                await self._close_locked()
            if self._session_id is None:
                lease = await self._supervisor.begin_lease()
                self._session_id = session_id
                self._token = lease.token
                log.info("Lease %s opened for a new session", getattr(lease, "lease_number", "?"))
            return web.json_response({
                "success": True,
                "public_url": self._public_url,
                "token": self._token,
                "worker_id": self._worker_id,
                "protocol": PROTOCOL_VERSION,
                "idle_seconds": self._idle_seconds,
            })

    async def _end(self, request: web.Request) -> web.Response:
        body = await _json(request)
        async with self._lock:
            if self._session_id is None or body.get("session_id") != self._session_id:
                return web.json_response({"ended": False})
            await self._close_locked()
        return web.json_response({"ended": True})

    async def _bench(self, request: web.Request) -> web.Response:
        await asyncio.sleep(BENCH_SECONDS)
        return web.json_response({"success": True})

    async def _close_locked(self) -> None:
        self._session_id = None
        self._token = None
        await self._supervisor.end_lease()
        log.info("Lease closed")

    async def check_sessions(self) -> None:
        """Closes the lease if its session no longer exists in the SDK."""
        if self._live_sessions is None or self._session_id is None:
            return
        live = await self._live_sessions()
        async with self._lock:
            if self._session_id is not None and self._session_id not in live:
                log.info("Lease's session is gone (expired or ended); closing the lease")
                await self._close_locked()

    async def _start_watchdog(self, app: web.Application) -> None:
        async def loop() -> None:
            while True:
                await asyncio.sleep(self._watchdog_interval)
                try:
                    await self.check_sessions()
                except Exception:
                    log.exception("Session watchdog check failed")
        self._watchdog = asyncio.create_task(loop())

    async def _stop_watchdog(self, app: web.Application) -> None:
        if self._watchdog is not None:
            self._watchdog.cancel()


async def _json(request: web.Request) -> dict[str, Any]:
    try:
        data = await request.json()
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}
