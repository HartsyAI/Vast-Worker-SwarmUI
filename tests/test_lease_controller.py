"""Lease controller tests with a fake supervisor (no Vast SDK, no GPU)."""

from __future__ import annotations

import asyncio
import os
import sys
import time
from dataclasses import dataclass

from aiohttp.test_utils import TestClient, TestServer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
import lease_controller as lc  # noqa: E402


@dataclass
class FakeLease:
    token: str
    lease_number: int


class FakeSupervisor:
    def __init__(self) -> None:
        self.began = 0
        self.ended = 0

    async def begin_lease(self) -> FakeLease:
        self.began += 1
        return FakeLease(token=f"token-{self.began}-" + "x" * 32, lease_number=self.began)

    async def end_lease(self) -> None:
        self.ended += 1


def make(live: set[str] | None = None):
    sup = FakeSupervisor()
    sessions = live if live is not None else {"s1", "s2"}

    async def live_sessions() -> set[str]:
        return set(sessions)

    ctrl = lc.LeaseController(sup, "https://1.2.3.4:40000", "c-1", 120.0, live_sessions=live_sessions,
                              watchdog_interval=3600)
    return sup, ctrl, sessions


async def client_for(ctrl) -> TestClient:
    client = TestClient(TestServer(ctrl.make_app()))
    await client.start_server()
    return client


def run(coro):
    return asyncio.run(coro)


def test_lease_opens_once_per_session_and_is_idempotent():
    async def body():
        sup, ctrl, _ = make()
        c = await client_for(ctrl)
        try:
            r1 = await (await c.post("/lease", json={"session_id": "s1"})).json()
            r2 = await (await c.post("/lease", json={"session_id": "s1"})).json()
            assert r1["success"] and r1["token"] == r2["token"]
            assert r1["public_url"] == "https://1.2.3.4:40000" and r1["protocol"] == lc.PROTOCOL_VERSION
            assert sup.began == 1 and sup.ended == 0
        finally:
            await c.close()
    run(body())


def test_lease_requires_a_real_session():
    async def body():
        _, ctrl, _ = make()
        c = await client_for(ctrl)
        try:
            r = await c.post("/lease", json={})
            assert r.status == 422 and (await r.json())["error_id"] == "session_required"
            r = await c.post("/lease", json={"session_id": "forged"})
            assert r.status == 410 and (await r.json())["error_id"] == "session_unknown"
        finally:
            await c.close()
    run(body())


def test_new_session_replaces_a_lost_one_and_revokes_it():
    async def body():
        sup, ctrl, _ = make()
        c = await client_for(ctrl)
        try:
            first = await (await c.post("/lease", json={"session_id": "s1"})).json()
            second = await (await c.post("/lease", json={"session_id": "s2"})).json()
            assert first["token"] != second["token"]
            assert sup.began == 2 and sup.ended == 1
            assert ctrl.session_id == "s2"
        finally:
            await c.close()
    run(body())


def test_on_close_route_ends_only_the_matching_session():
    async def body():
        sup, ctrl, _ = make()
        c = await client_for(ctrl)
        try:
            await c.post("/lease", json={"session_id": "s1"})
            assert (await (await c.post("/lease/end", json={"session_id": "other"})).json()) == {"ended": False}
            assert sup.ended == 0
            assert (await (await c.post("/lease/end", json={"session_id": "s1"})).json()) == {"ended": True}
            assert sup.ended == 1 and ctrl.session_id is None
        finally:
            await c.close()
    run(body())


def test_watchdog_revokes_when_session_disappears():
    async def body():
        sup, ctrl, sessions = make()
        c = await client_for(ctrl)
        try:
            await c.post("/lease", json={"session_id": "s1"})
            await ctrl.check_sessions()
            assert sup.ended == 0
            sessions.discard("s1")
            await ctrl.check_sessions()
            assert sup.ended == 1 and ctrl.session_id is None
        finally:
            await c.close()
    run(body())


def test_benchmark_takes_the_calibrated_time():
    async def body():
        _, ctrl, _ = make()
        c = await client_for(ctrl)
        try:
            start = time.monotonic()
            r = await c.post("/bench", json={})
            assert r.status == 200
            assert time.monotonic() - start >= lc.BENCH_SECONDS * 0.95
        finally:
            await c.close()
    run(body())
    # One session at SESSION_COST must equal the measured capacity (workload per second).
    assert lc.SESSION_COST == lc.BENCH_WORKLOAD / lc.BENCH_SECONDS
