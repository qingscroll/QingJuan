from __future__ import annotations

import asyncio
from pathlib import Path

import httpx
import pytest
from test_plugin_packages import isolated_plugins as isolated_plugins
from test_plugin_packages import make_package

from app import db, scraper
from app.models import AddBookPayload
from app.plugin_system import packages, repository, runtime
from app.plugin_system.sdk import PluginContext
from app.site_plugins import get_site_plugin


@pytest.mark.asyncio
async def test_manga_plugin_uses_image_download_contract():
    code = """
async def preview(url, context):
    return {"title": "漫画", "chapters": [{"title": "第一话", "url": "/chapter/1"}]}
async def chapter(url, context):
    return {"imageUrls": ["https://cdn.example.test/1.jpg", "https://cdn.example.test/2.jpg"]}
"""
    packages.install_package(
        make_package(
            code=code,
            category="manga",
            bookKinds=["漫画"],
            capabilities=["preview", "chapter"],
            networkDomains=["cdn.example.test"],
        )
    )
    async with httpx.AsyncClient() as client:
        result = await scraper._fetch_chapter_data(client, "https://novels.example.test/chapter/1", "第一话")
    assert result.image_urls == ["https://cdn.example.test/1.jpg", "https://cdn.example.test/2.jpg"]
    assert result.text


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "result",
    [
        {"title": "作品", "chapters": [{"title": "第一章", "url": "https://outside.example.test/chapter"}]},
        {"title": "作品", "chapters": [{"title": "第一章", "url": "http://127.0.0.1/private"}]},
        {"title": "作品", "chapters": [{"title": "第一章", "url": "file:///secret"}]},
        {
            "title": "作品",
            "cover": "https://user:secret@novels.example.test/img",
            "chapters": [{"title": "章", "url": "/a"}],
        },
        {"title": "作品", "chapters": [{"title": "第一章", "url": "/a"}, {"title": "第二章", "url": "/a"}]},
    ],
)
async def test_output_validation_rejects_bad_urls_and_duplicate_chapters(result):
    code = f"async def preview(url, context):\n    return {result!r}"
    plugin = packages.install_package(make_package(code=code, capabilities=["preview"]))
    with pytest.raises(ValueError, match="不符合规范"):
        await runtime.preview_plugin(plugin, "https://novels.example.test/book/1")


@pytest.mark.asyncio
async def test_context_checks_redirect_domain_before_following_and_does_not_forward_credentials():
    plugin = packages.install_package(make_package())
    requested = []

    def respond(request):
        requested.append(request)
        return httpx.Response(302, headers={"location": "https://other.example.test/private"})

    async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
        context = PluginContext(plugin, "https://novels.example.test/book/1", client)
        with pytest.raises(ValueError, match="网络域名"):
            await context.get_text("/redirect")
    assert len(requested) == 1
    assert "authorization" not in requested[0].headers
    assert "cookie" not in requested[0].headers


@pytest.mark.asyncio
async def test_runtime_timeout_cancels_cooperative_plugin(monkeypatch):
    code = """
import asyncio
cancelled = False
async def preview(url, context):
    global cancelled
    try:
        await asyncio.sleep(10)
    finally:
        cancelled = True
"""
    plugin = packages.install_package(make_package(code=code, capabilities=["preview"]))
    monkeypatch.setattr(runtime, "CALL_TIMEOUT_SECONDS", 0.01)
    with pytest.raises(ValueError, match="超时"):
        await runtime.preview_plugin(plugin, "https://novels.example.test/book/1")
    assert plugin.runtime.cancelled


@pytest.mark.asyncio
async def test_caller_cancellation_propagates(monkeypatch):
    plugin = packages.install_package(
        make_package(
            code="""
import asyncio
async def preview(url, context):
    await asyncio.sleep(60)
""",
            capabilities=["preview"],
        )
    )
    task = asyncio.create_task(runtime.preview_plugin(plugin, "https://novels.example.test/book/1"))
    await asyncio.sleep(0)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task


