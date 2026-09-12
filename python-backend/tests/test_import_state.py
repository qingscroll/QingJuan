from __future__ import annotations

from types import SimpleNamespace

import httpx
import pytest

from app import db, main
from app.models import AddBookPayload, BookRecord, BookSourceRecord, PreviewResponse
from app.scraper_network_security import ScraperNetworkSecurityError


@pytest.mark.asyncio
@pytest.mark.parametrize("downloaded_count, expected", [(0, "待处理"), (1, "解析中"), (2, "已下载")])
async def test_full_import_reports_actual_downloaded_chapter_state(
    monkeypatch: pytest.MonkeyPatch, tmp_path, downloaded_count: int, expected: str,
) -> None:
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    monkeypatch.setattr(db, "_SITE_PLUGIN_STATE_CACHE", None)
    db.init_db()
    preview = PreviewResponse(
        title="部分下载作品", chapterCount=2, bookKind="长小说",
        chapters=[
            {"title": "第一章", "url": "https://example.com/chapter/1"},
            {"title": "第二章", "url": "https://example.com/chapter/2"},
        ],
    )

    async def fake_download(payload, metadata, book_dir):
        book_dir.mkdir(parents=True)
        chapters = []
        for index in range(1, 3):
            downloaded = index <= downloaded_count
            filename = f"{index:04d}.txt"
            if downloaded:
                (book_dir / filename).write_text(f"第 {index} 章真实正文", encoding="utf-8")
            chapters.append({
                "index": index, "title": f"第 {index} 章", "file_name": filename,
                "url": f"https://example.com/chapter/{index}", "downloaded": downloaded,
                **({"download_error": "上游未返回可用正文"} if not downloaded else {}),
            })
        main.save_manifest(book_dir, {"title": metadata.title, "chapters": chapters})
        return SimpleNamespace(
            title=metadata.title, chapters=chapters, local_path=book_dir, synopsis="", cover=None,
        )

    saved: list[BookRecord] = []
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "LIBRARY_ROOT", tmp_path / "library")
    monkeypatch.setattr(main, "download_book", fake_download)
    monkeypatch.setattr(main, "save_book", lambda book: saved.append(book.model_copy(deep=True)))
    result = await main._create_imported_book(
        AddBookPayload(sourceUrl="https://example.com/book/1", bookKind="长小说", language="中文"),
        preview,
    )
    assert result.status == expected
    assert saved[-1].status == expected
    assert result.chapterCount == 2
    # Lists also repair an old optimistic database status using the actual manifest.
    stale = result.model_copy(update={"status": "已下载"})
    assert main._hydrate_book_record(stale).status == expected


@pytest.mark.asyncio
@pytest.mark.parametrize("operation", ["import", "search"])
async def test_source_requests_reject_private_destinations_without_browser_fallback(
    monkeypatch: pytest.MonkeyPatch, operation: str,
) -> None:
    # Old unprotected clients use a local fixture instead of reaching a real network.
    original_client = httpx.AsyncClient

    def client_with_default_fixture(**kwargs):
        kwargs.setdefault("transport", httpx.MockTransport(lambda _: httpx.Response(200, text="[]")))
        return original_client(**kwargs)

    async def reject_browser(*args, **kwargs):
        pytest.fail("被网络安全边界拒绝的地址不能通过浏览器重试")

    monkeypatch.setattr(httpx, "AsyncClient", client_with_default_fixture)
    monkeypatch.setattr(main, "_fetch_book_source_import_payload_with_browser", reject_browser)
    with pytest.raises(ScraperNetworkSecurityError):
        if operation == "import":
            await main._fetch_book_source_import_payload("http://127.0.0.1:9/sources.json")
        else:
            source = BookSourceRecord(
                id="unsafe-source", name="测试书源", baseUrl="http://127.0.0.1:9",
                rulePayload={"searchUrl": "/search?q={{key}}", "ruleSearch": {}},
            )
            await main._search_legado_source(source, "测试", 3)
