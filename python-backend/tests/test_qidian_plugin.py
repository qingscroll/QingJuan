from __future__ import annotations

import json
from types import SimpleNamespace
from typing import Any

import pytest
from fastapi.testclient import TestClient

from app import db, main, scraper
from app.api.routers import plugins_router
from app.application import create_application
from app.models import (
    AddBookPayload,
    BookRecord,
    BookSourceRecord,
    ChapterPreview,
    PreviewResponse,
    TaskRecord,
)
from app.multi_user import DEFAULT_ADMIN_USER_ID
from app.site_plugins import get_site_plugin, qidian_client, qidian_runtime
from app.site_plugins.qidian_client import QidianApiError
from app.site_plugins.qidian_runtime import QidianRuntime


class _FakeResponse:
    def __init__(
        self,
        payload: dict[str, Any] | None = None,
        *,
        text: str = "",
        status_code: int = 200,
        headers: dict[str, str] | None = None,
    ) -> None:
        self.status_code = status_code
        self.headers = headers or {}
        self._payload = payload or {}
        self.text = text

    def json(self) -> dict[str, Any]:
        return self._payload


def test_qidian_login_redirects_reject_untrusted_hosts() -> None:
    class _Session:
        def __init__(self) -> None:
            self.calls: list[str] = []

        def get(self, url: str, **kwargs) -> _FakeResponse:
            self.calls.append(url)
            return _FakeResponse(
                status_code=302,
                headers={"Location": "http://127.0.0.1/private"},
            )

    session = _Session()

    with pytest.raises(QidianApiError, match="不受信任"):
        qidian_client._follow_login_redirects(session, "https://www.qidian.com/loginSuccess")

    assert session.calls == ["https://www.qidian.com/loginSuccess"]


def test_qidian_search_maps_mobile_ssr_results_without_account_state(monkeypatch) -> None:
    page_context = {
        "pageContext": {
            "pageProps": {
                "pageData": {
                    "kw": "斗破苍穹",
                    "bookInfo": {
                        "total": 1000,
                        "pageNum": 1,
                        "pageSize": 20,
                        "isLast": 0,
                        "records": [
                            {
                                "bid": 1209977,
                                "bName": "斗破苍穹",
                                "cid": 1019021,
                                "bAuth": "天蚕土豆",
                                "desc": "这里是属于斗气的世界",
                                "cat": "玄幻",
                                "subCateName": "异世大陆",
                                "imgUrl": "//bookcover.yuewen.com/qdbimg/349573/1209977/180",
                                "cnt": "533.23万字",
                            },
                            {"bid": 2, "bName": "超出限制"},
                        ],
                    },
                }
            }
        }
    }
    captured: dict[str, object] = {}

    def request_get(session, url, **kwargs):
        captured.update({"url": url, **kwargs})
        return _FakeResponse(
            text=f'<script id="vite-plugin-ssr_pageContext">{json.dumps(page_context)}</script>'
        )

    monkeypatch.setattr(qidian_client, "_request_get", request_get)

    result = qidian_client.search_books("斗破 苍穹", page_size=1)

    assert result["data"]["keyword"] == "斗破苍穹"
    assert result["data"]["books"] == [
        {
            "bookId": 1209977,
            "bookName": "斗破苍穹",
            "cbid": None,
            "authorId": 1019021,
            "authorName": "天蚕土豆",
            "desc": "这里是属于斗气的世界",
            "category": "玄幻",
            "subCategory": "异世大陆",
            "state": None,
            "signStatus": None,
            "coverUrl": "https://bookcover.yuewen.com/qdbimg/349573/1209977/180",
            "isVip": None,
            "wordCountText": "533.23万字",
            "recommendCnt": None,
            "favoriteCnt": None,
            "lastChapterName": None,
            "lastUpdateTime": None,
            "bookType": None,
            "isPub": None,
        }
    ]
    assert captured["url"] == ("https://m.qidian.com/so/%E6%96%97%E7%A0%B4%20%E8%8B%8D%E7%A9%B9.html")
    assert captured["params"] == {"pageNum": 1, "orderBy": 0}
    assert "cookies" not in captured


