from __future__ import annotations

from urllib.parse import parse_qs

import httpx
import pytest

from app import scraper
from app.models import AddBookPayload, BookSourceRecord, PreviewResponse
from app.site_plugins import biqvge_client

TXT80_SEARCH_HTML = """
<ul>
  <li class="searchresult">
    <a href="/txt/151585.html"><img data-original="//img.txt80.net/txt80.jpg"></a>
    <h3><a href="/txt/151585.html"><span class="hot">测试作品</span></a></h3>
    <p><i class="fa fa-user-circle-o"></i> 作者甲&nbsp;</p>
    <p class="searchresult_p">开场&amp;hellip;继续&amp;amp;amp;amp;emsp;正文。</p>
    <span>玄幻 / 连载</span>
    <a href="/read/151585/86106198.html">第一章</a>
  </li>
  <li class="searchresult">
    <h3><a href="/txt/151585.html">同站重复作品</a></h3>
  </li>
</ul>
"""


MIRROR_CATALOG_HTML = """
<div class="item">
  <img src="../files/article/image/2/2157/2157s.jpg">
  <dl>
    <dt><a href="/2_2157/">测试作品</a><span>作者乙</span></dt>
    <dd>镜像站的作品简介 &amp; 更多内容。</dd>
  </dl>
</div>
<div class="item">
  <dl>
    <dt><a href="/2_2157/">同站重复作品</a><span>作者乙</span></dt>
  </dl>
</div>
<div class="item">
  <dl><dt><a href="/not-a-book/">应忽略</a></dt></dl>
</div>
"""


MIRROR_BOOK_HTML = """
<head>
  <meta property="og:novel:book_name" content="镜像测试书">
  <meta content="作者乙" property="og:novel:author">
  <meta property="og:novel:category" content="玄幻小说">
  <meta property="og:novel:status" content="完本">
  <meta property="og:description" content="第一行 &amp; 第二行">
  <meta property="og:image" content="../files/article/image/2/2157/2157s.jpg">
  <meta property="og:novel:latest_chapter_name" content="第二章 宇宙">
  <meta property="og:novel:latest_chapter_url" content="/2_2157/154384562.htm">
  <meta property="og:novel:update_time" content="2026-08-22">
</head>
<body>
  <div id="list">
    <dt>《镜像测试书》最新章节</dt>
    <a href="/2_2157/154384562.htm">第二章 宇宙</a>
    <dt>《镜像测试书》正文</dt>
    <a href="/2_2157/154384561.html">第一章 启程</a>
    <a href="https://www.b520.cc/2_2157/154384562.htm">第二章 宇宙</a>
    <a href="/2_2157/154384561.html">重复第一章</a>
    <a href="/2_2157/">作品目录</a>
  </div>
</body>
"""


TXT80_BOOK_HTML = """
<head>
  <meta property="og:novel:book_name" content="八零测试书">
  <meta property="og:novel:author" content="作者甲">
  <meta property="og:description" content="八零简介">
  <meta property="og:image" content="http://img.test/txt80-cover.jpg">
  <meta property="og:novel:lastest_chapter_name" content="第三章">
  <meta property="og:novel:lastest_chapter_url"
        content="http://www.txt80.net/read/151585/103.html">
</head>
<body>
  <section class="latest-chapters">
    <a href="/read/151585/103.html">第三章</a>
    <a href="/read/151585/102.html">第二章</a>
  </section>
  <ul id="ul_all_chapters" class="full-catalog">
    <a href="/read/151585/101.html">第一章</a>
    <a href="/read/151585/102.html">第二章</a>
    <a href="/read/151585/103.html">第三章</a>
  </ul>
  <a href="/read/151585/101.html">开始阅读</a>
</body>
"""


MIRROR_CHAPTER_HTML = """
<meta property="og:novel:book_name" content="镜像测试书">
<h1>第一章 &amp; 启程</h1>
<div id="content">
  <p>\ufeff第一段正文。</p>
  <script>window.bad = "不能进入正文";</script>
  <p>第二段 &amp; 更多。</p>
</div>
"""


@pytest.fixture(autouse=True)
def _reset_biqvge_catalog_cache():
    biqvge_client.clear_catalog_cache()
    yield
    biqvge_client.clear_catalog_cache()


