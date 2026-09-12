from __future__ import annotations

import asyncio
import sqlite3
from contextlib import contextmanager

import pytest
import test_plugin_packages

from app import db
from app.plugin_system import packages, repository, runtime
from app.plugin_system.maintenance import inspect_installed_plugin, rollback_plugin
from app.site_plugins import get_site_plugin

isolated_plugins = test_plugin_packages.isolated_plugins
make_package = test_plugin_packages.make_package


def test_update_preserves_previous_version_for_restart_and_explicit_rollback():
    packages.install_package(make_package())
    db.save_site_plugin_enabled("example-novel", False)
    packages.install_package(make_package("1.1.0"), replace=True)
    packages.clear_loaded_plugins()
    packages.load_installed_plugins()
    report = inspect_installed_plugin("example-novel")
    assert report.version == "1.1.0"
    assert report.rollbackVersion == "1.0.0"
    assert report.compatible
    plugin = rollback_plugin("example-novel", expected_version=report.version, expected_sha256=report.sha256)
    assert plugin.version == "1.0.0"
    assert not db.is_site_plugin_enabled(plugin.id)
    assert inspect_installed_plugin(plugin.id).rollbackVersion == "1.1.0"
    packages.clear_loaded_plugins()
    packages.load_installed_plugins()
    assert get_site_plugin(plugin.id).version == "1.0.0"


def test_failed_runtime_or_persistence_update_preserves_current_and_history(monkeypatch):
    packages.install_package(make_package())
    packages.install_package(make_package("1.1.0"), replace=True)
    with pytest.raises(packages.PluginPackageError):
        packages.install_package(
            make_package("1.2.0", code="raise RuntimeError('private-secret')"), replace=True
        )
    with monkeypatch.context() as patch:

        def failed(*args, **kwargs):
            raise OSError("private-database-location")

        patch.setattr(repository, "save_package", failed)
        with pytest.raises(packages.PluginPackageError):
            packages.install_package(make_package("1.2.0"), replace=True)
    report = inspect_installed_plugin("example-novel")
    assert report.version == "1.1.0"
    assert report.rollbackVersion == "1.0.0"
    assert "private" not in report.model_dump_json()


def test_rollback_is_bound_to_reviewed_version_and_rejects_tampered_previous_package():
    packages.install_package(make_package())
    packages.install_package(make_package("1.1.0"), replace=True)
    report = inspect_installed_plugin("example-novel")
    with pytest.raises(packages.PluginPackageError) as error:
        rollback_plugin("example-novel", expected_version="1.0.0", expected_sha256=report.sha256)
    assert error.value.status_code == 409
    with db.get_connection() as conn:
        conn.execute("UPDATE site_plugin_package_history SET sha256='changed'")
    with pytest.raises(packages.PluginPackageError):
        rollback_plugin("example-novel", expected_version=report.version, expected_sha256=report.sha256)
    assert get_site_plugin("example-novel").version == "1.1.0"


@pytest.mark.asyncio
async def test_running_plugin_call_blocks_update_rollback_and_uninstall_until_completion():
    code = """
import asyncio
entered = asyncio.Event()
finish = asyncio.Event()
async def preview(url, context):
    entered.set()
    await finish.wait()
    return {"title": "作品", "chapters": [{"title": "第一章", "url": "/one"}]}
"""
    packages.install_package(make_package(capabilities=["preview"]))
    plugin = packages.install_package(
        make_package("1.1.0", code=code, capabilities=["preview"]), replace=True
    )
    task = asyncio.create_task(runtime.preview_plugin(plugin, "https://novels.example.test/book"))
    await plugin.runtime.entered.wait()
    report = inspect_installed_plugin(plugin.id)
    try:
        for action in (
            lambda: packages.install_package(make_package("1.2.0"), replace=True),
            lambda: rollback_plugin(
                plugin.id, expected_version=report.version, expected_sha256=report.sha256
            ),
            lambda: packages.uninstall_package(plugin.id),
        ):
            with pytest.raises(packages.PluginPackageError) as error:
                action()
            assert error.value.status_code == 409
    finally:
        plugin.runtime.finish.set()
        await task
    assert (
        rollback_plugin(plugin.id, expected_version=report.version, expected_sha256=report.sha256).version
        == "1.0.0"
    )


def test_self_check_verifies_runtime_contract_without_reexecuting_plugin_code():
    code = """
initialized = 1
async def preview(url, context):
    raise RuntimeError("self check must not contact the site")
"""
    plugin = packages.install_package(make_package(code=code, capabilities=["preview"]))
    report = inspect_installed_plugin(plugin.id)
    assert report.compatible
    assert plugin.runtime.initialized == 1
    plugin.runtime.preview = lambda: None
    failed = inspect_installed_plugin(plugin.id)
    assert not failed.compatible
    assert any(check.code == "runtime" and check.status == "failed" for check in failed.checks)


def test_uninstall_removes_package_history_but_keeps_user_state():
    packages.install_package(make_package())
    packages.install_package(make_package("1.1.0"), replace=True)
    packages.uninstall_package("example-novel")
    with db.get_connection() as conn:
        assert conn.execute("SELECT count(*) FROM site_plugin_package_history").fetchone()[0] == 0
        assert conn.execute("SELECT count(*) FROM users").fetchone()[0] == 1


