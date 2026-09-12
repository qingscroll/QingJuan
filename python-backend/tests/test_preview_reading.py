import asyncio
import hashlib
import os
from contextlib import asynccontextmanager
from io import BytesIO
from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app import admin_auth, db, scraper
from app.api import preview_reading as api
from app.application import create_application
from app.models import AddBookPayload, ChapterPreview, PreviewResponse
from app.multi_user import DEFAULT_ADMIN_USER_ID
from app.preview_reading import PreviewChapterRequest, PreviewReadingError, PreviewReadingService
from app.security import API_PREFIX


@pytest.fixture
def preview(monkeypatch, tmp_path):
    source_reader = scraper._fetch_chapter_data
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    db.init_db()
    calls = []
    result = scraper.ChapterFetchResult(text="第一段。\n\n第二段。", image_urls=[])
    catalog = PreviewResponse(
        title="试读作品",
        chapterCount=2,
        bookKind="长小说",
        chapters=[
            ChapterPreview(title=f"第 {index} 章", url=f"https://books.example/chapter/{index}")
            for index in (1, 2)
        ],
    )

    async def resolve(payload):
        calls.append(("preview", str(payload.sourceUrl)))
        return catalog

    @asynccontextmanager
    async def client():
        yield object()

    async def fetch(_client, url, title, **kwargs):
        calls.append(("chapter", url, title, kwargs))
        return result

    async def binary(_client, url, referer):
        calls.append(("image", url, referer))
        output = BytesIO()
        Image.new("RGB", (2, 2), "white").save(output, format="PNG")
        return output.getvalue()

    monkeypatch.setattr(scraper, "_build_http_client", client)
    monkeypatch.setattr(scraper, "_fetch_chapter_data", fetch)
    monkeypatch.setattr(scraper, "_download_binary_bytes", binary)
    monkeypatch.setattr(scraper, "_require_enabled_site_plugin", lambda _: None)
    runtime = SimpleNamespace(
        preview_from_url=resolve,
        _site_account_download_kwargs=lambda owner, _: {"qidian_cookies": {"owner": owner}},
        _split_paragraphs=lambda value: [part for part in value.splitlines() if part],
    )
    clock = [1000.0]
    service = PreviewReadingService(runtime, now=lambda: clock[0], ttl_seconds=900)
    request = PreviewChapterRequest(
        book=AddBookPayload(sourceUrl="https://books.example/book", bookKind="长小说", language="中文"),
        chapterIndex=2,
    )
    return SimpleNamespace(
        service=service,
        runtime=runtime,
        request=request,
        result=result,
        catalog=catalog,
        calls=calls,
        clock=clock,
        root=tmp_path,
        source_reader=source_reader,
    )


async def test_read_uses_server_catalog_and_owner_credentials_without_library_writes(preview):
    before = sorted(path.relative_to(preview.root).as_posix() for path in preview.root.rglob("*"))
    response = await preview.service.read("alice", preview.request)
    assert response.bookId == ""
    assert response.chapter.title == "第 2 章"
    assert response.chapter.downloaded is False
    assert response.mode == "original"
    assert response.paragraphs == ["第一段。", "第二段。"]
    assert preview.calls[-1] == (
        "chapter",
        "https://books.example/chapter/2",
        "第 2 章",
        {"qidian_cookies": {"owner": "alice"}},
    )
    assert db.list_books() == []
    assert db.list_tasks() == []
    assert sorted(path.relative_to(preview.root).as_posix() for path in preview.root.rglob("*")) == before


async def test_invalid_directory_position_never_fetches_chapter(preview):
    preview.request.chapterIndex = 3
    with pytest.raises(PreviewReadingError, match="章节不存在"):
        await preview.service.read("alice", preview.request)
    assert all(call[0] != "chapter" for call in preview.calls)


