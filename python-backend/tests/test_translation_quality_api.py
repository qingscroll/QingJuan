from __future__ import annotations

from types import SimpleNamespace

import test_translation_quality as base
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api import translation_quality as api

quality_book = base.quality_book


def test_all_quality_routes_enforce_owner_and_return_no_private_paths(quality_book, monkeypatch):
    book, _ = quality_book
    owner = "user-admin"
    monkeypatch.setattr(api, "require_user_access", lambda request: SimpleNamespace(owner_id=owner))
    application = FastAPI()
    application.include_router(api.router, prefix="/api/v1")
    prefix = f"/api/v1/books/{book.id}"
    with TestClient(application) as client:
        current = client.get(prefix + "/translation/chapters/1")
        assert current.status_code == 200
        assert current.headers["Cache-Control"] == "no-store"
        assert "fileName" not in current.text and "localPath" not in current.text
        snapshot = current.json()
        cas = {
            "expectedRevision": snapshot["revision"],
            "sourceHash": snapshot["sourceHash"],
            "translationHash": snapshot["translationHash"],
        }
        edited = client.put(prefix + "/translation/chapters/1", json={**cas, "text": "接口校对"})
        assert edited.status_code == 200
        assert (
            client.put(prefix + "/translation/chapters/1", json={**cas, "text": "过期修改"}).status_code
            == 409
        )
        history_id = edited.json()["history"][0]["id"]
        owner = "another-user"
        for endpoint in (
            "/glossary",
            "/translation/chapters/1",
            f"/translation/chapters/1/history/{history_id}",
            "/translation/usage",
        ):
            assert client.get(prefix + endpoint).status_code == 404
        assert (
            client.put(prefix + "/glossary", json={"expectedRevision": 0, "entries": []}).status_code == 404
        )
        assert (
            client.put(prefix + "/translation/chapters/1", json={**cas, "text": "他人内容"}).status_code
            == 404
        )
        assert (
            client.post(
                prefix + "/translation/chapters/1/restore", json={**cas, "historyId": history_id}
            ).status_code
            == 404
        )
        assert (
            client.post(
                prefix + "/translation/chapters/1/retranslate",
                json={**cas, "operationId": "another-request", "sourceStart": 0, "sourceEnd": 3},
            ).status_code
            == 404
        )


def test_duplicate_glossary_terms_and_unbounded_inputs_are_rejected(quality_book, monkeypatch):
    book, _ = quality_book
    monkeypatch.setattr(api, "require_user_access", lambda request: SimpleNamespace(owner_id=book.ownerId))
    application = FastAPI()
    application.include_router(api.router, prefix="/api/v1")
    with TestClient(application) as client:
        response = client.put(
            f"/api/v1/books/{book.id}/glossary",
            json={
                "expectedRevision": 0,
                "entries": [
                    {"source": "Alice", "target": "艾丽丝"},
                    {"source": "alice", "target": "另一个译名"},
                ],
            },
        )
        assert response.status_code == 422
        assert client.get(f"/api/v1/books/{book.id}/glossary").json()["entries"] == []


def test_quality_api_returns_explicit_quota_error_without_changing_translation(quality_book, monkeypatch):
    from app import db

    book, directory = quality_book
    before = (directory / "one.translated.txt").read_bytes()
    with db.get_connection() as conn:
        conn.execute("INSERT INTO resource_limits VALUES(?,0,NULL,0)", (book.ownerId,))
    monkeypatch.setattr(api, "require_user_access", lambda request: SimpleNamespace(owner_id=book.ownerId))
    application = FastAPI()
    application.include_router(api.router, prefix="/api/v1")
    path = f"/api/v1/books/{book.id}/translation/chapters/1"
    with TestClient(application) as client:
        chapter = client.get(path).json()
        response = client.put(
            path,
            json={
                "expectedRevision": chapter["revision"],
                "sourceHash": chapter["sourceHash"],
                "translationHash": chapter["translationHash"],
                "text": "大" * 100,
            },
        )
    assert response.status_code == 413
    assert response.headers["Cache-Control"] == "no-store"
    assert "限额" in response.json()["detail"]
    assert (directory / "one.translated.txt").read_bytes() == before
