"""secure_session_create, against a stubbed vastai SDK (the real one is only in the image)."""

from __future__ import annotations

import asyncio
import os
import sys
import types
from dataclasses import dataclass

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

for name in ("vastai", "vastai.serverless", "vastai.serverless.server", "vastai.serverless.server.lib"):
    sys.modules.setdefault(name, types.ModuleType(name))


@dataclass
class _AuthData:
    cost: str
    endpoint: str
    reqnum: int
    request_idx: int
    signature: str
    url: str

    @classmethod
    def from_json_msg(cls, msg):
        return cls(**{k: msg[k] for k in ("cost", "endpoint", "reqnum", "request_idx", "signature", "url")})


data_types = types.ModuleType("vastai.serverless.server.lib.data_types")
data_types.AuthData = _AuthData
sys.modules["vastai.serverless.server.lib.data_types"] = data_types
sdk_worker = types.ModuleType("vastai.serverless.server.worker")
for cls in ("BenchmarkConfig", "HandlerConfig", "Worker", "WorkerConfig"):
    setattr(sdk_worker, cls, type(cls, (), {}))
sys.modules["vastai.serverless.server.worker"] = sdk_worker

import worker  # noqa: E402


class FakeBackend:
    def __init__(self, signature_ok: bool):
        self.signature_ok = signature_ok
        self.created = []

    def _Backend__check_signature(self, auth):
        return self.signature_ok

    async def session_create_handler(self, request):
        self.created.append(await request.json())
        return "created"


class FakeRequest:
    def __init__(self, data):
        self._data = data

    async def json(self):
        return self._data


AUTH = {"cost": "1", "endpoint": "e", "reqnum": 1, "request_idx": 1, "signature": "sig", "url": "https://w"}


def call(backend, data):
    worker.secure_session_create(backend)
    return asyncio.run(backend.session_create_handler(FakeRequest(data)))


def test_unsigned_session_is_refused():
    backend = FakeBackend(signature_ok=False)
    response = call(backend, {"auth_data": AUTH, "payload": {"lifetime": 60}})
    assert response.status == 401 and not backend.created


def test_missing_auth_is_refused():
    backend = FakeBackend(signature_ok=True)
    response = call(backend, {"payload": {"lifetime": 60}})
    assert response.status == 422 and not backend.created


def test_signed_session_gets_fixed_cost_and_capped_lifetime():
    backend = FakeBackend(signature_ok=True)
    assert call(backend, {"auth_data": AUTH, "payload": {"lifetime": 10 ** 9, "on_close_route": "/lease/end"}}) == "created"
    created = backend.created[0]
    assert created["auth_data"]["cost"] == worker.SESSION_COST
    assert created["payload"] == {"lifetime": worker.MAX_SESSION_LIFETIME, "on_close_route": "/lease/end"}


def test_bad_lifetime_falls_back_to_default():
    backend = FakeBackend(signature_ok=True)
    call(backend, {"auth_data": AUTH, "payload": {"lifetime": "forever"}})
    assert backend.created[0]["payload"]["lifetime"] == 60.0
