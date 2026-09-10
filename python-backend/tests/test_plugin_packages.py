from __future__ import annotations

import io
import json
import zipfile

import httpx
import pytest
from fastapi.testclient import TestClient

from app import db, scraper
from app.models import AddBookPayload
from app.plugin_system import packages
from app.site_plugins import get_site_plugin, resolve_site_plugin


def make_package(version="1.0.0", code=None, **changes):
    manifest = {
        "schemaVersion": 1,
        "apiVersion": 1,
        "id": "example-novel",
        "name": "示例小说",
        "version": version,
        "author": "测试作者",
        "description": "测试外部解析器",
        "category": "novel",
        "domains": ["novels.example.test"],
        "bookKinds": ["长小说"],
        "capabilities": ["preview", "chapter", "search", "on_demand"],
        "entrypoint": "plugin.py",
    }
    manifest.update(changes)
    code = (
        code
        if code is not None
        else """
async def preview(url, context):
    return {"title": "外部作品", "chapters": [{"title": "第一章", "url": "/chapter/1"}]}

async def chapter(url, context):
    return {"text": "这是从独立插件取得的章节正文。"}

async def search(keyword, limit, context):
    return [{"title": keyword, "sourceUrl": "/book/1"}]
"""
    )
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False))
        archive.writestr("plugin.py", code)
    return output.getvalue()


@pytest.fixture(autouse=True)
def isolated_plugins(monkeypatch, tmp_path):
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    db.init_db()
    packages.load_installed_plugins()
    yield
    packages.clear_loaded_plugins()


@pytest.mark.asyncio
async def test_imported_package_runs_preview_chapter_and_search():
    plugin = packages.install_package(make_package())
    assert plugin.origin == "installed"
    assert resolve_site_plugin("https://novels.example.test/book/1").id == plugin.id
    preview = await scraper.preview_from_url(
        AddBookPayload(sourceUrl="https://novels.example.test/book/1", bookKind="长小说", language="中文")
    )
    assert preview.title == "外部作品"
    assert preview.chapterCount == 1
    assert preview.chapters[0].url == "https://novels.example.test/chapter/1"
    async with httpx.AsyncClient() as client:
        chapter = await scraper._fetch_chapter_data(client, preview.chapters[0].url)
    assert chapter.text == "这是从独立插件取得的章节正文。"
    from app.plugin_system.runtime import search_plugin

    results = await search_plugin(plugin, "独立搜索", 5)
    assert results[0].title == "独立搜索"
    assert results[0].sourceUrl == "https://novels.example.test/book/1"


def test_update_requires_explicit_replace_and_new_version_and_preserves_disabled_state():
    packages.install_package(make_package())
    db.save_site_plugin_enabled("example-novel", False)
    with pytest.raises(packages.PluginPackageError, match="已安装"):
        packages.install_package(make_package("1.1.0"))
    with pytest.raises(packages.PluginPackageError, match="更高"):
        packages.install_package(make_package(), replace=True)
    packages.install_package(make_package("1.1.0"), replace=True)
    assert get_site_plugin("example-novel").version == "1.1.0"
    assert not db.is_site_plugin_enabled("example-novel")
    packages.clear_loaded_plugins()
    packages.load_installed_plugins()
    assert get_site_plugin("example-novel").version == "1.1.0"
    assert not db.is_site_plugin_enabled("example-novel")


def test_invalid_update_preserves_active_and_persisted_package():
    packages.install_package(make_package())
    with pytest.raises(packages.PluginPackageError):
        packages.install_package(
            make_package("2.0.0", code="raise RuntimeError('private-secret')"), replace=True
        )
    assert get_site_plugin("example-novel").version == "1.0.0"
    packages.clear_loaded_plugins()
    packages.load_installed_plugins()
    assert get_site_plugin("example-novel").version == "1.0.0"