@pytest.mark.asyncio
async def test_qidian_builtin_search_maps_to_canonical_book_urls(monkeypatch) -> None:
    monkeypatch.setattr(
        scraper,
        "search_qidian_books",
        lambda *args, **kwargs: {
            "data": {
                "books": [
                    {
                        "bookId": 1209977,
                        "bookName": "斗破苍穹",
                        "authorName": "天蚕土豆",
                        "desc": "这里是属于斗气的世界",
                        "coverUrl": "https://example.test/cover.jpg",
                    },
                    {"bookId": 1209977, "bookName": "重复作品"},
                    {"bookId": "invalid", "bookName": "无效作品"},
                ]
            }
        },
    )
    source = BookSourceRecord(
        id="source-builtin-qidian",
        name="起点中文网",
        baseUrl="https://www.qidian.com",
        bookKind="长小说",
        language="中文",
        origin="builtin",
    )

    results = await scraper._search_qidian_works(source, "斗破苍穹", 8)

    assert len(results) == 1
    assert results[0].title == "斗破苍穹"
    assert results[0].author == "天蚕土豆"
    assert results[0].synopsis == "这里是属于斗气的世界"
    assert results[0].sourceUrl == "https://www.qidian.com/book/1209977/"


def test_qidian_plugin_declares_search_capability() -> None:
    plugin = get_site_plugin("qidian")

    assert plugin is not None
    assert plugin.search_handler == "qidian"
    assert "search" in plugin.capabilities


def test_qidian_catalog_maps_volumes_and_access_state(monkeypatch) -> None:
    response = _FakeResponse(
        {
            "code": 0,
            "data": {
                "bookId": 123,
                "bookName": "测试作品",
                "vs": [
                    {
                        "cs": [
                            {"id": 11, "cN": "免费章", "cnt": 1000, "sS": 1},
                            {"id": 12, "cN": "付费章", "cnt": 1200, "sS": 2},
                        ]
                    }
                ],
            },
        }
    )
    monkeypatch.setattr(qidian_client, "_request_get", lambda *args, **kwargs: response)

    result = qidian_client.get_catalog("123")

    chapters = result["volumes"][0]["chapters"]
    assert result["chapterTotal"] == 2
    assert chapters[0]["isVip"] is False
    assert chapters[1]["isVip"] is True
    assert chapters[1]["chapterId"] == "12"


def test_qidian_reports_unsupported_encrypted_chapter_format(monkeypatch) -> None:
    page_context = {
        "pageContext": {
            "pageProps": {
                "pageData": {
                    "chapterInfo": {
                        "chapterId": "11",
                        "chapterName": "受保护章节",
                        "content": "encrypted",
                        "fkp": "protected-key-payload",
                    }
                }
            }
        }
    }
    html = f'<script id="vite-plugin-ssr_pageContext">{json.dumps(page_context)}</script>'
    monkeypatch.setattr(
        qidian_client,
        "_request_get",
        lambda *args, **kwargs: _FakeResponse(text=html),
    )

    with pytest.raises(QidianApiError, match="尚未支持的加密正文格式"):
        qidian_client.get_chapter("123", "11", cookies={"ywguid": "private"})


def test_qidian_parses_returned_vip_content_without_preemptive_rejection(monkeypatch) -> None:
    page_context = {
        "pageContext": {
            "pageProps": {
                "pageData": {
                    "chapterInfo": {
                        "chapterId": "12",
                        "chapterName": "订阅章节",
                        "content": "<p>第一段完整正文</p><p>第二段完整正文</p>",
                        "freeStatus": "1",
                        "isBuy": "0",
                        "vipStatus": "1",
                    }
                }
            }
        }
    }
    html = f'<script id="vite-plugin-ssr_pageContext">{json.dumps(page_context)}</script>'
    monkeypatch.setattr(
        qidian_client,
        "_request_get",
        lambda *args, **kwargs: _FakeResponse(text=html),
    )

    result = qidian_client.get_chapter("123", "12")

    assert result["text"] == "第一段完整正文\n第二段完整正文"
    assert result["accessRestricted"] is True


