from functools import partial
from types import SimpleNamespace

import httpx
import pytest
import test_storage_service as base

from app.api import storage as api
from app.maintenance import MaintenanceGate
from app.storage_maintenance import quiesce_storage
from app.storage_service import StorageService

quality_book = base.quality_book
exports = base.exports


@pytest.mark.asyncio
async def test_storage_routes_are_owner_scoped_and_confirm_under_exclusive_gate(exports, monkeypatch):
    from fastapi import FastAPI

    book, _, artifact = exports
    owner = book.ownerId
    gate = MaintenanceGate()
    authentication_calls = []

    async def authenticate(request):
        authentication_calls.append(gate.active_count)

    async def running(request):
        pass

    monkeypatch.setattr(api, "require_user_access", lambda request: SimpleNamespace(owner_id=owner))
    monkeypatch.setattr(api, "require_api_authentication", authenticate)
    monkeypatch.setattr(api, "require_business_service_running", running)
    application = FastAPI()
    application.state.maintenance_gate = gate
    application.state.storage_service = StorageService(quiesce=partial(quiesce_storage, gate))
    application.include_router(api.router)
    application.include_router(api.cleanup_router)
    path = f"/books/{book.id}/storage"
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=application), base_url="http://test"
    ) as client:
        response = await client.get(path)
        assert response.status_code == 200 and response.json()["reclaimableBytes"] == 8
        assert response.headers["Cache-Control"] == "no-store"
        preview = (await client.post(path + "/cleanup-preview", json={"categories": ["exports"]})).json()
        payload = {key: preview[key] for key in ("cleanupId", "confirmationToken")}
        owner = "someone-else"
        assert (await client.get(path)).status_code == 404
        assert (await client.post(path + "/cleanup", json=payload)).status_code == 404
        assert artifact.exists()
        owner = book.ownerId
        result = await client.post(path + "/cleanup", json=payload)
        assert result.status_code == 200 and result.json()["deletedFiles"] == 1
        assert not artifact.exists() and not gate.closed
    assert authentication_calls and all(value >= 1 for value in authentication_calls)