def test_biqvge_resource_urls_are_canonical_and_host_limited() -> None:
    txt80 = biqvge_client.book_resource_from_url("http://www.txt80.net/read/151585/86106198_2.html")
    b520 = biqvge_client.book_resource_from_url("https://www.b520.cc/2_2157/")
    blqukan = biqvge_client.book_resource_from_url("https://www.blqukan.cc/38_38836/802853496.htm")

    assert txt80 is not None
    assert (txt80.site, txt80.book_id, txt80.chapter_id, txt80.page) == (
        "txt80",
        "151585",
        "86106198",
        2,
    )
    assert b520 is not None
    assert (b520.site, b520.book_id, b520.chapter_id) == ("b520", "2157", None)
    assert blqukan is not None
    assert (blqukan.site, blqukan.book_id, blqukan.chapter_id) == (
        "blqukan",
        "38836",
        "802853496",
    )
    assert biqvge_client.book_resource_from_url("https://attacker.test/2_2157/") is None
    assert biqvge_client.book_resource_from_url("ftp://www.b520.cc/2_2157/") is None

    assert biqvge_client.canonical_book_url("txt80", "151585") == "http://www.txt80.net/txt/151585.html"
    assert biqvge_client.canonical_book_url("b520", "2157") == "https://www.b520.cc/2_2157/"
    assert (
        biqvge_client.canonical_chapter_url("blqukan", "38836", "802853496")
        == "https://www.blqukan.cc/38_38836/802853496.html"
    )


def test_biqvge_parses_txt80_search_and_mirror_catalog() -> None:
    txt80 = biqvge_client.parse_search_page(TXT80_SEARCH_HTML, "txt80")
    b520 = biqvge_client.parse_catalog_page(
        MIRROR_CATALOG_HTML,
        "b520",
        category="玄幻小说",
    )

    assert len(txt80) == 1
    assert txt80[0]["title"] == "测试作品"
    assert txt80[0]["author"] == "作者甲"
    assert txt80[0]["synopsis"] == "开场…继续 正文。"
    assert txt80[0]["latest_chapter_id"] == "86106198"
    assert txt80[0]["latest_chapter_url"] == (
        "http://www.txt80.net/read/151585/86106198.html"
    )
    assert txt80[0]["url"] == "http://www.txt80.net/txt/151585.html"
    assert str(txt80[0].get("cover") or "").startswith("http")

    assert len(b520) == 1
    assert b520[0]["title"] == "测试作品"
    assert b520[0]["author"] == "作者乙"
    assert b520[0].get("category") == "玄幻小说"
    assert b520[0]["synopsis"] == "镜像站的作品简介 & 更多内容。"
    assert b520[0]["url"] == "https://www.b520.cc/2_2157/"
    assert b520[0]["cover"] == ("https://www.b520.cc/files/article/image/2/2157/2157s.jpg")


def test_biqvge_parses_mirror_book_metadata_and_full_catalog() -> None:
    book = biqvge_client.parse_book_page(
        MIRROR_BOOK_HTML,
        "https://www.b520.cc/2_2157/",
    )

    assert book["title"] == "镜像测试书"
    assert book["author"] == "作者乙"
    assert book["category"] == "玄幻小说"
    assert book["status"] == "完本"
    assert book["synopsis"] == "第一行 & 第二行"
    assert book["cover"] == "https://www.b520.cc/files/article/image/2/2157/2157s.jpg"
    assert [chapter["id"] for chapter in book["chapters"]] == ["154384561", "154384562"]
    assert [chapter["title"] for chapter in book["chapters"]] == [
        "第一章 启程",
        "第二章 宇宙",
    ]
    assert [chapter["url"] for chapter in book["chapters"]] == [
        "https://www.b520.cc/2_2157/154384561.html",
        "https://www.b520.cc/2_2157/154384562.html",
    ]
    assert book["latest_chapter_id"] == "154384562"
    assert book["update_time"] == "2026-08-22"
    assert book["count"] == 2


def test_biqvge_txt80_catalog_deduplicates_latest_block_in_reading_order() -> None:
    book = biqvge_client.parse_book_page(
        TXT80_BOOK_HTML,
        "http://www.txt80.net/txt/151585.html",
    )

    assert book["title"] == "八零测试书"
    assert [chapter["id"] for chapter in book["chapters"]] == ["101", "102", "103"]
    assert [chapter["title"] for chapter in book["chapters"]] == ["第一章", "第二章", "第三章"]


def test_biqvge_rejects_cover_outside_the_current_provider_domain() -> None:
    html = MIRROR_BOOK_HTML.replace(
        "../files/article/image/2/2157/2157s.jpg",
        "http://127.0.0.1/private-cover.jpg",
    )

    book = biqvge_client.parse_book_page(html, "https://www.b520.cc/2_2157/")

    assert book["cover"] == ""