async def test_reordered_catalog_does_not_read_a_different_chapter(preview):
    preview.request.expectedChapterUrl = preview.catalog.chapters[1].url
    preview.catalog.chapters.reverse()
    with pytest.raises(PreviewReadingError) as error:
        await preview.service.read("alice", preview.request)
    assert error.value.status_code == 409
    assert all(call[0] != "chapter" for call in preview.calls)


async def test_locked_catalog_uses_current_account_instead_of_blocking_read(preview):
    preview.catalog.chapters[1].accessRestricted = True
    response = await preview.service.read("alice", preview.request)
    assert response.content == preview.result.text
    assert preview.calls[-1][-1] == {"qidian_cookies": {"owner": "alice"}}
    assert db.list_books() == []


async def test_source_restrictions_are_not_replaced_by_an_import_fallback(preview, monkeypatch):
    preview.catalog.chapters[1].accessRestricted = True

    async def restricted(*args, **kwargs):
        raise ValueError("需要来源账户授权")

    monkeypatch.setattr(scraper, "_fetch_chapter_data", restricted)
    with pytest.raises(ValueError, match="需要来源账户授权"):
        await preview.service.read("alice", preview.request)
    assert db.list_books() == []
    assert not preview.service._sessions


async def test_restricted_source_without_content_is_not_reported_as_readable(preview):
    preview.catalog.chapters[1].accessRestricted = True
    preview.result.access_restricted = True
    preview.result.text = ""
    preview.result.image_urls = []
    with pytest.raises(PreviewReadingError, match="未返回可试读内容"):
        await preview.service.read("alice", preview.request)
    assert not preview.service._sessions
    assert db.list_books() == []
    assert db.list_tasks() == []


async def test_source_restriction_metadata_does_not_discard_returned_manga(preview):
    preview.result.access_restricted = True
    preview.result.text = ""
    preview.result.image_urls = ["https://images.example/readable.png"]
    response = await preview.service.read("alice", preview.request)
    assert response.chapter.imageCount == 1
    token = response.imageSources[0].split("/")[-2]
    assert preview.service._sessions[token].owner_id == "alice"
    assert db.list_books() == []
    assert db.list_tasks() == []


async def test_preview_matches_bookshelf_source_reader_for_authorized_vip_content(preview, monkeypatch):
    chapter_url = "https://m.qidian.com/chapter/123/456/"
    preview.catalog.chapters[1].url = chapter_url
    preview.catalog.chapters[1].accessRestricted = True
    cookies_seen = []

    def qidian_chapter(book_id, chapter_id, *, cookies):
        assert (book_id, chapter_id) == ("123", "456")
        cookies_seen.append(cookies)
        return {"text": "已登录来源账号可以读取的正文", "accessRestricted": True}

    monkeypatch.setattr(scraper, "_fetch_chapter_data", preview.source_reader)
    monkeypatch.setattr(
        scraper,
        "_require_enabled_site_plugin",
        lambda _: SimpleNamespace(origin="builtin", chapter_handler="qidian"),
    )
    monkeypatch.setattr(scraper, "get_qidian_chapter", qidian_chapter)
    before = set(preview.root.rglob("*"))
    response = await preview.service.read("alice", preview.request)
    assert set(preview.root.rglob("*")) == before
    assert db.list_books() == []
    assert db.list_tasks() == []

    # Exercise the actual saved-book download path with the same source session.
    book_dir = preview.root / "formal-reading-comparison"
    book_dir.mkdir()
    downloaded = await scraper.download_chapter_payload(
        book_dir,
        {
            "source_url": "https://m.qidian.com/book/123/",
            "chapters": [{"index": 2, "url": chapter_url, "access_restricted": True}],
        },
        2,
        qidian_cookies={"owner": "alice"},
    )
    assert cookies_seen == [{"owner": "alice"}, {"owner": "alice"}]
    assert downloaded["downloaded"] is True
    assert downloaded["access_restricted"] is True
    assert scraper.chapter_text_path(book_dir, downloaded["file_name"]).read_text("utf-8") == response.content