def test_qidian_free_chapter_normalizes_string_access_flags(monkeypatch) -> None:
    page_context = {
        "pageContext": {
            "pageProps": {
                "pageData": {
                    "chapterInfo": {
                        "chapterId": "11",
                        "chapterName": "公开章节",
                        "content": "<p>第一段</p><p>第二段</p>",
                        "freeStatus": "0",
                        "isBuy": "0",
                        "vipStatus": "0",
                    }
                }
            }
        }
    }
    html = f'<script id="vite-plugin-ssr_pageContext">{json.dumps(page_context)}</script>'
    monkeypatch.setattr(
        qidian_client,
        "_request_get",
        lambda *args, **kwargs: _FakeResponse(text=html),
    )

    result = qidian_client.get_chapter("123", "11")

    assert result["text"] == "第一段\n第二段"
    assert result["accessRestricted"] is False


def test_qidian_runtime_reads_all_groups_pages_and_deduplicates(monkeypatch) -> None:
    calls: list[tuple[int, int]] = []

    def fake_page(cookies, *, group_id, page, page_size, sort=0):
        calls.append((group_id, page))
        payloads = {
            (-100, 1): {
                "groups": [{"groupId": -100}, {"groupId": 8}],
                "page": {"totalPage": 2, "isLast": 0},
                "books": [{"bid": "1", "bookName": "甲"}],
            },
            (-100, 2): {
                "groups": [],
                "page": {"totalPage": 2, "isLast": 1},
                "books": [{"bid": "2", "bookName": "乙"}],
            },
            (8, 1): {
                "groups": [],
                "page": {"totalPage": 1, "isLast": 1},
                "books": [
                    {"bid": "2", "bookName": "乙（重复）"},
                    {"bid": "3", "bookName": "丙"},
                ],
            },
        }
        return payloads[(group_id, page)]

    runtime = QidianRuntime()
    monkeypatch.setattr(runtime, "cookies", lambda: {"ywguid": "x", "ywkey": "y"})
    monkeypatch.setattr(qidian_runtime, "get_bookshelf_page", fake_page)

    books = runtime.list_bookshelf_books()

    assert [book["bid"] for book in books] == ["1", "2", "3"]
    assert calls == [(-100, 1), (-100, 2), (8, 1)]


def test_qidian_runtime_hides_upstream_session_and_cookies(monkeypatch) -> None:
    monkeypatch.setattr(
        qidian_runtime,
        "get_qrcode",
        lambda session: {
            "sessionKey": "upstream-secret-session",
            "qrImageBase64": "aW1hZ2U=",
            "expireSeconds": 180,
        },
    )
    monkeypatch.setattr(
        qidian_runtime,
        "poll_qrcode",
        lambda session, session_key: {
            "status": "success",
            "message": "登录成功",
            "cookies": {"ywguid": "private-guid", "ywkey": "private-key"},
        },
    )
    runtime = QidianRuntime()

    started = runtime.start_login()
    polled = runtime.poll_login(str(started["flowId"]))

    assert "sessionKey" not in started
    assert "cookies" not in polled
    assert "private" not in json.dumps(started | polled)
    assert polled == {"status": "success", "message": "登录成功", "loggedIn": True}


def test_qidian_login_routes_are_private_and_never_expose_upstream_state(monkeypatch) -> None:
    monkeypatch.setattr(main, "is_site_plugin_enabled", lambda plugin_id: plugin_id == "qidian")
    monkeypatch.setattr(
        main.QIDIAN_RUNTIME,
        "start_login",
        lambda: {
            "flowId": "opaque-flow",
            "qrImageBase64": "aW1hZ2U=",
            "expiresAt": "2030-01-01T00:03:00Z",
        },
    )
    monkeypatch.setattr(
        main.QIDIAN_RUNTIME,
        "poll_login",
        lambda flow_id: {
            "status": "success",
            "message": "登录成功",
            "loggedIn": True,
        },
    )
    application = create_application(routers=[plugins_router])

    with TestClient(application) as client:
        started = client.post("/plugins/qidian/account/login-qrcode")
        polled = client.get("/plugins/qidian/account/login-qrcode/opaque-flow")

    assert started.status_code == 200
    assert polled.status_code == 200
    assert started.headers["Cache-Control"] == "no-store"
    assert polled.headers["Cache-Control"] == "no-store"
    combined = json.dumps([started.json(), polled.json()])
    assert "sessionKey" not in combined
    assert "cookies" not in combined


