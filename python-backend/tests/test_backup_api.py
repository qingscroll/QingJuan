from __future__ import annotations

import json

import test_backup_service
from fastapi.testclient import TestClient
from test_backup_service import quiesce

from app.admin_auth import ADMIN_CSRF_HEADER, ADMIN_SESSION_COOKIE, create_admin_session, hash_admin_password
from app.api.backups import router
from app.application import create_application
from app.backup_service import BackupService

source = test_backup_service.source


def test_backup_api_only_accepts_management_cookie_with_csrf(source, monkeypatch):
    monkeypatch.setenv("QINGJUAN_ADMIN_PASSWORD_HASH", hash_admin_password("test-admin-password"))
    monkeypatch.setenv("QINGJUAN_ADMIN_SESSION_SECRET", "45" * 32)
    application = create_application(routers=[router], api_prefix="/api/v1")
    application.state.backup_service = BackupService(source, "2.2.1", quiesce=quiesce)
    session = create_admin_session()
    with TestClient(application) as client:
        assert client.post("/api/v1/backups", json={"acknowledgeSensitiveData": True}).status_code == 401
        assert (
            client.post(
                "/api/v1/backups",
                json={"acknowledgeSensitiveData": True},
                headers={"Authorization": "Bearer remote-admin-user-session"},
            ).status_code
            == 401
        )
        client.cookies.set(ADMIN_SESSION_COOKIE, session.token)
        assert client.post("/api/v1/backups", json={"acknowledgeSensitiveData": True}).status_code == 403
        headers = {ADMIN_CSRF_HEADER: session.csrf_token}
        assert client.post("/api/v1/backups", json={}, headers=headers).status_code == 422
        created = client.post("/api/v1/backups", json={"acknowledgeSensitiveData": True}, headers=headers)
        assert created.status_code == 201, created.text
        assert created.headers["Cache-Control"] == "no-store"
        record = created.json()
        assert str(source) not in created.text
        assert "sensitive-test" not in created.text
        assert client.get(record["downloadUrl"], headers=headers).status_code == 405
        assert client.post(record["downloadUrl"]).status_code == 403
        downloaded = client.post(record["downloadUrl"], headers=headers)
        assert downloaded.status_code == 200
        report = client.post(
            "/api/v1/backups/inspect",
            files={"file": ("private.zip", downloaded.content, "application/zip")},
            data={"mode": "replace"},
            headers=headers,
        )
        assert report.status_code == 200, report.text
        payload = report.json()
        assert payload["backupCounts"]["books"] == 1
        assert "sensitive-test" not in json.dumps(payload)
        assert (
            client.post(
                "/api/v1/backups/restore",
                json={key: payload[key] for key in ("restoreId", "confirmationToken")},
                headers=headers,
            ).status_code
            == 200
        )
        assert len(client.get("/api/v1/backups", headers=headers).json()) == 1


def test_trusted_windows_loopback_requires_local_request_marker(source, monkeypatch):
    import os

    import pytest

    if os.name != "nt":
        pytest.skip("Windows implicit management session")
    monkeypatch.setenv("QINGJUAN_TRUST_LOCAL_ADMIN", "1")
    application = create_application(routers=[router], api_prefix="/api/v1")
    application.state.backup_service = BackupService(source, "2.2.1", quiesce=quiesce)
    with TestClient(application, base_url="http://127.0.0.1", client=("127.0.0.1", 53000)) as client:
        assert client.post("/api/v1/backups", json={"acknowledgeSensitiveData": True}).status_code == 401
        response = client.post(
            "/api/v1/backups",
            json={"acknowledgeSensitiveData": True},
            headers={"X-QingJuan-Local-Request": "1"},
        )
        assert response.status_code == 201, response.text
