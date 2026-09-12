"""Exercise serial tracking through the production routes and desktop authentication."""

import hashlib
import os
from types import SimpleNamespace

import httpx
import pytest
import test_book_updates as base

from app import admin_auth, db, main
from app.book_updates import BookUpdateService
from app.runtime_bindings import RuntimeBindings
from app.user_auth import issue_user_session, register_user

tracked = base.tracked


@pytest.fixture
def desktop_tracking(tracked, monkeypatch):
    token = "desktop-integration-connection-token"
    monkeypatch.setenv("QINGJUAN_AUTH_TOKEN_SHA256", hashlib.sha256(token.encode()).hexdigest())
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "0")
    monkeypatch.setenv("QINGJUAN_TRUST_LOCAL_ADMIN", "1")
    monkeypatch.setattr(admin_auth, "os", SimpleNamespace(name="nt", getenv=os.getenv))
    monkeypatch.setattr(main, "DATA_DIR", tracked.runtime.DATA_DIR)
    monkeypatch.setattr(main, "LIBRARY_ROOT", tracked.runtime.DATA_DIR / "library")
    monkeypatch.setattr(main, "EXPORT_ROOT", tracked.runtime.DATA_DIR / "exports")
    monkeypatch.setattr(main, "preview_from_url", tracked.runtime.preview_from_url)
    monkeypatch.setattr(main.app.state, "deleted_book_ids", set(), raising=False)
    monkeypatch.setattr(main.app.state, "chapter_manifest_locks", {}, raising=False)
    service = BookUpdateService(RuntimeBindings(vars(main)), now=lambda: tracked.clock[0])
    monkeypatch.setattr(main.app.state, "book_updates", service, raising=False)
    return SimpleNamespace(
        tracked=tracked,
        service=service,
        headers={"Authorization": f"Bearer {token}", "X-QingJuan-Local-Request": "1"},
    )


@pytest.mark.asyncio
@pytest.mark.parametrize("owner_id", ["user-admin", "alice"])
async def test_desktop_library_detail_and_every_tracking_action_share_book_owner(desktop_tracking, owner_id):
    state = desktop_tracking
    db.save_book(db.get_book("serial").model_copy(update={"ownerId": owner_id}))
    transport = httpx.ASGITransport(app=main.app, client=("127.0.0.1", 50000))
    async with httpx.AsyncClient(
        transport=transport, base_url="http://127.0.0.1", headers=state.headers
    ) as client:
        # Trusted desktop requests have admin scope (owner_id=None), while the
        # imported book and its tracking row must keep their concrete owner.
        books = await client.get("/api/v1/books")
        assert books.status_code == 200 and books.json()[0]["id"] == "serial"
        detail = await client.get("/api/v1/books/serial")
        assert detail.status_code == 200 and detail.json()["book"]["id"] == "serial"

        prefix = "/api/v1/books/serial/updates"
        response = await client.get(prefix)
        assert response.status_code == 200, response.text
        assert response.json()["bookId"] == "serial"
        assert response.json()["automatic"] is True
        assert response.headers["Cache-Control"] == "no-store"
        listed = await client.get("/api/v1/book-updates")
        assert listed.status_code == 200
        assert [item["bookId"] for item in listed.json()] == ["serial"]

        configured = await client.put(
            prefix,
            json={"expectedRevision": 0, "intervalHours": 12, "autoDownload": False},
        )
        assert configured.status_code == 200, configured.text
        assert configured.json()["intervalHours"] == 12
        checked = await client.post(prefix + "/check")
        assert checked.status_code == 200, checked.text
        assert checked.json()["newChapterCount"] == 1
        acknowledged = await client.post(prefix + "/ack", json={"throughChapterIndex": 8})
        assert acknowledged.status_code == 200, acknowledged.text
        assert acknowledged.json()["newChapterCount"] == 0

    with db.get_connection() as connection:
        rows = connection.execute("SELECT book_id,owner_id FROM book_updates").fetchall()
    assert rows == [("serial", owner_id)]


@pytest.mark.asyncio
async def test_desktop_tracking_list_includes_all_visible_owners(desktop_tracking):
    other_book = db.get_book("serial").model_copy(
        update={"id": "other-book", "ownerId": "bob", "localPath": "library/other-book"}
    )
    db.save_book(other_book)
    transport = httpx.ASGITransport(app=main.app, client=("127.0.0.1", 50000))
    async with httpx.AsyncClient(
        transport=transport, base_url="http://127.0.0.1", headers=desktop_tracking.headers
    ) as client:
        response = await client.get("/api/v1/book-updates")
        assert response.status_code == 200, response.text
        assert {item["bookId"] for item in response.json()} == {"serial", "other-book"}
    with db.get_connection() as connection:
        rows = connection.execute("SELECT book_id,owner_id FROM book_updates").fetchall()
    assert set(rows) == {("serial", "alice"), ("other-book", "bob")}


@pytest.mark.asyncio
async def test_real_user_sessions_cannot_read_or_change_another_owners_tracking(
    desktop_tracking, monkeypatch
):
    alice = register_user(username="alice", display_name="Alice", password="long-password-for-alice")
    bob = register_user(username="bob", display_name="Bob", password="long-password-for-bob")
    alice_token = issue_user_session(alice)
    bob_token = issue_user_session(bob)
    book = db.get_book("serial").model_copy(update={"ownerId": alice.id})
    db.save_book(book)
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "1")
    transport = httpx.ASGITransport(app=main.app, client=("127.0.0.1", 50000))
    async with httpx.AsyncClient(
        transport=transport, base_url="http://127.0.0.1", headers=desktop_tracking.headers
    ) as client:
        prefix = "/api/v1/books/serial/updates"
        assert (await client.get(prefix)).status_code == 401
        client.headers["X-QingJuan-User-Token"] = alice_token
        assert (await client.get(prefix)).status_code == 200
        client.headers["X-QingJuan-User-Token"] = bob_token
        for method, path, payload in [
            ("GET", prefix, None),
            ("PUT", prefix, {"expectedRevision": 0, "intervalHours": 12, "autoDownload": True}),
            ("POST", prefix + "/check", None),
            ("POST", prefix + "/ack", {"throughChapterIndex": 7}),
        ]:
            response = await client.request(method, path, json=payload)
            assert response.status_code == 404, response.text
        listed = await client.get("/api/v1/book-updates")
        assert listed.status_code == 200 and listed.json() == []

    row = desktop_tracking.service.state("serial", alice.id)
    assert row.intervalHours == 6 and not row.autoDownload
    assert row.acknowledgedChapterIndex == 7