@pytest.mark.asyncio
async def test_qidian_bookshelf_import_skips_existing_and_isolates_failure(monkeypatch) -> None:
    main.SITE_PLUGIN_IMPORT_JOB_STORE.clear()
    remote_books = [
        {"bid": "1", "bookName": "已有作品", "cateName": "玄幻"},
        {"bid": "2", "bookName": "新增作品", "cateName": "轻小说"},
        {"bid": "3", "bookName": "失败作品", "cateName": "都市"},
    ]
    existing = BookRecord(
        id="book-existing",
        title="已有作品",
        sourceUrl="https://book.qidian.com/info/1/",
        bookKind="长小说",
        language="中文",
        status="待处理",
        chapterCount=1,
        translated=False,
        localPath="中文/已有作品",
    )
    monkeypatch.setattr(main.QIDIAN_RUNTIME, "list_bookshelf_books", lambda: remote_books)
    monkeypatch.setattr(main, "list_books", lambda owner_id=None: [existing])

    async def fake_preview(payload):
        if qidian_client.qidian_book_id_from_url(str(payload.sourceUrl)) == "3":
            raise ValueError("目录不可用")
        return PreviewResponse(
            title=payload.title or "新增作品",
            author="作者",
            synopsis="简介",
            chapterCount=1,
            chapters=[
                ChapterPreview(
                    title="第一章",
                    url="https://m.qidian.com/chapter/2/20/",
                )
            ],
            bookKind=payload.bookKind,
        )

    async def fake_create(payload, preview, *, owner_id="user-admin"):
        return BookRecord(
            id="book-new",
            title=preview.title,
            sourceUrl=str(payload.sourceUrl),
            bookKind=preview.bookKind,
            language=payload.language,
            status="待处理",
            chapterCount=1,
            translated=False,
            localPath="中文/新增作品",
        )

    monkeypatch.setattr(main, "preview_from_url", fake_preview)
    monkeypatch.setattr(main, "_create_imported_book", fake_create)
    job = main.SITE_PLUGIN_IMPORT_JOB_STORE.create("qidian")

    await main._run_site_plugin_bookshelf_import(job.id, "qidian")

    result = main.SITE_PLUGIN_IMPORT_JOB_STORE.get(job.id, "qidian")
    assert result.status == "completed"
    assert (result.importedCount, result.skippedCount, result.failedCount) == (1, 1, 1)
    assert [item.status for item in result.items] == ["skipped", "imported", "failed"]
    assert result.items[1].bookId == "book-new"


@pytest.mark.asyncio
async def test_qidian_chapter_fetch_uses_only_explicit_cookie_context(monkeypatch) -> None:
    captured: list[dict[str, str]] = []

    def fake_get_chapter(
        book_id: str,
        chapter_id: str,
        *,
        cookies: dict[str, str],
    ) -> dict[str, object]:
        assert (book_id, chapter_id) == ("1209977", "11")
        captured.append(dict(cookies))
        cookies["mutated"] = "inside-fetch"
        return {"text": "正文", "accessRestricted": False}

    monkeypatch.setattr(scraper, "get_qidian_chapter", fake_get_chapter)
    admin_cookies = {"ywguid": "admin-guid", "ywkey": "admin-key"}
    user_cookies = {"ywguid": "reader-guid", "ywkey": "reader-key"}

    await scraper._fetch_qidian_chapter_data(
        "https://m.qidian.com/chapter/1209977/11/",
        qidian_cookies=admin_cookies,
    )
    await scraper._fetch_qidian_chapter_data(
        "https://m.qidian.com/chapter/1209977/11/",
        qidian_cookies=user_cookies,
    )

    assert captured == [admin_cookies, user_cookies]
    assert "mutated" not in admin_cookies
    assert "mutated" not in user_cookies