def test_biqvge_parses_mirror_chapter_text_without_scripts() -> None:
    chapter = biqvge_client.parse_chapter_page(
        MIRROR_CHAPTER_HTML,
        "https://www.b520.cc/2_2157/154384561.html",
    )
    text = chapter["text"]

    assert "第一段正文。" in text
    assert "第二段 & 更多。" in text
    assert "\ufeff" not in text
    assert text.index("第一段正文。") < text.index("第二段 & 更多。")
    assert "不能进入正文" not in text
    assert chapter["title"] == "第一章 & 启程"
    assert chapter["book_title"] == "镜像测试书"
    assert chapter["pages"] == 1


@pytest.mark.asyncio
async def test_biqvge_search_aggregates_sites_and_isolates_one_site_failure() -> None:
    requests: list[httpx.Request] = []

    def transport(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.url.host == "www.txt80.net":
            if request.method == "GET" and request.url.path == "/":
                return httpx.Response(
                    200,
                    text='<form action="/searchf0.html"><input name="searchkey"></form>',
                    request=request,
                )
            assert request.method == "POST" and request.url.path == "/searchf0.html"
            return httpx.Response(200, text=TXT80_SEARCH_HTML, request=request)
        if request.url.host == "www.b520.cc":
            return httpx.Response(200, text=MIRROR_CATALOG_HTML, request=request)
        if request.url.host == "www.blqukan.cc":
            return httpx.Response(503, text="temporary failure", request=request)
        raise AssertionError(f"unexpected request: {request.method} {request.url}")

    async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as client:
        results = await biqvge_client.search_books(client, "测试作品", 20)
        repeated = await biqvge_client.search_books(client, "测试作品", 20)

    resources = [biqvge_client.book_resource_from_url(item["url"]) for item in results]
    assert [(item.site, item.book_id) for item in resources if item is not None] == [
        ("txt80", "151585"),
        ("b520", "2157"),
    ]
    assert [item["title"] for item in results] == ["测试作品", "测试作品"]
    assert repeated == results
    txt80_request = next(
        request
        for request in requests
        if request.url.host == "www.txt80.net" and request.method == "POST"
    )
    assert txt80_request.url.path == "/searchf0.html"
    assert parse_qs(txt80_request.content.decode()) == {
        "searchkey": ["测试作品"],
        "searchtype": ["all"],
    }
    assert any(request.url.host == "www.blqukan.cc" for request in requests)
    failed_site_requests = [request for request in requests if request.url.host == "www.blqukan.cc"]
    assert len(failed_site_requests) == 3


@pytest.mark.asyncio
async def test_biqvge_txt80_search_route_falls_back_when_homepage_has_no_form() -> None:
    requested_paths: list[tuple[str, str]] = []

    def transport(request: httpx.Request) -> httpx.Response:
        requested_paths.append((request.method, request.url.path))
        if request.method == "GET" and request.url.path == "/":
            return httpx.Response(200, text="<html>no search form</html>", request=request)
        if request.url.path == "/searchf0.html":
            return httpx.Response(404, request=request)
        if request.url.path == "/search.html":
            return httpx.Response(200, text=TXT80_SEARCH_HTML, request=request)
        raise AssertionError(f"unexpected request: {request.method} {request.url}")

    async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as client:
        results = await biqvge_client._search_txt80(client, "测试作品")

    assert [item["title"] for item in results] == ["测试作品"]
    assert requested_paths == [
        ("GET", "/"),
        ("POST", "/searchf0.html"),
        ("POST", "/search.html"),
        ("POST", "/search.html"),
    ]


@pytest.mark.asyncio
async def test_biqvge_rejects_cross_site_redirect_before_following_it() -> None:
    requested_urls: list[str] = []

    def transport(request: httpx.Request) -> httpx.Response:
        requested_urls.append(str(request.url))
        if request.url.host == "www.txt80.net":
            return httpx.Response(
                302,
                headers={"Location": "http://127.0.0.1/private"},
                request=request,
            )
        raise AssertionError(f"redirect target must not be requested: {request.url}")

    async with httpx.AsyncClient(
        transport=httpx.MockTransport(transport),
        follow_redirects=True,
    ) as client:
        with pytest.raises(biqvge_client.BiqvgeError, match="非本站重定向"):
            await biqvge_client._fetch_text(
                client,
                biqvge_client.SITES["txt80"],
                "http://www.txt80.net/search19.html",
            )

    assert requested_urls == ["http://www.txt80.net/search19.html"]


@pytest.mark.asyncio
async def test_biqvge_scraper_preserves_result_provider_name(monkeypatch) -> None:
    async def fake_search(client: httpx.AsyncClient, keyword: str, limit: int):
        return [
            {
                "site": "b520",
                "site_name": "笔趣阁 5200",
                "book_id": "2157",
                "title": keyword,
                "author": "作者乙",
                "synopsis": "简介",
                "cover": None,
                "url": "https://www.b520.cc/2_2157/",
            }
        ]

    monkeypatch.setattr(scraper, "search_biqvge_books", fake_search)
    source = BookSourceRecord(
        id="source-builtin-biqvge",
        name="笔趣阁",
        baseUrl="https://www.b520.cc",
        bookKind="长小说",
        language="中文",
        origin="builtin",
    )

    results = await scraper._search_biqvge_works(source, "测试作品", 8)

    assert results[0].providerName == "笔趣阁 5200"


@pytest.mark.asyncio
async def test_biqvge_txt80_chapter_fetch_joins_all_pages_once() -> None:
    requested_paths: list[str] = []

    def transport(request: httpx.Request) -> httpx.Response:
        requested_paths.append(request.url.path)
        if request.url.path == "/read/151585/86106198.html":
            return httpx.Response(
                200,
                text="""
                  <meta property="og:title" content="八零测试书">
                  <p class="style_h1">第一章</p>
                  <article id="article"><p>第一页第一段。</p><p>第一页第二段。</p></article>
                  <a id="next_url" href="/read/151585/86106198_2.html">下一页</a>
                """,
                request=request,
            )
        if request.url.path == "/read/151585/86106198_2.html":
            return httpx.Response(
                200,
                text='<article id="article"><p>第二页正文。</p></article>',
                request=request,
            )
        raise AssertionError(f"unexpected request: {request.url}")

    async with httpx.AsyncClient(transport=httpx.MockTransport(transport)) as client:
        chapter = await biqvge_client.get_chapter(
            client,
            "http://www.txt80.net/read/151585/86106198.html",
        )

    text = chapter["text"]
    assert requested_paths == [
        "/read/151585/86106198.html",
        "/read/151585/86106198_2.html",
    ]
    assert text.count("第一页第一段。") == 1
    assert text.count("第一页第二段。") == 1
    assert text.count("第二页正文。") == 1
    assert text.index("第一页第一段。") < text.index("第二页正文。")


@pytest.mark.asyncio
async def test_biqvge_scraper_dispatches_search_preview_and_chapter(monkeypatch) -> None:
    calls: list[tuple[str, str]] = []

    async def fake_search(source: BookSourceRecord, keyword: str, limit: int):
        calls.append(("search", keyword))
        assert source.id == "source-builtin-biqvge"
        assert limit == 8
        return []

    async def fake_preview(source_url: str, payload: AddBookPayload) -> PreviewResponse:
        calls.append(("preview", source_url))
        return PreviewResponse(
            title="分派测试书",
            chapterCount=1,
            chapters=[
                {
                    "title": "第一章",
                    "url": "https://www.b520.cc/2_2157/154384561.html",
                }
            ],
            bookKind=payload.bookKind,
        )

    async def fake_chapter(client, chapter_url: str, chapter_title: str = ""):
        calls.append(("chapter", chapter_url))
        return scraper.ChapterFetchResult(text="分派正文", image_urls=[])

    monkeypatch.setattr(scraper, "is_site_plugin_enabled", lambda _plugin_id: True)
    monkeypatch.setattr(scraper, "_search_biqvge_works", fake_search)
    monkeypatch.setattr(scraper, "_preview_biqvge", fake_preview)
    monkeypatch.setattr(scraper, "_fetch_biqvge_chapter_data", fake_chapter)

    source = BookSourceRecord(
        id="source-builtin-biqvge",
        name="笔趣阁",
        baseUrl="https://www.b520.cc",
        bookKind="长小说",
        language="中文",
        origin="builtin",
    )
    assert await scraper.search_builtin_site_books(source, "测试") == []

    preview = await scraper.preview_from_url(
        AddBookPayload(
            sourceUrl="https://www.b520.cc/2_2157/",
            bookKind="长小说",
            language="中文",
        )
    )
    async with httpx.AsyncClient() as client:
        chapter = await scraper._fetch_chapter_data(
            client,
            "https://www.b520.cc/2_2157/154384561.html",
            "第一章",
        )

    assert preview.title == "分派测试书"
    assert chapter.text == "分派正文"
    assert calls == [
        ("search", "测试"),
        ("preview", "https://www.b520.cc/2_2157/"),
        ("chapter", "https://www.b520.cc/2_2157/154384561.html"),
    ]