@pytest.mark.parametrize(
    "changes",
    [
        {"id": "fanqie"},
        {"apiVersion": 99},
        {"version": "latest"},
        {"domains": ["fanqienovel.com"]},
        {"domains": ["https://example.test"]},
        {"domains": []},
        {"capabilities": ["preview", "account_login"]},
        {"entrypoint": "../plugin.py"},
        {"unknownField": True},
    ],
)
def test_rejects_invalid_or_conflicting_manifests(changes):
    with pytest.raises(packages.PluginPackageError):
        packages.install_package(make_package(**changes))
    assert get_site_plugin("example-novel") is None


def test_rejects_archive_traversal_and_duplicate_entries():
    for filename in ("../outside.py", "plugin.py"):
        output = io.BytesIO(make_package())
        with zipfile.ZipFile(output, "a") as archive:
            archive.writestr(filename, "pass")
        with pytest.raises(packages.PluginPackageError):
            packages.install_package(output.getvalue())


@pytest.mark.asyncio
async def test_disabled_plugin_does_not_fall_back_or_execute():
    packages.install_package(make_package())
    db.save_site_plugin_enabled("example-novel", False)
    with pytest.raises(ValueError, match="停用"):
        await scraper.preview_from_url(
            AddBookPayload(sourceUrl="https://novels.example.test/book/1", bookKind="长小说", language="中文")
        )


def test_uninstall_removes_persistence_but_never_builtins():
    packages.install_package(make_package())
    packages.uninstall_package("example-novel")
    assert get_site_plugin("example-novel") is None
    packages.load_installed_plugins()
    assert get_site_plugin("example-novel") is None
    with pytest.raises(packages.PluginPackageError):
        packages.uninstall_package("fanqie")
    assert get_site_plugin("fanqie") is not None


@pytest.mark.asyncio
async def test_runtime_errors_are_sanitized_and_empty_content_rejected():
    for code in (
        "async def preview(url, context):\n    raise RuntimeError('secret-cookie')",
        "async def preview(url, context):\n    return {'title': '', 'chapters': []}",
    ):
        packages.install_package(make_package(code=code, capabilities=["preview"]))
        with pytest.raises(ValueError) as error:
            await scraper.preview_from_url(
                AddBookPayload(
                    sourceUrl="https://novels.example.test/book/1", bookKind="长小说", language="中文"
                )
            )
        assert "secret-cookie" not in str(error.value)
        packages.uninstall_package("example-novel")


def test_management_api_requires_admin_session_csrf_and_returns_public_metadata(monkeypatch):
    from app.admin_auth import ADMIN_PASSWORD_HASH_ENV, ADMIN_SESSION_SECRET_ENV, hash_admin_password
    from app.api.routers import admin_router, plugins_router
    from app.application import create_application

    monkeypatch.setenv(
        ADMIN_PASSWORD_HASH_ENV, hash_admin_password("test-admin-password", iterations=100_000)
    )
    monkeypatch.setenv(ADMIN_SESSION_SECRET_ENV, "ab" * 32)
    application = create_application(
        routers=[plugins_router], public_routers=[admin_router], api_prefix="/api/v1"
    )
    with TestClient(application) as client:
        files = {"file": ("example.qjplugin", make_package(), "application/zip")}
        assert client.post("/api/v1/plugins/import", files=files).status_code == 401
        login = client.post("/admin/api/login", json={"password": "test-admin-password"})
        assert login.status_code == 200
        assert client.post("/api/v1/plugins/import", files=files).status_code == 403
        # The exact server header is part of the existing admin-session contract.
        from app.admin_auth import ADMIN_CSRF_HEADER

        headers = {ADMIN_CSRF_HEADER: login.json()["csrfToken"]}
        response = client.post("/api/v1/plugins/import", files=files, headers=headers)
        assert response.status_code == 201, response.text
        assert response.json()["origin"] == "installed"
        assert "plugin.py" not in response.text
        assert client.post("/api/v1/plugins/import", files=files, headers=headers).status_code == 409
        search = client.post("/api/v1/plugins/search", json={"keyword": "作品", "limit": 10}, headers=headers)
        assert search.status_code == 200, search.text
        assert search.json()[0]["sourceName"] == "示例小说"
        assert client.delete("/api/v1/plugins/example-novel").status_code == 403
        assert client.delete("/api/v1/plugins/example-novel", headers=headers).status_code == 204
