from __future__ import annotations

import asyncio
import hashlib

import pytest
from fastapi import APIRouter
from fastapi.testclient import TestClient

from app.admin_auth import (
    ADMIN_CSRF_HEADER,
    ADMIN_PASSWORD_HASH_ENV,
    ADMIN_SESSION_SECRET_ENV,
    hash_admin_password,
)
from app.api.admin import router as admin_router
from app.application import create_application
from app.process_lifecycle import BackendServiceController
from app.security import API_PREFIX


def _configure_admin(monkeypatch) -> tuple[str, str]:
    password = "correct-admin-password"
    bearer_token = "client-bearer-token"
    monkeypatch.setenv(
        ADMIN_PASSWORD_HASH_ENV,
        hash_admin_password(password, salt=b"0123456789abcdef", iterations=100_000),
    )
    monkeypatch.setenv(ADMIN_SESSION_SECRET_ENV, "11" * 32)
    monkeypatch.setenv(
        "QINGJUAN_AUTH_TOKEN_SHA256",
        hashlib.sha256(bearer_token.encode()).hexdigest(),
    )
    return password, bearer_token


def test_admin_can_stop_start_and_restart_business_service(monkeypatch) -> None:
    password, bearer_token = _configure_admin(monkeypatch)
    private_router = APIRouter()

    @private_router.get("/private")
    async def get_private() -> dict[str, str]:
        return {"status": "ok"}

    application = create_application(
        routers=[private_router],
        public_routers=[admin_router],
        api_prefix=API_PREFIX,
        authenticate=True,
    )
    with TestClient(application) as admin_client, TestClient(application) as user_client:
        login = admin_client.post(
            "/admin/api/login",
            json={"password": password},
        )
        csrf_token = login.json()["csrfToken"]
        csrf_headers = {ADMIN_CSRF_HEADER: csrf_token}
        bearer_headers = {"Authorization": f"Bearer {bearer_token}"}

        initial = admin_client.get("/admin/api/backend-service")
        stopped = admin_client.post(
            "/admin/api/backend-service/actions",
            headers=csrf_headers,
            json={"action": "stop"},
        )
        blocked = user_client.get(f"{API_PREFIX}/private", headers=bearer_headers)
        admin_still_connected = admin_client.get(f"{API_PREFIX}/private")
        started = admin_client.post(
            "/admin/api/backend-service/actions",
            headers=csrf_headers,
            json={"action": "start"},
        )
        available_again = user_client.get(f"{API_PREFIX}/private", headers=bearer_headers)
        restarted = admin_client.post(
            "/admin/api/backend-service/actions",
            headers=csrf_headers,
            json={"action": "restart"},
        )

    assert initial.status_code == 200
    assert initial.json()["state"] == "running"
    assert stopped.status_code == 200
    assert stopped.json()["businessApiAvailable"] is False
    assert blocked.status_code == 503
    assert blocked.headers["retry-after"] == "5"
    assert admin_still_connected.status_code == 200
    assert started.json()["state"] == "running"
    assert available_again.status_code == 200
    assert restarted.json()["state"] == "running"
    assert restarted.json()["generation"] == started.json()["generation"] + 1


def test_backend_service_actions_require_csrf(monkeypatch) -> None:
    password, _ = _configure_admin(monkeypatch)
    application = create_application(routers=[], public_routers=[admin_router])

    with TestClient(application) as client:
        client.post("/admin/api/login", json={"password": password})
        response = client.post(
            "/admin/api/backend-service/actions",
            json={"action": "stop"},
        )

    assert response.status_code == 403


@pytest.mark.asyncio
async def test_stopped_service_pauses_waiting_queue_work_until_started() -> None:
    controller = BackendServiceController()
    await controller.apply("stop")

    waiting = asyncio.create_task(controller.wait_until_running())
    await asyncio.sleep(0)
    assert waiting.done() is False

    await controller.apply("start")
    await asyncio.wait_for(waiting, timeout=1)
