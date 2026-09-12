import asyncio
import hashlib
from functools import partial

import httpx
import pytest
import test_storage_service as base

from app import security
from app.api import storage
from app.application import create_application
from app.storage_maintenance import quiesce_storage
from app.storage_service import StorageService

quality_book = base.quality_book
exports = base.exports


@pytest.mark.asyncio
async def test_cleanup_real_composition_authenticates_without_admission_deadlock(exports, monkeypatch):
    book, _, artifact = exports
    token = "storage-composition-connection-token"
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "0")
    monkeypatch.setenv(security.TOKEN_DIGEST_ENV, hashlib.sha256(token.encode()).hexdigest())
    application = create_application(
        routers=[storage.router], management_routers=[storage.cleanup_router], authenticate=True,
    )
    gate = application.state.maintenance_gate
    application.state.storage_service = StorageService(quiesce=partial(quiesce_storage, gate))
    admissions = []

    async def device_write(request):
        admissions.append(gate.active_count)
        assert not gate.closed

    monkeypatch.setattr(security, "register_request_device", device_write)
    path = f"/api/v1/books/{book.id}/storage"
    headers = {"Authorization": f"Bearer {token}"}
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=application), base_url="http://test") as client:
        preview = await client.post(path + "/cleanup-preview", headers=headers, json={"categories": ["exports"]})
        assert preview.status_code == 200, preview.text
        payload = {key: preview.json()[key] for key in ("cleanupId", "confirmationToken")}
        assert (await client.post(path + "/cleanup", json=payload)).status_code == 401
        assert artifact.exists()
        async with gate.exclusive():
            # Only the exact POST cleanup endpoint bypasses outer admission;
            # its own short authentication admission still rejects maintenance.
            blocked = await client.post(path + "/cleanup", headers=headers, json=payload)
            assert blocked.status_code == 409
            assert (await client.get(path + "/cleanup", headers=headers)).status_code == 503
            assert (await client.post(path + "/cleanup-preview", headers=headers,
                json={"categories": ["exports"]})).status_code == 503
            assert (await client.post(path + "/cleanup/extra", headers=headers)).status_code == 503
        result = await asyncio.wait_for(client.post(path + "/cleanup", headers=headers, json=payload), timeout=3)
        assert result.status_code == 200, result.text
        assert result.json()["deletedFiles"] == 1
        assert result.headers["Cache-Control"] == "no-store"
        assert not artifact.exists()
    assert admissions and all(count >= 1 for count in admissions)
    assert gate.active_count == 0 and not gate.closed