def test_failed_disk_write_keeps_old_runtime_and_package(monkeypatch):
    packages.install_package(make_package())

    def fail(*args):
        raise OSError("private-storage-path")

    monkeypatch.setattr(repository, "save_package", fail)
    with pytest.raises(packages.PluginPackageError, match="保存失败"):
        packages.install_package(make_package("1.1.0"), replace=True)
    assert get_site_plugin("example-novel").version == "1.0.0"
    packages.load_installed_plugins()
    assert get_site_plugin("example-novel").version == "1.0.0"


@pytest.mark.asyncio
async def test_corrupt_package_is_visible_blocked_and_repairable():
    packages.install_package(make_package())
    with db.get_connection() as connection:
        connection.execute("UPDATE site_plugin_packages SET sha256 = 'corrupted'")
    packages.load_installed_plugins()
    broken = get_site_plugin("example-novel")
    assert broken.load_error
    with pytest.raises(ValueError, match="加载失败"):
        await runtime.preview_plugin(broken, "https://novels.example.test/book/1")
    packages.install_package(make_package(), replace=True)
    assert get_site_plugin("example-novel").load_error is None


def test_separate_database_does_not_inherit_installed_plugins(monkeypatch, tmp_path):
    packages.install_package(make_package())
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "another.db")
    db.init_db()
    packages.load_installed_plugins()
    assert get_site_plugin("example-novel") is None


def test_inspection_does_not_execute_top_level_code():
    manifest, _ = packages.inspect_package(make_package(code="raise RuntimeError('never-execute')"))
    assert manifest.id == "example-novel"
    assert get_site_plugin(manifest.id) is None


@pytest.mark.asyncio
async def test_aggregate_search_returns_completed_results_and_cancels_slow_plugins(monkeypatch):
    from app.api import plugin_packages
    from app.models import BookSourceSearchPayload, BuiltinSiteSearchResult

    packages.install_package(make_package(id="fast-plugin", domains=["fast.example.test"]))
    packages.install_package(make_package(id="slow-plugin", domains=["slow.example.test"]))
    cancelled = asyncio.Event()

    async def search(plugin, keyword, limit):
        if plugin.id == "fast-plugin":
            return [BuiltinSiteSearchResult(title="结果", sourceUrl="https://fast.example.test/book/1")]
        try:
            await asyncio.sleep(10)
        finally:
            cancelled.set()

    monkeypatch.setattr(plugin_packages, "search_plugin", search)
    monkeypatch.setattr(plugin_packages, "require_user_access", lambda _: None)
    monkeypatch.setattr(plugin_packages, "SEARCH_TIMEOUT_SECONDS", 0.01)
    result = await plugin_packages.search_installed_plugins(BookSourceSearchPayload(keyword="作品"), object())
    assert len(result) == 1
    assert cancelled.is_set()


@pytest.mark.parametrize(
    "changes", [{"schemaVersion": True}, {"apiVersion": True}, {"defaultEnabled": "false"}]
)
def test_manifest_version_and_flags_are_strict(changes):
    with pytest.raises(packages.PluginPackageError):
        packages.inspect_package(make_package(**changes))


@pytest.mark.asyncio
async def test_shipped_offline_example_is_installable_and_readable():
    import io
    import zipfile

    directory = Path(__file__).resolve().parents[2] / "examples/plugins/demo-novel"
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as archive:
        for name in ("manifest.json", "plugin.py"):
            archive.writestr(name, (directory / name).read_bytes())
    plugin = packages.install_package(data.getvalue())
    results = await runtime.search_plugin(plugin, "青卷", 10)
    preview = await scraper.preview_from_url(
        AddBookPayload(sourceUrl=results[0].sourceUrl, bookKind="长小说", language="中文")
    )
    assert preview.chapterCount == 2
    for chapter in preview.chapters:
        text, _ = await runtime.chapter_plugin(plugin, chapter.url)
        assert len(text) > 10