async def test_trusted_local_preview_uses_saved_admin_account_and_asset_owner(preview, monkeypatch):
    monkeypatch.setenv("QINGJUAN_TRUST_LOCAL_ADMIN", "1")
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "0")
    monkeypatch.setattr(admin_auth, "os", SimpleNamespace(name="nt", getenv=os.getenv))
    original_access = api.require_user_access
    accesses = []

    def read_access(request):
        access = original_access(request)
        accesses.append(access)
        return access

    monkeypatch.setattr(api, "require_user_access", read_access)
    preview.catalog.chapters[1].accessRestricted = True
    preview.result.access_restricted = True
    preview.result.image_urls = ["https://images.example/page.png"]
    application = create_application(routers=[api.router], api_prefix=API_PREFIX)
    application.state.preview_reading = preview.service
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=application, client=("127.0.0.1", 12345)),
        base_url="http://127.0.0.1",
        headers={"X-QingJuan-Local-Request": "1"},
    ) as client:
        response = await client.post(
            f"{API_PREFIX}/books/preview/chapter", json=preview.request.model_dump(mode="json")
        )
        assert response.status_code == 200
        assert preview.calls[-1][-1] == {"qidian_cookies": {"owner": DEFAULT_ADMIN_USER_ID}}
        asset = response.json()["imageSources"][0]
        token = asset.split("/")[-2]
        assert preview.service._sessions[token].owner_id == DEFAULT_ADMIN_USER_ID
        image = await client.get(asset)
        assert image.status_code == 200
        assert image.headers["Content-Type"] == "image/png"
    assert len(accesses) == 2
    assert all(access.admin_view and access.owner_id is None for access in accesses)
    assert db.list_books() == []
    assert db.list_tasks() == []


async def test_manga_is_lazy_owner_bound_and_expires(preview):
    preview.result.image_urls = ["https://images.example/page.png", "https://images.example/page2.png"]
    response = await preview.service.read("alice", preview.request)
    assert response.chapter.imageCount == 2
    token = response.imageSources[0].split("/")[-2]
    assert not any(call[0] == "image" for call in preview.calls)
    for owner, index in [("bob", 0), ("alice", -1), ("alice", 2)]:
        with pytest.raises(PreviewReadingError) as error:
            await preview.service.image(owner, token, index)
        assert error.value.status_code == 404
    content, mime = await preview.service.image("alice", token, 0)
    assert mime == "image/png" and content.startswith(b"\x89PNG")
    assert await preview.service.image("alice", token, 0) == (content, mime)
    assert [call[0] for call in preview.calls].count("image") == 1
    preview.clock[0] += 901
    with pytest.raises(PreviewReadingError, match="过期"):
        await preview.service.image("alice", token, 0)
    assert preview.service._image_bytes == 0
    assert not preview.service._images


async def test_old_preview_assets_are_evicted_per_owner(preview):
    preview.result.image_urls = ["https://images.example/page.png"]
    first = await preview.service.read("alice", preview.request)
    first_token = first.imageSources[0].split("/")[-2]
    for _ in range(8):
        await preview.service.read("alice", preview.request)
    assert len(preview.service._sessions) == 8
    with pytest.raises(PreviewReadingError):
        await preview.service.image("alice", first_token, 0)


async def test_maintenance_invalidates_inflight_preview(preview, monkeypatch):
    entered = asyncio.Event()
    release = asyncio.Event()

    async def delayed(*args, **kwargs):
        entered.set()
        await release.wait()
        return preview.result

    monkeypatch.setattr(scraper, "_fetch_chapter_data", delayed)
    task = asyncio.create_task(preview.service.read("alice", preview.request))
    await entered.wait()
    preview.service.clear()
    release.set()
    with pytest.raises(PreviewReadingError, match="重新加载"):
        await task
    assert not preview.service._sessions


async def test_cancellation_does_not_leave_preview_assets(preview, monkeypatch):
    entered = asyncio.Event()

    async def delayed(*args, **kwargs):
        entered.set()
        await asyncio.Future()

    monkeypatch.setattr(scraper, "_fetch_chapter_data", delayed)
    task = asyncio.create_task(preview.service.read("alice", preview.request))
    await entered.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert not preview.service._sessions


