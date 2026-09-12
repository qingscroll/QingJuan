import json
from contextlib import asynccontextmanager, nullcontext
from types import SimpleNamespace

import httpx
import pytest

from app import scraper
from app.models import AddBookPayload, ChapterPreview, PreviewResponse, TranslationSettings
from app.source_status import html_publication_status, publication_status


@pytest.mark.parametrize(
    ("source", "metadata", "expected"),
    [
        ("fanqie", {"creationStatus": 0}, "completed"),
        ("fanqie", {"creationStatus": "1"}, "ongoing"),
        ("fanqie", {"creationStatus": 9}, "unknown"),
        ("fanqie", {"creationStatus": False}, "unknown"),
        ("qidian", {"bookStatus": "完本", "finish": True}, "completed"),
        ("qidian", {"bookStatus": "连载", "finish": False}, "ongoing"),
        ("qidian", {"bookStatus": "完本", "finish": False}, "unknown"),
        ("qidian", {"state": 1}, "unknown"),
        ("quark", {"state": "1"}, "ongoing"),
        ("quark", {"state": 2}, "completed"),
        ("quark", {"state": "200"}, "unknown"),
        ("quark", {"state": True}, "unknown"),
        ("copymanga", {"status": {"value": 0, "display": "連載中"}}, "ongoing"),
        ("copymanga", {"status": {"value": 1}}, "unknown"),
        ("kakuyomu", {"serialStatus": "RUNNING"}, "ongoing"),
        ("kakuyomu", {"serialStatus": "COMPLETED"}, "completed"),
        ("kakuyomu", {"serialStatus": "SUSPENDED"}, "unknown"),
        ("kakuyomu", {"serialStatus": "DRAFT"}, "unknown"),
        ("bika", {"isFinished": False}, "ongoing"),
        ("bika", {"isFinished": "false"}, "unknown"),
        ("sfacg", {"isFinish": True}, "completed"),
        ("sfacg", {}, "unknown"),
        ("json-book", {"sourceStatus": "ongoing"}, "ongoing"),
        ("json-book", {"status": "completed"}, "unknown"),
    ],
)
def test_publication_fields_use_only_verified_semantics(source, metadata, expected):
    result = publication_status(source, metadata)
    assert result.status == expected
    assert (result.evidence is not None) == (expected != "unknown")


def test_synopsis_and_chapter_titles_are_never_publication_evidence():
    assert html_publication_status("<h1>完本</h1><p>这是一部连载中小说</p>").status == "unknown"
    assert html_publication_status('<meta property="og:novel:status" content="已完本">').status == "completed"
    assert (
        html_publication_status(
            '<meta property="og:novel:status" content="连载"><meta name="book:status" content="完本">'
        ).status
        == "unknown"
    )


@pytest.mark.asyncio
@pytest.mark.parametrize("creation_status,expected", [(0, "completed"), (1, "ongoing"), (22, "unknown")])
async def test_fanqie_preview_keeps_status_from_official_page_payload(monkeypatch, creation_status, expected):
    url = "https://fanqienovel.com/page/123456"
    state = {
        "page": {
            "bookId": "123456",
            "bookName": "作品",
            "creationStatus": creation_status,
            "chapterListWithVolume": [[{"itemId": "123457", "title": "第一章"}]],
        }
    }
    html = "<script>window.__INITIAL_STATE__=" + json.dumps(state) + ";</script>"

    async def fetch(_):
        return html, url

    monkeypatch.setattr(scraper, "_fetch_fanqie_html", fetch)
    preview = await scraper._preview_fanqie(
        url, AddBookPayload(sourceUrl=url, bookKind="长小说", language="中文")
    )
    assert preview.sourceStatus == expected
    assert preview.chapterCount == 1


@pytest.mark.asyncio
async def test_qidian_preview_uses_finish_and_keeps_access_restrictions(monkeypatch):
    monkeypatch.setattr(
        scraper, "get_qidian_book_info", lambda _: {"bookName": "作品", "bookStatus": "完本", "finish": True}
    )
    monkeypatch.setattr(
        scraper,
        "get_qidian_catalog",
        lambda _: {"volumes": [{"chapters": [{"chapterId": "234", "chapterName": "第一章", "isVip": True}]}]},
    )
    url = "https://book.qidian.com/info/123/"
    preview = await scraper._preview_qidian(
        url, AddBookPayload(sourceUrl=url, bookKind="长小说", language="中文")
    )
    assert preview.sourceStatus == "completed"
    assert preview.chapters[0].accessRestricted