@pytest.mark.parametrize("failure", ["publish", "commit"])
@pytest.mark.parametrize("operation", ["update", "rollback", "uninstall"])
def test_database_and_runtime_both_rollback_if_publication_or_commit_fails(monkeypatch, failure, operation):
    packages.install_package(make_package())
    old = packages.install_package(make_package("1.1.0"), replace=True)
    before = repository.read_package(old.id)
    report = inspect_installed_plugin(old.id)
    previous = repository.read_package(old.id, previous=True)
    original_publish = packages.replace_installed_site_plugins
    original_connection = db.get_connection
    called = False

    def fail_publication(plugins):
        nonlocal called
        original_publish(plugins)
        if not called:
            called = True
            raise RuntimeError("private-runtime-error")

    @contextmanager
    def fail_commit():
        with original_connection() as conn:
            yield conn
            # Only the write transaction should fail, after the registry changes.
            if conn.in_transaction:
                raise sqlite3.OperationalError("private-commit-error")

    with monkeypatch.context() as patch:
        if failure == "publish":
            patch.setattr(packages, "replace_installed_site_plugins", fail_publication)
        else:
            patch.setattr(db, "get_connection", fail_commit)
        with pytest.raises(packages.PluginPackageError):
            if operation == "update":
                packages.install_package(make_package("1.2.0"), replace=True)
            elif operation == "rollback":
                rollback_plugin(old.id, expected_version=report.version, expected_sha256=report.sha256)
            else:
                packages.uninstall_package(old.id)
    assert get_site_plugin(old.id) is old
    assert repository.read_package(old.id) == before
    assert repository.read_package(old.id, previous=True) == previous


def test_a_running_task_blocks_changes_between_plugin_calls():
    from app.models import BookRecord, TaskRecord

    packages.install_package(make_package())
    db.save_book(
        BookRecord(
            id="active-book",
            title="作品",
            sourceUrl="https://novels.example.test/book",
            bookKind="长小说",
            language="中文",
            status="已下载",
            chapterCount=1,
            translated=False,
            localPath="library/active",
        )
    )
    db.save_task(
        TaskRecord(
            id="running-task",
            bookId="active-book",
            taskType="download",
            chapterIndexes=[0],
            status="running",
            totalCount=1,
            createdAt="2026-09-11",
            updatedAt="2026-09-11",
        )
    )
    with pytest.raises(packages.PluginPackageError) as error:
        packages.install_package(make_package("1.1.0"), replace=True)
    assert error.value.status_code == 409
    with db.get_connection() as conn:
        conn.execute("UPDATE tasks SET status='paused'")
    assert packages.install_package(make_package("1.1.0"), replace=True).version == "1.1.0"


def test_running_link_import_blocks_parser_change():
    from app.link_job_repository import PersistentLinkJobStore
    from app.models import AddBookPayload

    packages.install_package(make_package())
    store = PersistentLinkJobStore()
    job = store.create(
        "import",
        AddBookPayload(sourceUrl="https://novels.example.test/book", bookKind="长小说", language="中文"),
    )
    store.start(job.id, "解析中")
    with pytest.raises(packages.PluginPackageError) as error:
        packages.uninstall_package("example-novel")
    assert error.value.status_code == 409
    store.fail(job.id, "暂不可用")
    packages.uninstall_package("example-novel")


@pytest.mark.asyncio
async def test_a_stale_handler_after_update_cannot_execute_the_retired_version():
    old = packages.install_package(make_package())
    packages.install_package(make_package("1.1.0"), replace=True)
    with pytest.raises(ValueError):
        await runtime.preview_plugin(old, "https://novels.example.test/book")


def test_only_one_previous_version_is_retained():
    packages.install_package(make_package())
    packages.install_package(make_package("1.1.0"), replace=True)
    packages.install_package(make_package("1.2.0"), replace=True)
    assert inspect_installed_plugin("example-novel").rollbackVersion == "1.1.0"
    with db.get_connection() as conn:
        assert conn.execute("SELECT count(*) FROM site_plugin_package_history").fetchone()[0] == 1


def test_maintenance_endpoints_require_admin_cookie_and_csrf(monkeypatch):
    from fastapi.testclient import TestClient

    from app.admin_auth import (
        ADMIN_CSRF_HEADER,
        ADMIN_SESSION_COOKIE,
        create_admin_session,
        hash_admin_password,
    )
    from app.api.plugin_packages import router
    from app.application import create_application

    monkeypatch.setenv("QINGJUAN_ADMIN_PASSWORD_HASH", hash_admin_password("test-admin-password"))
    monkeypatch.setenv("QINGJUAN_ADMIN_SESSION_SECRET", "78" * 32)
    packages.install_package(make_package())
    packages.install_package(make_package("1.1.0"), replace=True)
    application = create_application(routers=[router], api_prefix="/api/v1")
    session = create_admin_session()
    with TestClient(application) as client:
        endpoint = "/api/v1/plugins/example-novel"
        assert (
            client.post(
                endpoint + "/check", headers={"Authorization": "Bearer administrator-user-session"}
            ).status_code
            == 401
        )
        client.cookies.set(ADMIN_SESSION_COOKIE, session.token)
        assert client.post(endpoint + "/check").status_code == 403
        headers = {ADMIN_CSRF_HEADER: session.csrf_token}
        checked = client.post(endpoint + "/check", headers=headers)
        assert checked.status_code == 200
        report = checked.json()
        assert report["compatible"] is True
        assert report["rollbackVersion"] == "1.0.0"
        assert checked.headers["Cache-Control"] == "no-store"
        assert client.get(endpoint + "/maintenance", headers=headers).status_code == 200
        payload = {"expectedVersion": report["version"], "expectedSha256": report["sha256"]}
        assert client.post(endpoint + "/rollback", json=payload).status_code == 403
        assert client.post(endpoint + "/rollback", json=payload, headers=headers).json()["version"] == "1.0.0"
        assert client.post(endpoint + "/rollback", json=payload, headers=headers).status_code == 409