@pytest.mark.parametrize("index", [0, -1, 1.5, True, "2"])
def test_api_validates_index_before_network(preview, index):
    application = create_application(routers=[api.router], api_prefix=API_PREFIX)
    application.state.preview_reading = preview.service
    with TestClient(application) as client:
        payload = preview.request.model_dump(mode="json") | {"chapterIndex": index}
        assert client.post(f"{API_PREFIX}/books/preview/chapter", json=payload).status_code == 422
    assert preview.calls == []


def test_api_requires_connection_and_user_authentication(preview, monkeypatch):
    token = "preview-connection-token"
    monkeypatch.setenv("QINGJUAN_AUTH_TOKEN_SHA256", hashlib.sha256(token.encode()).hexdigest())
    application = create_application(routers=[api.router], authenticate=True)
    application.state.preview_reading = preview.service
    with TestClient(application) as client:
        url = f"{API_PREFIX}/books/preview/chapter"
        payload = preview.request.model_dump(mode="json")
        assert client.post(url, json=payload).status_code == 401
        headers = {"Authorization": f"Bearer {token}"}
        response = client.post(url, json=payload, headers=headers)
        assert response.status_code == 200
        assert response.headers["Cache-Control"] == "no-store"
        assert db.list_books() == []
        monkeypatch.setenv("QINGJUAN_MULTI_USER", "1")
        assert client.post(url, json=payload, headers=headers).status_code == 401
        assert (
            client.get(f"{API_PREFIX}/books/preview/assets/not-a-token/0", headers=headers).status_code == 401
        )


async def test_api_does_not_expose_assets_to_other_owners(preview, monkeypatch):
    preview.result.image_urls = ["https://images.example/page.png"]
    response = await preview.service.read("alice", preview.request)
    application = create_application(routers=[api.router], api_prefix=API_PREFIX)
    application.state.preview_reading = preview.service
    monkeypatch.setattr(api, "require_user_access", lambda _: SimpleNamespace(owner_id="bob"))
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=application), base_url="http://test"
    ) as client:
        denied = await client.get(response.imageSources[0])
        assert denied.status_code == 404
        monkeypatch.setattr(api, "require_user_access", lambda _: SimpleNamespace(owner_id="alice"))
        allowed = await client.get(response.imageSources[0])
        assert allowed.status_code == 200
        assert allowed.headers["Content-Type"] == "image/png"
        assert allowed.headers["Cache-Control"] == "no-store"


async def test_invalid_image_is_not_cached(preview, monkeypatch):
    preview.result.image_urls = ["https://images.example/page.png"]
    response = await preview.service.read("alice", preview.request)
    token = response.imageSources[0].split("/")[-2]

    async def invalid(*args):
        return b"<html>login required</html>"

    monkeypatch.setattr(scraper, "_download_binary_bytes", invalid)
    with pytest.raises(PreviewReadingError, match="图片无效"):
        await preview.service.image("alice", token, 0)
    assert not preview.service._images


def test_production_library_router_resolves_preview_before_book_routes(preview, monkeypatch):
    from app import main
    from app.api.routers import library_router

    monkeypatch.setattr(main, "preview_from_url", preview.runtime.preview_from_url)
    application = create_application(routers=[library_router], api_prefix=API_PREFIX)
    application.state.preview_reading = preview.service
    with TestClient(application) as client:
        detail = client.post(f"{API_PREFIX}/books/preview", json=preview.request.book.model_dump(mode="json"))
        assert detail.status_code == 200
        assert detail.headers["Cache-Control"] == "no-store"
        assert len(detail.json()["chapters"]) == 2
        chapter = client.post(
            f"{API_PREFIX}/books/preview/chapter", json=preview.request.model_dump(mode="json")
        )
        assert chapter.status_code == 200
        assert chapter.json()["bookId"] == ""
        assert db.list_books() == []
        assert db.list_tasks() == []
