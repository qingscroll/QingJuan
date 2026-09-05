from __future__ import annotations

import httpx
import pytest

from app import scraper
from app.models import AddBookPayload, PreviewResponse, TranslationSettings


@pytest.fixture(autouse=True)
def enabled_plugins(monkeypatch):
    monkeypatch.setattr(scraper, "is_site_plugin_enabled", lambda _plugin_id: True)


@pytest.mark.asyncio
async def test_failed_chapter_download_preserves_existing_text(tmp_path):
    chapter_path = tmp_path / "chapter.txt"
    chapter_path.write_text("有效正文", encoding="utf-8")
    async with httpx.AsyncClient(
        transport=httpx.MockTransport(lambda request: httpx.Response(503, request=request))
    ) as client:
        with pytest.raises(httpx.HTTPStatusError):
            await scraper._download_single_chapter(
                client,
                tmp_path,
                1,
                {"file_name": chapter_path.name, "title": "第一章", "url": "https://example.com/1"},
            )
    assert chapter_path.read_text(encoding="utf-8") == "有效正文"


@pytest.mark.asyncio
async def test_full_import_keeps_failed_chapter_uncached_and_continues(tmp_path, monkeypatch):
    def reply(request):
        if request.url.path == "/1":
            return httpx.Response(503, request=request)
        return httpx.Response(200, text="<p>第二章有效正文</p>", request=request)

    monkeypatch.setattr(
        scraper,
        "_build_http_client",
        lambda: httpx.AsyncClient(transport=httpx.MockTransport(reply)),
    )
    monkeypatch.setattr(scraper, "_load_runtime_settings", TranslationSettings)
    preview = PreviewResponse(
        title="测试小说",
        chapterCount=2,
        chapters=[
            {"title": "第一章", "url": "https://example.com/1"},
            {"title": "第二章", "url": "https://example.com/2"},
        ],
    )
    result = await scraper.download_book(
        AddBookPayload(sourceUrl="https://example.com/book", bookKind="长小说", language="中文"),
        preview,
        tmp_path,
    )
    chapters = scraper.load_manifest(result.local_path)["chapters"]
    assert chapters[0]["downloaded"] is False
    assert chapters[0]["download_error"]
    assert not (result.local_path / chapters[0]["file_name"]).exists()
    assert chapters[1]["downloaded"] is True
    assert (result.local_path / chapters[1]["file_name"]).read_text(encoding="utf-8") == "第二章有效正文"


@pytest.mark.asyncio
async def test_empty_chapter_response_does_not_replace_valid_text(tmp_path):
    chapter_path = tmp_path / "chapter.txt"
    chapter_path.write_text("有效正文", encoding="utf-8")
    async with httpx.AsyncClient(
        transport=httpx.MockTransport(lambda request: httpx.Response(200, text="", request=request))
    ) as client:
        with pytest.raises(ValueError, match="正文"):
            await scraper._download_single_chapter(
                client,
                tmp_path,
                1,
                {"file_name": chapter_path.name, "url": "https://example.com/1"},
            )
    assert chapter_path.read_text(encoding="utf-8") == "有效正文"


@pytest.mark.asyncio
async def test_atomic_chapter_publish_failure_preserves_previous_text(tmp_path, monkeypatch):
    chapter_path = tmp_path / "chapter.txt"
    chapter_path.write_text("有效正文", encoding="utf-8")

    def fail_replace(*_args):
        raise OSError("模拟文件发布失败")

    monkeypatch.setattr(scraper.os, "replace", fail_replace)
    async with httpx.AsyncClient(
        transport=httpx.MockTransport(
            lambda request: httpx.Response(200, text="<p>新正文</p>", request=request)
        )
    ) as client:
        with pytest.raises(OSError, match="发布失败"):
            await scraper._download_single_chapter(
                client,
                tmp_path,
                1,
                {"file_name": chapter_path.name, "url": "https://example.com/1"},
            )
    assert chapter_path.read_text(encoding="utf-8") == "有效正文"
    assert list(tmp_path.iterdir()) == [chapter_path]