@pytest.mark.asyncio
async def test_kakuyomu_queries_serial_status_and_passes_it_to_preview(monkeypatch):
    def handler(request):
        assert "serialStatus" in json.loads(request.content)["query"]
        return httpx.Response(
            200,
            json={
                "data": {
                    "work": {
                        "id": "123",
                        "title": "作品",
                        "serialStatus": "RUNNING",
                        "tableOfContentsV2": [
                            {"episodeUnions": [{"__typename": "Episode", "id": "234", "title": "第一章"}]}
                        ],
                    }
                }
            },
        )

    monkeypatch.setattr(
        scraper, "_build_http_client", lambda: httpx.AsyncClient(transport=httpx.MockTransport(handler))
    )
    url = "https://kakuyomu.jp/works/123"
    preview = await scraper._preview_kakuyomu(
        url, AddBookPayload(sourceUrl=url, bookKind="长小说", language="中文")
    )
    assert preview.sourceStatus == "ongoing"


@pytest.mark.asyncio
@pytest.mark.parametrize("manifest_only", [True, False])
async def test_both_import_modes_persist_publication_separately_from_download_state(
    monkeypatch, tmp_path, manifest_only
):
    @asynccontextmanager
    async def client():
        yield object()

    async def cover(*args):
        return None

    async def chapter(*args, **kwargs):
        return scraper.ChapterFetchResult(text="正文", image_urls=[])

    monkeypatch.setattr(scraper, "_build_http_client", client)
    monkeypatch.setattr(scraper, "_download_cover_image", cover)
    monkeypatch.setattr(scraper, "_fetch_chapter_data", chapter)
    monkeypatch.setattr(scraper, "_load_runtime_settings", TranslationSettings)
    preview = PreviewResponse(
        title="书",
        chapterCount=1,
        chapters=[ChapterPreview(title="章节", url="https://example.test/1")],
        sourceStatus="ongoing",
        sourceStatusEvidence="json-book.sourceStatus",
    )
    payload = AddBookPayload(sourceUrl="https://example.test/book", bookKind="长小说", language="中文")
    function = scraper.create_book_manifest_only if manifest_only else scraper.download_book
    result = await function(payload, preview, tmp_path)
    manifest = scraper.load_manifest(result.local_path)
    assert manifest["source_status"] == "ongoing"
    assert manifest["source_status_evidence"] == "json-book.sourceStatus"
    assert manifest["source_status_checked_at"].endswith("Z")
    assert manifest["chapters"][0]["downloaded"] is (not manifest_only)


@pytest.mark.asyncio
@pytest.mark.parametrize("state,expected", [("1", "ongoing"), ("2", "completed")])
async def test_quark_preview_uses_book_info_state_not_envelope_status(monkeypatch, state, expected):
    @asynccontextmanager
    async def client():
        yield object()

    async def info(*args):
        return {"bookName": "作品", "state": state}

    async def catalog(*args):
        return {}, [{"chapterId": "222", "chapterName": "第一章", "isFreeRead": True}]

    monkeypatch.setattr(scraper, "_build_http_client", client)
    monkeypatch.setattr(scraper, "get_quark_book_info", info)
    monkeypatch.setattr(scraper, "get_quark_catalog", catalog)
    url = "https://www.shuqi.com/book/111.html"
    preview = await scraper._preview_quark(
        url, AddBookPayload(sourceUrl=url, bookKind="长小说", language="中文")
    )
    assert preview.sourceStatus == expected and preview.chapterCount == 1


@pytest.mark.asyncio
@pytest.mark.parametrize("hook_fails", [True, False])
async def test_tracking_hook_runs_after_import_commit_and_cannot_fail_the_import(
    monkeypatch, tmp_path, hook_fails
):
    from app import book_import_execution

    monkeypatch.setattr(book_import_execution, "provisional_book_storage", lambda *args: nullcontext())
    events = []

    def register(book_id, owner_id):
        assert events == ["saved"]
        events.append((book_id, owner_id))
        if hook_fails:
            raise OSError("temporary tracking database failure")

    async def imported(*args):
        return SimpleNamespace(
            title="作品",
            synopsis="",
            cover=None,
            local_path=tmp_path / "book",
            chapters=[ChapterPreview(title="一", url="https://example.test/1")],
        )

    runtime = SimpleNamespace(
        LIBRARY_ROOT=tmp_path,
        _uses_manifest_only_import=lambda _: True,
        create_book_manifest_only=imported,
        _storage_key_for_path=lambda _: "library/book",
        _now=lambda: "2026-09-12T00:00:00Z",
        save_book=lambda _: events.append("saved"),
        app=SimpleNamespace(state=SimpleNamespace(book_updates=SimpleNamespace(register_book=register))),
        _schedule_server_managed_source_cache=lambda _: None,
        _hydrate_book_record=lambda record: record,
    )
    payload = AddBookPayload(sourceUrl="https://example.test/book", bookKind="长小说", language="中文")
    preview = PreviewResponse(title="作品", chapterCount=1, chapters=[])
    result = await book_import_execution.create_imported_book(runtime, payload, preview, owner_id="alice")
    assert result.ownerId == "alice"
    assert events == ["saved", (result.id, "alice")]
