import httpx
import pytest
import test_resource_limits as base
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app import model_endpoint_security, scraper
from app.admin_auth import ADMIN_CSRF_HEADER, ADMIN_SESSION_COOKIE, create_admin_session
from app.api.resource_limits import admin_router
from app.resource_limits import (
    ResourceLimitError,
    ResourceLimitPatch,
    get_usage,
    resource_actor,
    update_limit,
)

limits_db = base.limits_db


@pytest.mark.asyncio
async def test_retry_consumes_each_attempt_and_stops_before_next_network_call(limits_db, monkeypatch):
    update_limit(limits_db, ResourceLimitPatch(expectedRevision=0, dailyModelRequests=1))
    calls = []
    def reply(request):
        calls.append(request)
        return httpx.Response(503, json={"error": "busy"})
    monkeypatch.setattr(model_endpoint_security, "ValidatedModelHTTPTransport", lambda **_: httpx.MockTransport(reply))
    with resource_actor(limits_db):
        async with model_endpoint_security.create_model_http_client(timeout=2) as client:
            with pytest.raises(ResourceLimitError, match="上限"):
                await scraper._post_translation_json(client, "https://models.example.com/v1/chat/completions",
                    headers={}, payload={"model": "model"}, max_retries=3)
    assert len(calls) == 1
    assert get_usage(limits_db).modelRequests == 1


@pytest.mark.asyncio
async def test_image_edits_are_counted_and_actor_does_not_leak_to_health_checks(limits_db, monkeypatch):
    calls = []
    monkeypatch.setattr(model_endpoint_security, "ValidatedModelHTTPTransport",
        lambda **_: httpx.MockTransport(lambda request: calls.append(request) or httpx.Response(200, json={})))
    async with model_endpoint_security.create_model_http_client(timeout=2) as client:
        with resource_actor(limits_db):
            await client.post("https://models.example.com/v1/images/edits", content=b"image")
        await client.post("https://models.example.com/v1/chat/completions", json={"health": True})
    assert len(calls) == 2
    assert get_usage(limits_db).modelRequests == 1


def test_admin_limits_require_session_csrf_and_stale_revision_is_rejected(limits_db, monkeypatch):
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "1")
    monkeypatch.setenv("QINGJUAN_ADMIN_SESSION_SECRET", "11" * 32)
    application = FastAPI()
    application.include_router(admin_router)
    prefix = f"/admin/api/users/{limits_db}/resources"
    payload = {"expectedRevision": 0, "dailyModelRequests": 2, "storageBytes": None}
    with TestClient(application) as client:
        assert client.get(prefix).status_code == 401
        assert client.put(prefix, json=payload).status_code == 401
        session = create_admin_session()
        client.cookies.set(ADMIN_SESSION_COOKIE, session.token)
        assert client.get(prefix).status_code == 200
        assert client.put(prefix, json=payload).status_code == 403
        saved = client.put(prefix, json=payload, headers={ADMIN_CSRF_HEADER: session.csrf_token})
        assert saved.status_code == 200
        assert saved.json()["limits"]["dailyModelRequests"] == 2
        assert saved.headers["Cache-Control"] == "no-store"
        assert client.put(prefix, json=payload, headers={ADMIN_CSRF_HEADER: session.csrf_token}).status_code == 409
        assert client.get("/admin/api/users/missing/resources").status_code == 404