@pytest.mark.asyncio
async def test_qidian_incremental_downloads_forward_separate_cookie_contexts(
    monkeypatch,
    tmp_path,
) -> None:
    captured: list[dict[str, str]] = []

    async def fake_download_single(
        client,
        book_dir,
        chapter_index,
        chapter,
        *,
        image_download_semaphore=None,
        qidian_cookies=None,
        shaoniandream_cookies=None,
    ) -> dict[str, object]:
        assert shaoniandream_cookies is None
        captured.append(dict(qidian_cookies or {}))
        return {
            "index": chapter_index,
            "file_name": "0001-test.txt",
            "downloaded": True,
            "illustration": False,
            "image_urls": [],
            "image_files": [],
            "translated_image_files": [],
            "page_count": 0,
            "images_repaired": False,
            "content_source": "qidian-mobile-web",
            "authorization_method": "qidian-web-session",
            "access_restricted": False,
        }

    def manifest() -> dict[str, object]:
        return {
            "source_url": "https://www.qidian.com/book/1209977/",
            "chapters": [
                {
                    "index": 1,
                    "title": "第一章",
                    "url": "https://m.qidian.com/chapter/1209977/11/",
                    "file_name": "0001-test.txt",
                }
            ],
        }

    monkeypatch.setattr(scraper, "_download_single_chapter", fake_download_single)
    admin_dir = tmp_path / "admin"
    user_dir = tmp_path / "user"
    admin_dir.mkdir()
    user_dir.mkdir()
    admin_cookies = {"ywguid": "admin-guid"}
    user_cookies = {"ywguid": "reader-guid"}

    await scraper.download_chapter_payload(
        admin_dir,
        manifest(),
        1,
        qidian_cookies=admin_cookies,
    )
    await scraper.download_selected_chapters(
        user_dir,
        manifest(),
        [1],
        qidian_cookies=user_cookies,
    )

    assert captured == [admin_cookies, user_cookies]


@pytest.mark.asyncio
async def test_qidian_full_download_forwards_cookie_without_persisting_it(
    monkeypatch,
    tmp_path,
) -> None:
    captured: list[dict[str, str]] = []

    async def fake_fetch(
        client,
        chapter_url: str,
        chapter_title: str = "",
        *,
        qidian_cookies=None,
    ) -> scraper.ChapterFetchResult:
        captured.append(dict(qidian_cookies or {}))
        return scraper.ChapterFetchResult(text=f"{chapter_title}正文", image_urls=[])

    async def fake_cover(*args, **kwargs) -> None:
        return None

    monkeypatch.setattr(scraper, "_fetch_chapter_data", fake_fetch)
    monkeypatch.setattr(scraper, "_download_cover_image", fake_cover)
    monkeypatch.setattr(
        scraper,
        "_load_runtime_settings",
        lambda: SimpleNamespace(downloadConcurrency=1),
    )
    cookies = {"ywguid": "private-admin-guid", "ywkey": "private-admin-key"}
    payload = AddBookPayload(
        sourceUrl="https://www.qidian.com/book/1209977/",
        bookKind="长小说",
        language="中文",
    )
    preview = PreviewResponse(
        title="起点测试书",
        chapterCount=1,
        chapters=[
            ChapterPreview(
                title="第一章",
                url="https://m.qidian.com/chapter/1209977/11/",
            )
        ],
        bookKind="长小说",
    )

    result = await scraper.download_book(
        payload,
        preview,
        tmp_path,
        qidian_cookies=cookies,
    )

    assert captured == [cookies]
    manifest_text = (result.local_path / "manifest.json").read_text(encoding="utf-8")
    assert "private-admin-guid" not in manifest_text
    assert "private-admin-key" not in manifest_text


