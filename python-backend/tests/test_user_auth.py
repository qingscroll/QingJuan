from __future__ import annotations

import hashlib
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier

import pytest
from fastapi import APIRouter, Request
from fastapi.testclient import TestClient

from app import db, main
from app.admin_auth import (
    ADMIN_CSRF_HEADER,
    ADMIN_PASSWORD_HASH_ENV,
    ADMIN_SESSION_SECRET_ENV,
    hash_admin_password,
)
from app.api.admin import router as admin_router
from app.api.auth import router as auth_router
from app.api.routers import (
    library_router,
    plugins_router,
    settings_router,
    sources_router,
    tasks_router,
)
from app.api.translation_model import router as translation_model_router
from app.application import create_application
from app.link_jobs import LinkJobStore
from app.models import AddBookPayload, BookRecord, TaskRecord
from app.multi_user import DEFAULT_ADMIN_USER_ID
from app.security import API_PREFIX
from app.site_plugins.import_jobs import SitePluginImportJobStore
from app.user_auth import require_admin_user_access

ADMIN_PASSWORD = "correct-admin-password"
USER_PASSWORD = "correct-user-password"


@pytest.fixture
def user_database(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Path:
    data_dir = tmp_path / "data"
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "1")
    monkeypatch.setenv(
        ADMIN_PASSWORD_HASH_ENV,
        hash_admin_password(ADMIN_PASSWORD, salt=b"0123456789abcdef", iterations=100_000),
    )
    monkeypatch.setenv(ADMIN_SESSION_SECRET_ENV, "77" * 32)
    monkeypatch.setattr(db, "DATA_DIR", data_dir)
    monkeypatch.setattr(db, "DB_PATH", data_dir / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    monkeypatch.setattr(db, "_SITE_PLUGIN_STATE_CACHE", None)
    monkeypatch.setattr(main, "DATA_DIR", data_dir)
    monkeypatch.setattr(main, "LIBRARY_ROOT", data_dir / "library")
    monkeypatch.setattr(main, "EXPORT_ROOT", data_dir / "exports")
    data_dir.mkdir(parents=True)
    db.init_db()
    return data_dir


def _application(*, include_admin: bool = False):
    return create_application(
        routers=[auth_router, library_router, tasks_router],
        public_routers=[admin_router] if include_admin else [],
        api_prefix=API_PREFIX,
    )


def _register(client: TestClient, username: str) -> dict:
    response = client.post(
        f"{API_PREFIX}/auth/register",
        json={
            "username": username,
            "email": f"{username}@example.test",
            "displayName": username.title(),
            "password": USER_PASSWORD,
        },
    )
    assert response.status_code == 201, response.text
    assert response.headers["cache-control"] == "no-store"
    return response.json()


def _save_book(data_dir: Path, *, owner_id: str, book_id: str, title: str) -> BookRecord:
    book_dir = data_dir / "library" / owner_id / book_id
    book_dir.mkdir(parents=True)
    (book_dir / "0001.txt").write_text(f"{title} 正文", encoding="utf-8")
    (book_dir / "cover.png").write_bytes(b"private-image")
    main.save_manifest(
        book_dir,
        {
            "title": title,
            "book_kind": "长小说",
            "language": "中文",
            "chapters": [
                {
                    "index": 1,
                    "title": "第一章",
                    "file_name": "0001.txt",
                    "url": None,
                    "image_files": [],
                }
            ],
        },
    )
    book = BookRecord(
        ownerId=owner_id,
        id=book_id,
        title=title,
        sourceUrl="",
        bookKind="长小说",
        language="中文",
        status="已下载",
        chapterCount=1,
        translated=False,
        localPath=book_dir.relative_to(data_dir).as_posix(),
        synopsis=f"{title} 简介",
    )
    db.save_book(book)
    return book


def _save_task(*, owner_id: str, task_id: str, book_id: str) -> TaskRecord:
    task = TaskRecord(
        ownerId=owner_id,
        id=task_id,
        bookId=book_id,
        taskType="download",
        chapterIndexes=[1],
        status="failed",
        totalCount=1,
        message="失败",
        error="测试错误",
        createdAt="2030-01-01T00:00:00Z",
        updatedAt="2030-01-01T00:00:00Z",
    )
    db.create_task(task)
    db.append_task_log(task.id, "error", "私有任务日志", task.createdAt)
    return task


@pytest.mark.asyncio
async def test_service_meta_advertises_multi_user(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "1")
    monkeypatch.setattr(main, "_load_or_create_instance_id", lambda: "instance-test")
    meta = await main.get_service_meta()
    assert meta.capabilities["multiUser"] is True


def test_unauthorized_plugin_update_and_import_have_no_side_effects(
    user_database: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    saved_plugins: list[tuple[str, bool]] = []
    plugin_queries: list[str] = []
    preview_calls: list[str] = []
    real_get_site_plugin = main.get_site_plugin

    def tracked_get_site_plugin(plugin_id: str):
        plugin_queries.append(plugin_id)
        return real_get_site_plugin(plugin_id)

    async def tracked_preview(payload: AddBookPayload):
        preview_calls.append(str(payload.sourceUrl))
        raise AssertionError("未授权导入不得开始远程预览")

    monkeypatch.setattr(main, "get_site_plugin", tracked_get_site_plugin)
    monkeypatch.setattr(
        main,
        "save_site_plugin_enabled",
        lambda plugin_id, enabled: saved_plugins.append((plugin_id, enabled)),
    )
    monkeypatch.setattr(main, "preview_from_url", tracked_preview)
    application = create_application(
        routers=[plugins_router, library_router],
        api_prefix=API_PREFIX,
    )
    requests = [
        {},
        {"X-QingJuan-User-Token": "expired-session-token" * 2},
    ]

    with TestClient(application) as client:
        for headers in requests:
            plugin_response = client.put(
                f"{API_PREFIX}/plugins/fanqie",
                json={"enabled": False},
                headers=headers,
            )
            import_response = client.post(
                f"{API_PREFIX}/books/import",
                json={
                    "sourceUrl": "https://www.qidian.com/book/1209977/",
                    "bookKind": "长小说",
                    "language": "中文",
                },
                headers=headers,
            )
            assert plugin_response.status_code == 401
            assert import_response.status_code == 401

    assert plugin_queries == []
    assert saved_plugins == []
    assert preview_calls == []


def test_registration_login_session_logout_and_admin_mapping(user_database: Path) -> None:
    with TestClient(_application()) as client:
        registered = _register(client, "reader_one")
        token = registered["token"]
        assert registered["user"]["role"] == "user"
        assert "bookCount" not in registered["user"]
        assert "password" not in str(registered).lower()

        session = client.get(
            f"{API_PREFIX}/auth/session",
            headers={"X-QingJuan-User-Token": token},
        )
        assert session.status_code == 200
        assert session.json()["username"] == "reader_one"
        assert session.headers["cache-control"] == "no-store"

        admin_login = client.post(
            f"{API_PREFIX}/auth/login",
            json={"username": "admin", "password": ADMIN_PASSWORD},
        )
        assert admin_login.status_code == 200
        assert admin_login.json()["user"]["id"] == DEFAULT_ADMIN_USER_ID
        assert admin_login.json()["user"]["role"] == "admin"

        logout = client.post(
            f"{API_PREFIX}/auth/logout",
            headers={"X-QingJuan-User-Token": token},
        )
        assert logout.status_code == 204
        assert logout.headers["cache-control"] == "no-store"
        expired = client.get(
            f"{API_PREFIX}/auth/session",
            headers={"X-QingJuan-User-Token": token},
        )
        assert expired.status_code == 401
        assert expired.headers["cache-control"] == "no-store"


def test_login_rate_limit_groups_nfkc_equivalent_usernames(user_database: Path) -> None:
    with TestClient(_application()) as client:
        for username in ("admin", "ａｄｍｉｎ", "admin", "ａｄｍｉｎ", "admin"):
            rejected = client.post(
                f"{API_PREFIX}/auth/login",
                json={"username": username, "password": "wrong-password"},
            )
            assert rejected.status_code == 401

        blocked = client.post(
            f"{API_PREFIX}/auth/login",
            json={"username": "ａｄｍｉｎ", "password": "wrong-password"},
        )
        assert blocked.status_code == 429


def test_multi_user_disabled_uses_implicit_admin_shelf(
    user_database: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "0")
    book = _save_book(
        user_database,
        owner_id=DEFAULT_ADMIN_USER_ID,
        book_id="book-local",
        title="本机书籍",
    )
    with TestClient(_application()) as client:
        response = client.get(f"{API_PREFIX}/books")
    assert response.status_code == 200
    assert [item["id"] for item in response.json()] == [book.id]


def test_two_users_are_isolated_across_books_files_tasks_and_logs(user_database: Path) -> None:
    with TestClient(_application()) as client:
        first = _register(client, "reader_one")
        second = _register(client, "reader_two")
        first_headers = {"X-QingJuan-User-Token": first["token"]}
        second_headers = {"X-QingJuan-User-Token": second["token"]}

        first_book = _save_book(
            user_database,
            owner_id=first["user"]["id"],
            book_id="book-first",
            title="甲的书",
        )
        second_book = _save_book(
            user_database,
            owner_id=second["user"]["id"],
            book_id="book-second",
            title="乙的书",
        )
        first_task = _save_task(
            owner_id=first["user"]["id"],
            task_id="task-first",
            book_id=first_book.id,
        )
        second_task = _save_task(
            owner_id=second["user"]["id"],
            task_id="task-second",
            book_id=second_book.id,
        )

        first_books = client.get(f"{API_PREFIX}/books", headers=first_headers)
        second_books = client.get(f"{API_PREFIX}/books", headers=second_headers)
        assert [book["id"] for book in first_books.json()] == [first_book.id]
        assert [book["id"] for book in second_books.json()] == [second_book.id]
        assert "ownerId" not in first_books.text

        assert client.get(f"{API_PREFIX}/books/{second_book.id}", headers=first_headers).status_code == 404
        assert (
            client.get(
                f"{API_PREFIX}/books/{second_book.id}/assets/cover.png",
                headers=first_headers,
            ).status_code
            == 404
        )
        assert (
            client.post(
                f"{API_PREFIX}/books/{second_book.id}/export",
                headers=first_headers,
                json={"format": "txt"},
            ).status_code
            == 404
        )
        assert (
            client.put(
                f"{API_PREFIX}/books/{second_book.id}/progress",
                headers=first_headers,
                json={"chapterIndex": 1},
            ).status_code
            == 404
        )

        first_tasks = client.get(f"{API_PREFIX}/tasks", headers=first_headers)
        assert [task["id"] for task in first_tasks.json()] == [first_task.id]
        assert "ownerId" not in first_tasks.text
        assert (
            client.get(
                f"{API_PREFIX}/tasks/{second_task.id}/logs",
                headers=first_headers,
            ).status_code
            == 404
        )
        assert (
            client.post(
                f"{API_PREFIX}/tasks/{second_task.id}/retry",
                headers=first_headers,
            ).status_code
            == 404
        )
        own_logs = client.get(
            f"{API_PREFIX}/tasks/{first_task.id}/logs",
            headers=first_headers,
        )
        assert own_logs.status_code == 200
        assert own_logs.json()[0]["message"] == "私有任务日志"


def test_pagination_progress_remains_private_and_appears_on_owners_shelf(user_database: Path) -> None:
    with TestClient(_application()) as client:
        first = _register(client, "page_reader_one")
        second = _register(client, "page_reader_two")
        first_headers = {"X-QingJuan-User-Token": first["token"]}
        second_headers = {"X-QingJuan-User-Token": second["token"]}
        book = _save_book(
            user_database, owner_id=first["user"]["id"], book_id="book-pages", title="甲的分页",
        )
        endpoint = f"{API_PREFIX}/books/{book.id}/progress"
        payload = {
            "chapterIndex": 1, "pageIndex": 2, "pageCount": 10,
            "layoutKey": "reader-layout-v1", "contentMode": "original", "characterOffset": 90,
        }
        assert client.put(endpoint, headers=first_headers, json=payload).status_code == 200
        other_write = client.put(endpoint, headers=second_headers, json={**payload, "pageIndex": 5})
        assert other_write.status_code == 404
        assert db.load_reading_progress(book.id, first["user"]["id"]).lastPageIndex == 2
        owner_books = client.get(f"{API_PREFIX}/books", headers=first_headers).json()
        assert owner_books[0]["lastReadPageIndex"] == 2
        assert owner_books[0]["lastReadPageCount"] == 10
        assert client.get(f"{API_PREFIX}/books", headers=second_headers).json() == []


def test_same_link_idempotency_key_creates_separate_jobs_for_different_users(
    user_database: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    store = LinkJobStore()
    started: list[str] = []

    async def fake_run(job_id: str) -> None:
        started.append(job_id)
        store.start(job_id, "开始测试")

    monkeypatch.setattr(main, "LINK_JOB_STORE", store)
    monkeypatch.setattr(main, "_run_link_job", fake_run)
    monkeypatch.setattr(main.app.state, "link_job_tasks", set(), raising=False)
    with TestClient(_application()) as client:
        first = _register(client, "link_reader_one")
        second = _register(client, "link_reader_two")
        first_headers = {"X-QingJuan-User-Token": first["token"], "Idempotency-Key": "same-key"}
        second_headers = {"X-QingJuan-User-Token": second["token"], "Idempotency-Key": "same-key"}
        payload = {
            "mode": "import",
            "payload": {"sourceUrl": "https://example.com/book/1", "bookKind": "长小说", "language": "中文"},
        }
        endpoint = f"{API_PREFIX}/books/link-jobs"
        first_job = client.post(endpoint, headers=first_headers, json=payload)
        repeated = client.post(endpoint, headers=first_headers, json=payload)
        second_job = client.post(endpoint, headers=second_headers, json=payload)
        assert first_job.status_code == repeated.status_code == second_job.status_code == 200
        assert first_job.json()["id"] == repeated.json()["id"]
        assert first_job.json()["id"] != second_job.json()["id"]
        assert set(started) == {first_job.json()["id"], second_job.json()["id"]}
        assert len(started) == 2
        assert client.get(f"{endpoint}/{first_job.json()['id']}", headers=second_headers).status_code == 404


def test_admin_user_management_disables_sessions_and_reports_book_count(
    user_database: Path,
) -> None:
    application = _application(include_admin=True)
    with TestClient(application) as user_client:
        registered = _register(user_client, "managed_user")
    user_id = registered["user"]["id"]
    _save_book(
        user_database,
        owner_id=user_id,
        book_id="book-managed",
        title="受管书籍",
    )

    with TestClient(application) as admin_client:
        login = admin_client.post(
            "/admin/api/login",
            json={"password": ADMIN_PASSWORD},
        )
        csrf = login.json()["csrfToken"]
        headers = {ADMIN_CSRF_HEADER: csrf}
        users = admin_client.get("/admin/api/users")
        managed = next(user for user in users.json() if user["id"] == user_id)
        default_admin = next(user for user in users.json() if user["id"] == DEFAULT_ADMIN_USER_ID)
        assert managed["bookCount"] == 1
        assert managed["role"] == "user"
        assert managed["isDefaultAdmin"] is False
        assert default_admin["role"] == "admin"
        assert default_admin["isDefaultAdmin"] is True
        assert users.headers["cache-control"] == "no-store"
        managed_books = admin_client.get(f"{API_PREFIX}/books")
        assert [book["id"] for book in managed_books.json()] == ["book-managed"]

        role_injection = admin_client.post(
            "/admin/api/users",
            headers=headers,
            json={
                "username": "second_admin",
                "password": USER_PASSWORD,
                "role": "admin",
            },
        )
        assert role_injection.status_code == 422
        cannot_disable_admin = admin_client.patch(
            f"/admin/api/users/{DEFAULT_ADMIN_USER_ID}",
            headers=headers,
            json={"status": "disabled"},
        )
        assert cannot_disable_admin.status_code == 400
        cannot_replace_admin_password = admin_client.put(
            f"/admin/api/users/{DEFAULT_ADMIN_USER_ID}/password",
            headers=headers,
            json={"password": "another-admin-password"},
        )
        assert cannot_replace_admin_password.status_code == 400

        replacement_password = "replacement-user-password"
        changed_password = admin_client.put(
            f"/admin/api/users/{user_id}/password",
            headers=headers,
            json={"password": replacement_password},
        )
        assert changed_password.status_code == 204
        old_session = admin_client.get(
            f"{API_PREFIX}/auth/session",
            headers={"X-QingJuan-User-Token": registered["token"]},
        )
        assert old_session.status_code == 401
        replacement_login = admin_client.post(
            f"{API_PREFIX}/auth/login",
            json={"username": "managed_user", "password": replacement_password},
        )
        assert replacement_login.status_code == 200
        active_user_token = replacement_login.json()["token"]

        disabled = admin_client.patch(
            f"/admin/api/users/{user_id}",
            headers=headers,
            json={"status": "disabled"},
        )
        assert disabled.status_code == 200
        assert disabled.json()["status"] == "disabled"

    with TestClient(application) as user_client:
        rejected = user_client.get(
            f"{API_PREFIX}/auth/session",
            headers={"X-QingJuan-User-Token": active_user_token},
        )
        assert rejected.status_code == 401


def test_admin_user_roles_profiles_passwords_and_last_admin_guard(
    user_database: Path,
) -> None:
    application = _application(include_admin=True)
    with TestClient(application) as user_client:
        first = _register(user_client, "role_candidate")
        second = _register(user_client, "disabled_candidate")

    with TestClient(application) as admin_client:
        login = admin_client.post(
            "/admin/api/login",
            json={"password": ADMIN_PASSWORD},
        )
        csrf_headers = {ADMIN_CSRF_HEADER: login.json()["csrfToken"]}

        renamed_default = admin_client.patch(
            f"/admin/api/users/{DEFAULT_ADMIN_USER_ID}",
            headers=csrf_headers,
            json={"displayName": "主服务器管理员"},
        )
        assert renamed_default.status_code == 200
        assert renamed_default.json()["displayName"] == "主服务器管理员"
        assert renamed_default.json()["role"] == "admin"
        assert renamed_default.json()["isDefaultAdmin"] is True
        cannot_demote_default = admin_client.patch(
            f"/admin/api/users/{DEFAULT_ADMIN_USER_ID}",
            headers=csrf_headers,
            json={"role": "user"},
        )
        assert cannot_demote_default.status_code == 400
        assert "不能降权" in cannot_demote_default.json()["detail"]

        promoted = admin_client.patch(
            f"/admin/api/users/{first['user']['id']}",
            headers=csrf_headers,
            json={"displayName": "值班管理员", "role": "admin"},
        )
        assert promoted.status_code == 200
        assert promoted.json()["displayName"] == "值班管理员"
        assert promoted.json()["role"] == "admin"
        assert promoted.json()["isDefaultAdmin"] is False
        revoked_by_promotion = admin_client.get(
            f"{API_PREFIX}/auth/session",
            headers={"X-QingJuan-User-Token": first["token"]},
        )
        assert revoked_by_promotion.status_code == 401

        promoted_login = admin_client.post(
            f"{API_PREFIX}/auth/login",
            json={"username": "role_candidate", "password": USER_PASSWORD},
        )
        assert promoted_login.status_code == 200
        assert promoted_login.json()["user"]["role"] == "admin"
        replacement_password = "replacement-admin-password"
        password_changed = admin_client.put(
            f"/admin/api/users/{first['user']['id']}/password",
            headers=csrf_headers,
            json={"password": replacement_password},
        )
        assert password_changed.status_code == 204
        password_revoked_session = admin_client.get(
            f"{API_PREFIX}/auth/session",
            headers={"X-QingJuan-User-Token": promoted_login.json()["token"]},
        )
        assert password_revoked_session.status_code == 401
        replacement_login = admin_client.post(
            f"{API_PREFIX}/auth/login",
            json={"username": "role_candidate", "password": replacement_password},
        )
        assert replacement_login.status_code == 200
        assert replacement_login.json()["user"]["role"] == "admin"

        demoted = admin_client.patch(
            f"/admin/api/users/{first['user']['id']}",
            headers=csrf_headers,
            json={"role": "user"},
        )
        assert demoted.status_code == 200
        assert demoted.json()["role"] == "user"
        revoked_by_demotion = admin_client.get(
            f"{API_PREFIX}/auth/session",
            headers={"X-QingJuan-User-Token": replacement_login.json()["token"]},
        )
        assert revoked_by_demotion.status_code == 401

        disabled = admin_client.patch(
            f"/admin/api/users/{second['user']['id']}",
            headers=csrf_headers,
            json={"status": "disabled"},
        )
        assert disabled.status_code == 200
        rejected_disabled_promotion = admin_client.patch(
            f"/admin/api/users/{second['user']['id']}",
            headers=csrf_headers,
            json={"role": "admin", "status": "active"},
        )
        assert rejected_disabled_promotion.status_code == 400
        assert "先启用" in rejected_disabled_promotion.json()["detail"]
        enabled = admin_client.patch(
            f"/admin/api/users/{second['user']['id']}",
            headers=csrf_headers,
            json={"status": "active"},
        )
        assert enabled.status_code == 200
        second_promoted = admin_client.patch(
            f"/admin/api/users/{second['user']['id']}",
            headers=csrf_headers,
            json={"role": "admin"},
        )
        assert second_promoted.status_code == 200

        with sqlite3.connect(db.DB_PATH) as connection:
            connection.execute(
                "UPDATE users SET status = 'disabled' WHERE id = ?",
                (DEFAULT_ADMIN_USER_ID,),
            )
        cannot_disable_last_admin = admin_client.patch(
            f"/admin/api/users/{second['user']['id']}",
            headers=csrf_headers,
            json={"displayName": "不应保存", "status": "disabled"},
        )
        assert cannot_disable_last_admin.status_code == 400
        assert "至少一个" in cannot_disable_last_admin.json()["detail"]
        unchanged_last_admin = db.get_user(second["user"]["id"])
        assert unchanged_last_admin is not None
        assert unchanged_last_admin.displayName == second["user"]["displayName"]
        assert unchanged_last_admin.status == "active"
        cannot_remove_last_admin = admin_client.patch(
            f"/admin/api/users/{second['user']['id']}",
            headers=csrf_headers,
            json={"role": "user"},
        )
        assert cannot_remove_last_admin.status_code == 400
        assert "至少一个" in cannot_remove_last_admin.json()["detail"]
        assert db.get_user(second["user"]["id"]).role == "admin"

    db.init_db()
    default_admin = db.get_user(DEFAULT_ADMIN_USER_ID)
    assert default_admin is not None
    assert default_admin.displayName == "主服务器管理员"
    assert default_admin.role == "admin"
    assert default_admin.status == "active"


def test_legacy_users_table_migrates_roles(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    data_dir = tmp_path / "legacy-user-data"
    data_dir.mkdir()
    monkeypatch.setenv(
        ADMIN_PASSWORD_HASH_ENV,
        hash_admin_password(ADMIN_PASSWORD, salt=b"0123456789abcdef", iterations=100_000),
    )
    monkeypatch.setattr(db, "DATA_DIR", data_dir)
    monkeypatch.setattr(db, "DB_PATH", data_dir / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    monkeypatch.setattr(db, "_SITE_PLUGIN_STATE_CACHE", None)
    with sqlite3.connect(db.DB_PATH) as connection:
        connection.execute(
            """
            CREATE TABLE users (
                id TEXT PRIMARY KEY,
                username TEXT NOT NULL,
                username_key TEXT NOT NULL UNIQUE,
                display_name TEXT NOT NULL,
                password_hash TEXT NOT NULL,
                status TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                last_login_at TEXT
            )
            """
        )
        connection.execute(
            """
            INSERT INTO users (
                id, username, username_key, display_name, password_hash,
                status, created_at, updated_at, last_login_at
            ) VALUES (?, ?, ?, ?, ?, 'active', ?, ?, NULL)
            """,
            (
                "user-legacy",
                "legacy_reader",
                "legacy_reader",
                "旧版用户",
                hash_admin_password(USER_PASSWORD),
                "2030-01-01T00:00:00Z",
                "2030-01-01T00:00:00Z",
            ),
        )

    db.init_db()

    with sqlite3.connect(db.DB_PATH) as connection:
        columns = {row[1] for row in connection.execute("PRAGMA table_info(users)")}
    legacy_user = db.get_user("user-legacy")
    default_admin = db.get_user(DEFAULT_ADMIN_USER_ID)
    assert "role" in columns
    assert legacy_user is not None
    assert legacy_user.role == "user"
    assert legacy_user.isDefaultAdmin is False
    assert default_admin is not None
    assert default_admin.role == "admin"
    assert default_admin.isDefaultAdmin is True


def test_concurrent_role_updates_preserve_one_active_admin(user_database: Path) -> None:
    admin_ids = ("user-concurrent-one", "user-concurrent-two")
    for index, user_id in enumerate(admin_ids, start=1):
        db.create_user(
            user_id=user_id,
            username=f"concurrent_admin_{index}",
            username_key=f"concurrent_admin_{index}",
            display_name=f"并发管理员 {index}",
            password_hash="test-only-password-hash",
        )
        promoted = db.update_user_profile(user_id, role="admin")
        assert promoted is not None
        assert promoted.role == "admin"
    with sqlite3.connect(db.DB_PATH) as connection:
        connection.execute(
            "UPDATE users SET status = 'disabled' WHERE id = ?",
            (DEFAULT_ADMIN_USER_ID,),
        )

    start = Barrier(2)

    def demote(user_id: str) -> str:
        start.wait()
        try:
            db.update_user_profile(user_id, role="user")
        except ValueError as error:
            return str(error)
        return "updated"

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(demote, admin_ids))

    assert results.count("updated") == 1
    assert sum("至少一个" in result for result in results) == 1
    with sqlite3.connect(db.DB_PATH) as connection:
        active_admin_count = connection.execute(
            "SELECT COUNT(*) FROM users WHERE role = 'admin' AND status = 'active'"
        ).fetchone()[0]
    assert active_admin_count == 1


def test_in_memory_import_jobs_enforce_owner_scope() -> None:
    payload = AddBookPayload(
        sourceUrl="https://example.com/book/1",
        bookKind="长小说",
        language="中文",
    )
    link_jobs = LinkJobStore()
    first_link = link_jobs.create("import", payload, "user-first")
    assert link_jobs.get(first_link.id, "user-first").id == first_link.id
    with pytest.raises(KeyError):
        link_jobs.get(first_link.id, "user-second")

    plugin_jobs = SitePluginImportJobStore()
    first_plugin = plugin_jobs.create("fanqie", "user-first")
    second_plugin = plugin_jobs.create("fanqie", "user-second")
    assert plugin_jobs.get(first_plugin.id, "fanqie", "user-first").id == first_plugin.id
    assert plugin_jobs.get(second_plugin.id, "fanqie", "user-second").id == second_plugin.id
    with pytest.raises(KeyError):
        plugin_jobs.get(first_plugin.id, "fanqie", "user-second")


def test_admin_password_rotation_revokes_admin_user_sessions(
    user_database: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    with TestClient(_application()) as client:
        login = client.post(
            f"{API_PREFIX}/auth/login",
            json={"username": "admin", "password": ADMIN_PASSWORD},
        )
        token = login.json()["token"]
        assert login.status_code == 200

        replacement = "replacement-admin-password"
        monkeypatch.setenv(
            ADMIN_PASSWORD_HASH_ENV,
            hash_admin_password(replacement, salt=b"fedcba9876543210", iterations=100_000),
        )
        db.init_db()
        expired = client.get(
            f"{API_PREFIX}/auth/session",
            headers={"X-QingJuan-User-Token": token},
        )
        assert expired.status_code == 401
        replacement_login = client.post(
            f"{API_PREFIX}/auth/login",
            json={"username": "admin", "password": replacement},
        )
        assert replacement_login.status_code == 200


def test_legacy_schema_is_backfilled_to_default_admin(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    data_dir = tmp_path / "legacy"
    data_dir.mkdir()
    database = data_dir / "qingjuan.db"
    with sqlite3.connect(database) as conn:
        conn.execute(
            """
            CREATE TABLE books (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, source_url TEXT NOT NULL,
                book_kind TEXT NOT NULL, language TEXT NOT NULL, status TEXT NOT NULL,
                chapter_count INTEGER NOT NULL, translated INTEGER NOT NULL,
                local_path TEXT NOT NULL, updated_at TEXT NOT NULL, synopsis TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            INSERT INTO books VALUES (
                'legacy-book', '旧书', '', '长小说', '中文', '已下载',
                1, 0, 'library/legacy', '2030-01-01T00:00:00Z', ''
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE reading_progress (
                book_id TEXT PRIMARY KEY, last_chapter_index INTEGER NOT NULL,
                last_read_at TEXT
            )
            """
        )
        conn.execute("INSERT INTO reading_progress VALUES ('legacy-book', 1, NULL)")
        conn.execute(
            """
            CREATE TABLE tasks (
                id TEXT PRIMARY KEY, book_id TEXT NOT NULL, task_type TEXT NOT NULL,
                chapter_indexes TEXT NOT NULL, status TEXT NOT NULL, total_count INTEGER NOT NULL,
                completed_count INTEGER NOT NULL, progress REAL NOT NULL, message TEXT NOT NULL,
                error TEXT, attempts INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            INSERT INTO tasks VALUES (
                'legacy-task', 'legacy-book', 'download', '[1]', 'failed', 1, 0,
                0, '', 'old', 1, '2030-01-01T00:00:00Z', '2030-01-01T00:00:00Z'
            )
            """
        )

    monkeypatch.setattr(db, "DATA_DIR", data_dir)
    monkeypatch.setattr(db, "DB_PATH", database)
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    db.init_db()

    assert db.get_book("legacy-book").ownerId == DEFAULT_ADMIN_USER_ID
    assert db.load_reading_progress("legacy-book").ownerId == DEFAULT_ADMIN_USER_ID
    assert db.get_task("legacy-task").ownerId == DEFAULT_ADMIN_USER_ID
    with sqlite3.connect(database) as conn:
        for table in ("books", "reading_progress", "tasks"):
            columns = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
            assert "owner_id" in columns


def test_connection_token_remains_independent_from_user_token(
    user_database: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    connection_token = "connection-token-with-enough-randomness"
    monkeypatch.setenv(
        "QINGJUAN_AUTH_TOKEN_SHA256",
        hashlib.sha256(connection_token.encode()).hexdigest(),
    )
    application = create_application(
        routers=[auth_router, library_router],
        api_prefix=API_PREFIX,
        authenticate=True,
    )
    connection_headers = {"Authorization": f"Bearer {connection_token}"}
    with TestClient(application) as client:
        missing_connection = client.post(
            f"{API_PREFIX}/auth/register",
            json={
                "username": "gated_user",
                "email": "gated_user@example.test",
                "password": USER_PASSWORD,
            },
        )
        assert missing_connection.status_code == 401
        assert missing_connection.headers["cache-control"] == "no-store"
        registered = client.post(
            f"{API_PREFIX}/auth/register",
            headers=connection_headers,
            json={
                "username": "gated_user",
                "email": "gated_user@example.test",
                "password": USER_PASSWORD,
            },
        )
        assert registered.status_code == 201
        assert client.get(f"{API_PREFIX}/books", headers=connection_headers).status_code == 401
        both_headers = {
            **connection_headers,
            "X-QingJuan-User-Token": registered.json()["token"],
        }
        assert client.get(f"{API_PREFIX}/books", headers=both_headers).status_code == 200


def test_global_admin_access_enforces_role_and_admin_cookie_csrf_with_bearer(
    user_database: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    connection_token = "connection-token-with-enough-randomness"
    monkeypatch.setenv(
        "QINGJUAN_AUTH_TOKEN_SHA256",
        hashlib.sha256(connection_token.encode()).hexdigest(),
    )
    protected_router = APIRouter()

    @protected_router.post("/protected-global-setting")
    async def protected_global_setting(request: Request) -> dict[str, str]:
        access = require_admin_user_access(request)
        return {"userId": access.user.id}

    application = create_application(
        routers=[auth_router, protected_router],
        public_routers=[admin_router],
        api_prefix=API_PREFIX,
        authenticate=True,
    )
    connection_headers = {"Authorization": f"Bearer {connection_token}"}

    with TestClient(application) as client:
        management_login = client.post(
            "/admin/api/login",
            json={"password": ADMIN_PASSWORD},
        )
        assert management_login.status_code == 200
        csrf = management_login.json()["csrfToken"]

        missing_csrf = client.post(
            f"{API_PREFIX}/protected-global-setting",
            headers=connection_headers,
        )
        assert missing_csrf.status_code == 403
        with_csrf = client.post(
            f"{API_PREFIX}/protected-global-setting",
            headers={**connection_headers, ADMIN_CSRF_HEADER: csrf},
        )
        assert with_csrf.status_code == 200
        assert with_csrf.json()["userId"] == DEFAULT_ADMIN_USER_ID

        client.cookies.clear()
        regular = client.post(
            f"{API_PREFIX}/auth/register",
            headers=connection_headers,
            json={
                "username": "settings_reader",
                "email": "settings_reader@example.test",
                "password": USER_PASSWORD,
            },
        )
        regular_headers = {
            **connection_headers,
            "X-QingJuan-User-Token": regular.json()["token"],
        }
        assert (
            client.post(
                f"{API_PREFIX}/protected-global-setting",
                headers=regular_headers,
            ).status_code
            == 403
        )

        regular_user_id = regular.json()["user"]["id"]
        promoted = db.update_user_profile(regular_user_id, role="admin")
        assert promoted is not None
        assert promoted.role == "admin"
        assert (
            client.post(
                f"{API_PREFIX}/protected-global-setting",
                headers=regular_headers,
            ).status_code
            == 401
        )
        promoted_login = client.post(
            f"{API_PREFIX}/auth/login",
            headers=connection_headers,
            json={"username": "settings_reader", "password": USER_PASSWORD},
        )
        promoted_headers = {
            **connection_headers,
            "X-QingJuan-User-Token": promoted_login.json()["token"],
        }
        assert (
            client.post(
                f"{API_PREFIX}/protected-global-setting",
                headers=promoted_headers,
            ).status_code
            == 200
        )

        demoted = db.update_user_profile(regular_user_id, role="user")
        assert demoted is not None
        assert demoted.role == "user"
        assert (
            client.post(
                f"{API_PREFIX}/protected-global-setting",
                headers=promoted_headers,
            ).status_code
            == 401
        )

        admin_login = client.post(
            f"{API_PREFIX}/auth/login",
            headers=connection_headers,
            json={"username": "admin", "password": ADMIN_PASSWORD},
        )
        admin_headers = {
            **connection_headers,
            "X-QingJuan-User-Token": admin_login.json()["token"],
        }
        assert (
            client.post(
                f"{API_PREFIX}/protected-global-setting",
                headers=admin_headers,
            ).status_code
            == 200
        )


def test_shared_catalog_reads_require_login_and_global_writes_require_admin(
    user_database: Path,
) -> None:
    application = create_application(
        routers=[
            auth_router,
            plugins_router,
            sources_router,
            settings_router,
            translation_model_router,
        ],
        api_prefix=API_PREFIX,
    )
    with TestClient(application) as client:
        assert client.get(f"{API_PREFIX}/sources").status_code == 401
        assert client.get(f"{API_PREFIX}/settings").status_code == 401
        assert client.post(f"{API_PREFIX}/translation-model/check").status_code == 401

        regular = _register(client, "catalog_reader")
        regular_headers = {"X-QingJuan-User-Token": regular["token"]}
        assert client.get(f"{API_PREFIX}/sources", headers=regular_headers).status_code == 200
        assert client.get(f"{API_PREFIX}/settings", headers=regular_headers).status_code == 200
        assert (
            client.post(
                f"{API_PREFIX}/translation-model/check",
                headers=regular_headers,
            ).status_code
            == 200
        )

        initially_enabled = db.is_site_plugin_enabled("fanqie")
        denied_toggle = client.put(
            f"{API_PREFIX}/plugins/fanqie",
            headers=regular_headers,
            json={"enabled": not initially_enabled},
        )
        assert denied_toggle.status_code == 403
        assert db.is_site_plugin_enabled("fanqie") is initially_enabled
        denied_import = client.post(
            f"{API_PREFIX}/sources/import-text",
            headers=regular_headers,
            json={"content": "[]"},
        )
        assert denied_import.status_code == 403

        admin_login = client.post(
            f"{API_PREFIX}/auth/login",
            json={"username": "admin", "password": ADMIN_PASSWORD},
        )
        admin_headers = {"X-QingJuan-User-Token": admin_login.json()["token"]}
        allowed_toggle = client.put(
            f"{API_PREFIX}/plugins/fanqie",
            headers=admin_headers,
            json={"enabled": not initially_enabled},
        )
        assert allowed_toggle.status_code == 200
        assert db.is_site_plugin_enabled("fanqie") is (not initially_enabled)