@pytest.mark.asyncio
async def test_qidian_main_resolves_owner_cookie_for_every_download_path(
    monkeypatch,
    tmp_path,
) -> None:
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    db.init_db()
    reader_id = "user-reader"
    db.create_user(user_id=reader_id, username="reader", username_key="reader",
                   display_name="Reader", password_hash="test-unused")
    cookies_by_owner = {
        DEFAULT_ADMIN_USER_ID: {"ywguid": "admin-guid"},
        reader_id: {"ywguid": "reader-guid"},
    }

    def fake_runtime(plugin, owner_id):
        assert plugin.id == "qidian"
        return SimpleNamespace(cookies=lambda: dict(cookies_by_owner[owner_id]))

    import_cookies: list[dict[str, str]] = []

    async def fake_download_book(
        payload,
        preview,
        root_dir,
        *,
        qidian_cookies=None,
    ) -> SimpleNamespace:
        import_cookies.append(dict(qidian_cookies or {}))
        return SimpleNamespace(
            title=preview.title,
            synopsis=preview.synopsis,
            cover=None,
            chapters=preview.chapters,
            local_path=root_dir,
        )

    monkeypatch.setattr(main, "_site_plugin_runtime", fake_runtime)
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "LIBRARY_ROOT", tmp_path / "library")
    monkeypatch.setattr(main, "download_book", fake_download_book)
    monkeypatch.setattr(main, "save_book", lambda book: None)
    monkeypatch.setattr(main, "_hydrate_book_record", lambda book: book)
    payload = AddBookPayload(
        sourceUrl="https://www.qidian.com/book/1209977/",
        bookKind="长小说",
        language="中文",
    )
    preview = PreviewResponse(
        title="隔离测试书",
        chapterCount=1,
        chapters=[
            ChapterPreview(
                title="第一章",
                url="https://m.qidian.com/chapter/1209977/11/",
            )
        ],
        bookKind="长小说",
    )
    books = [
        await main._create_imported_book(payload, preview, owner_id=owner_id)
        for owner_id in (DEFAULT_ADMIN_USER_ID, reader_id)
    ]

    cache_cookies: list[dict[str, str]] = []

    async def fake_download_chapter(
        book_dir,
        manifest,
        chapter_index,
        *,
        qidian_cookies=None,
    ) -> dict[str, object]:
        cache_cookies.append(dict(qidian_cookies or {}))
        return {"index": chapter_index}

    async def fake_commit(*args, **kwargs) -> None:
        return None

    books_by_id = {book.id: book for book in books}
    monkeypatch.setattr(main, "_is_book_deleted", lambda book_id: False)
    monkeypatch.setattr(main, "_get_book_or_404", lambda book_id: books_by_id[book_id])
    monkeypatch.setattr(main, "_resolve_book_dir", lambda book: tmp_path / book.id)
    monkeypatch.setattr(
        main,
        "_load_or_initialize_manifest",
        lambda book, book_dir: {
            "source_url": book.sourceUrl,
            "chapters": [
                {
                    "index": 1,
                    "title": "第一章",
                    "url": "https://m.qidian.com/chapter/1209977/11/",
                    "file_name": "0001-test.txt",
                }
            ],
        },
    )
    monkeypatch.setattr(main, "_chapter_needs_source_cache", lambda book_dir, chapter: True)
    monkeypatch.setattr(main, "download_chapter_payload", fake_download_chapter)
    monkeypatch.setattr(main, "_commit_source_chapter_payload", fake_commit)
    main.app.state.chapter_manifest_locks = {}

    for book in books:
        await main._cache_source_chapter_by_id(book.id, 1)

    task_cookies: list[dict[str, str]] = []

    async def fake_download_selected(**kwargs) -> None:
        task_cookies.append(dict(kwargs.get("qidian_cookies") or {}))

    monkeypatch.setattr(main, "download_selected_chapters", fake_download_selected)
    monkeypatch.setattr(main, "load_settings", lambda: SimpleNamespace(downloadConcurrency=1))
    for index, book in enumerate(books):
        task = TaskRecord(
            ownerId=book.ownerId,
            id=f"task-{index}",
            bookId=book.id,
            taskType="download",
            chapterIndexes=[1],
            status="running",
            totalCount=1,
            createdAt="2030-01-01T00:00:00Z",
            updatedAt="2030-01-01T00:00:00Z",
        )
        await main._process_download_task(task, book)

    expected = [cookies_by_owner[DEFAULT_ADMIN_USER_ID], cookies_by_owner[reader_id]]
    assert import_cookies == expected
    assert cache_cookies == expected
    assert task_cookies == expected
