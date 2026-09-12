import asyncio
import gzip
import hashlib
import json
from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient

from app import db, scraper_network_security
from app.api.discovery import router
from app.application import create_application
from app.discovery import cache as cache_module
from app.discovery import httpclient, registry, service
from app.discovery.cache import TTLCache
from app.discovery.providers.base import BaseProvider, Channel, FetchResult
from app.security import API_PREFIX


@pytest.fixture(autouse=True)
def isolate_discovery(monkeypatch, tmp_path):
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    cache = TTLCache()
    monkeypatch.setattr(service, "cache", cache)
    monkeypatch.setattr(cache_module, "cache", cache)
    monkeypatch.setattr(service, "_semaphore", asyncio.Semaphore(6))
    registry.clear_provider_caches()


def test_catalog_contains_all_sites_and_distinct_real_channels():
    sites = registry.list_sites()
    assert [site.site for site in sites] == [
        "fanqie",
        "qidian",
        "ciweimao",
        "biqvge",
        "sfacg",
        "shaonianmeng",
        "quark",
        "kakuyomu",
        "bilibili",
        "jm18",
        "copycomic",
        "ores",
        "ehentai",
        "yanmaga",
        "yoyomanga",
    ]
    assert sum(site.channel_count for site in sites) == 218
    for site in sites:
        assert len({channel.key for channel in site.channels}) == site.channel_count
        assert all(channel.site == site.site for channel in site.channels)
    assert {channel.kind for channel in sites[0].channels} == {"rank", "recommend"}
    assert {channel.kind for channel in sites[1].channels} == {"rank"}


def test_catalog_api_requires_connection_token_and_valid_user_session(monkeypatch):
    token = "discovery-test-connection-token"
    monkeypatch.setenv("QINGJUAN_AUTH_TOKEN_SHA256", hashlib.sha256(token.encode()).hexdigest())
    application = create_application(routers=[router], authenticate=True)
    with TestClient(application) as client:
        assert client.get(f"{API_PREFIX}/discovery/sites").status_code == 401
        headers = {"Authorization": f"Bearer {token}"}
        response = client.get(f"{API_PREFIX}/discovery/sites", headers=headers)
        assert response.status_code == 200
        assert len(response.json()["sites"]) == 15
        monkeypatch.setenv("QINGJUAN_MULTI_USER", "1")
        assert client.get(f"{API_PREFIX}/discovery/sites", headers=headers).status_code == 401
        assert (
            client.get(f"{API_PREFIX}/discovery/sites/fanqie/channels/rank_list", headers=headers).status_code
            == 401
        )


@pytest.mark.parametrize("query", ["page=0", "page=1001", "limit=0", "limit=101", "refresh=invalid"])
def test_api_rejects_invalid_pagination_before_network(query):
    application = create_application(routers=[router], api_prefix=API_PREFIX)
    with TestClient(application) as client:
        response = client.get(f"{API_PREFIX}/discovery/sites/fanqie/channels/rank_list?{query}")
    assert response.status_code == 422


@pytest.mark.parametrize("path", ["unknown/channels/rank_list", "fanqie/channels/unknown"])
def test_api_unknown_site_or_channel_is_404(path):
    application = create_application(routers=[router], api_prefix=API_PREFIX)
    with TestClient(application) as client:
        response = client.get(f"{API_PREFIX}/discovery/sites/{path}")
    assert response.status_code == 404
    assert "不存在" in response.json()["detail"]


class FixtureProvider(BaseProvider):
    site = "fixture"
    site_name = "示例站"
    homepage = "https://books.example.test"
    channels = [Channel("rank", "周榜"), Channel("recommend", "编辑推荐", kind="recommend", pageable=False)]
    calls = 0
    fail = False

    async def fetch(self, channel, page=1, limit=20, options=None):
        type(self).calls += 1
        await asyncio.sleep(0.01)
        if self.fail:
            raise RuntimeError("Authorization=secret-token C:\\private\\data.db upstream secret-body")
        return FetchResult(
            items=[
                self.make(
                    channel,
                    title=f"书籍{index}",
                    book_id=str(index),
                    url="https://books.example.test/book/1",
                    cover="file:///private/key",
                    extra={"Cookie": "private-cookie", "localPath": "C:\\private"},
                )
                for index in range(limit + 2)
            ],
            has_more=True,
        )


@pytest.fixture
def fixture_provider(monkeypatch):
    FixtureProvider.calls = 0
    FixtureProvider.fail = False
    monkeypatch.setitem(service.PROVIDERS, "fixture", FixtureProvider)
    return FixtureProvider


async def test_fetch_coalesces_requests_clones_cache_and_refresh_replaces(fixture_provider):
    first, second = await asyncio.gather(
        service.fetch_channel("fixture", "rank", page=2, limit=3),
        service.fetch_channel("fixture", "rank", page=2, limit=3),
    )
    assert fixture_provider.calls == 1
    assert {first.cached, second.cached} == {False, True}
    assert [item.rank for item in first.items] == [4, 5, 6]
    assert first.count == 3 and first.has_more
    assert all(not item.extra and not item.cover for item in first.items)
    first.items[0].title = "changed"
    cached = await service.fetch_channel("fixture", "rank", page=2, limit=3)
    assert cached.items[0].title == "书籍0"
    assert cached.cached
    service.cache.set("channel:other:rank:1:3", "other-site-cache")
    refreshed = await service.fetch_channel("fixture", "rank", page=2, limit=3, refresh=True)
    assert fixture_provider.calls == 2 and not refreshed.cached
    assert (await service.fetch_channel("fixture", "rank", page=2, limit=3)).cached
    assert service.cache.get("channel:other:rank:1:3") == (True, "other-site-cache")


async def test_nonpageable_recommendation_uses_first_page_and_no_more(fixture_provider):
    result = await service.fetch_channel("fixture", "recommend", page=4, limit=3)
    assert result.page == 1 and not result.has_more
    assert all(item.rank is None for item in result.items)
    assert result.kind == "recommend"


async def test_disabled_plugin_hides_cached_results_and_makes_no_request(fixture_provider, monkeypatch):
    await service.fetch_channel("fixture", "rank")
    monkeypatch.setattr(registry, "is_site_plugin_enabled", lambda plugin_id: False)
    assert not registry.list_sites()[-1].enabled
    result = await service.fetch_channel("fixture", "rank", refresh=True)
    assert "已停用" in result.error
    assert not result.items
    assert fixture_provider.calls == 1


async def test_http_rechecks_disable_switch_before_sending(monkeypatch):
    def fail_client(**kwargs):
        return httpx.AsyncClient(
            transport=httpx.MockTransport(
                lambda request: pytest.fail("disabled site must not make an HTTP request")
            )
        )

    monkeypatch.setattr(httpclient, "create_public_http_client", fail_client)
    client = httpclient.SiteHttp("https://example.test", allowed=lambda: False)
    try:
        with pytest.raises(httpclient.UpstreamError, match="已停用"):
            await client.get("/rank")
    finally:
        await client.aclose()


async def test_errors_do_not_leak_or_poison_cache(fixture_provider, caplog):
    fixture_provider.fail = True
    result = await service.fetch_channel("fixture", "rank")
    assert result.error and not result.items
    for value in ["secret-token", "private", "secret-body", "RuntimeError:"]:
        assert value not in result.model_dump_json()
        assert value not in caplog.text
    fixture_provider.fail = False
    result = await service.fetch_channel("fixture", "rank")
    assert result.error is None and result.items
    assert fixture_provider.calls == 2


async def test_timeout_cancels_fetch_and_releases_slot(fixture_provider, monkeypatch):
    monkeypatch.setattr(service, "settings", SimpleNamespace(channel_timeout=0.001))
    result = await service.fetch_channel("fixture", "rank")
    assert "超时" in result.error
    assert not service.cache._pending
    assert service._semaphore._value == 6


async def test_cache_expiry_eviction_and_pending_cleanup():
    cache = TTLCache(ttl=100, max_items=2)
    cache.set("first", 1)
    cache.set("second", 2)
    cache.set("third", 3)
    assert cache.get("first") == (False, None)
    cache._store["third"] = (0, 3)
    assert cache.get("third") == (False, None)

    async def fail():
        raise ValueError("unavailable")

    with pytest.raises(ValueError):
        await cache.get_or_load("error", fail)
    assert not cache._pending
    await cache.aclose()
    assert not cache._store


async def test_http_uses_public_transport_and_rejects_local_urls():
    client = httpclient.SiteHttp("https://example.test")
    assert isinstance(client._client._transport, scraper_network_security.PublicHTTPTransport)
    try:
        with pytest.raises(scraper_network_security.ScraperNetworkSecurityError):
            await client.get("http://127.0.0.1/private")
    finally:
        await client.aclose()


async def test_http_decodes_compressed_json_and_sanitizes_bad_json(monkeypatch):
    async def handler(request):
        if request.url.path == "/bad":
            return httpx.Response(200, text="private upstream secret")
        return httpx.Response(
            200, headers={"Content-Encoding": "gzip"}, content=gzip.compress(b'{"items": []}')
        )

    def make_client(**kwargs):
        return httpx.AsyncClient(transport=httpx.MockTransport(handler))

    monkeypatch.setattr(httpclient, "create_public_http_client", make_client)
    client = httpclient.SiteHttp("https://example.test")
    try:
        assert await client.json("/ok") == {"items": []}
        with pytest.raises(httpclient.UpstreamError) as error:
            await client.json("/bad")
        assert "private" not in str(error.value)
    finally:
        await client.aclose()


async def test_http_bounds_response_size(monkeypatch):
    def make_client(**kwargs):
        return httpx.AsyncClient(
            transport=httpx.MockTransport(
                lambda request: httpx.Response(200, content=b"x" * (8 * 1024 * 1024 + 1))
            )
        )

    monkeypatch.setattr(httpclient, "create_public_http_client", make_client)
    client = httpclient.SiteHttp("https://example.test")
    try:
        with pytest.raises(httpclient.UpstreamError, match="过大"):
            await client.get("/large")
    finally:
        await client.aclose()


async def test_fanqie_rank_and_home_recommendation_mapping(monkeypatch):
    from app.discovery import cache as cache_module
    from app.discovery.providers import fanqie

    monkeypatch.setattr(cache_module, "cache", TTLCache())

    class HTTP:
        async def json(self, url, **kwargs):
            assert kwargs["params"]["offset"] == 0
            return {
                "code": 0,
                "data": {"list": [{"bookId": "123", "bookName": "测试小说", "author": "作者"}]},
            }

        async def text(self, url):
            return (
                "window.__INITIAL_STATE__ = "
                + json.dumps({"home": {"editorList": [{"bookId": "456", "bookName": "编辑书单"}]}})
                + ";"
            )

    provider = fanqie.Provider(http=HTTP())
    rank = await provider.fetch(provider.channel_by_key("rank_list"), page=2)
    assert rank.items[0].title == "测试小说"
    assert rank.items[0].url == "https://fanqienovel.com/page/123"
    assert not rank.has_more
    recommended = await provider.fetch(provider.channel_by_key("recommend_editor"))
    assert recommended.items[0].kind == "recommend"
    assert recommended.items[0].title == "编辑书单"


async def test_bilibili_comic_mapping():
    from app.discovery.providers import bilibili

    class HTTP:
        async def json_post(self, url, **kwargs):
            assert kwargs["json_body"] == {"id": 0}
            return {
                "code": 0,
                "data": {
                    "list": [
                        {
                            "comic_id": 123,
                            "title": "测试漫画",
                            "author_name": ["画师"],
                            "is_finish": 1,
                            "total": 12,
                        }
                    ]
                },
            }

    provider = bilibili.Provider(http=HTTP())
    result = await provider.fetch(provider.channel_by_key("rank_jp"))
    assert result.items[0].url == "https://manga.bilibili.com/detail/mc123"
    assert result.items[0].status == "已完结"
    assert not result.has_more


async def test_biqvge_html_mapping_and_deduplication():
    from app.discovery.providers import biqvge

    class HTTP:
        async def text(self, url):
            return (
                '<div class="item"><img src="/cover.jpg"><dt><a href="/1_123/">示例书</a><span>作者</span></dt><dd>简介</dd></div>'
                * 2
            )

    provider = biqvge.Provider(http=HTTP())
    result = await provider.fetch(provider.channel_by_key("recommend_home"))
    assert len(result.items) == 1
    assert result.items[0].title == "示例书"
    assert result.items[0].author == "作者"
    assert result.items[0].cover == "https://www.b520.cc/cover.jpg"


@pytest.mark.parametrize("total, expected_count", [(170, 1), (11, 0)])
async def test_jm_uses_shared_http_and_local_crypto(monkeypatch, total, expected_count):
    import base64

    from Crypto.Cipher import AES
    from Crypto.Util.Padding import pad
    from jmcomic import JmCryptoTool, JmMagicConstants, JmModuleConfig

    from app.discovery.providers import jm18

    monkeypatch.setattr(JmModuleConfig, "DOMAIN_API_LIST", ["jm.example.test"])
    monkeypatch.setattr(JmModuleConfig, "API_URL_DOMAIN_SERVER_LIST", [])

    class HTTP:
        async def json(self, url, **kwargs):
            timestamp = kwargs["headers"]["tokenparam"].split(",")[0]
            key = JmCryptoTool.md5hex(f"{timestamp}{JmMagicConstants.APP_DATA_SECRET}").encode()
            if url.endswith("/setting"):
                body = {"jm3_version": "2.0.26"}
            else:
                assert url == "https://jm.example.test/categories/filter"
                assert kwargs["params"] == {"page": 2, "order": "", "c": "0", "o": "mv_w"}
                body = {"total": total, "content": [{"id": "123", "name": "示例漫画", "author": "作者"}]}
            payload = json.dumps(body).encode()
            ciphertext = AES.new(key, AES.MODE_ECB).encrypt(pad(payload, 16))
            return {"code": 200, "data": base64.b64encode(ciphertext).decode()}

    provider = jm18.Provider(http=HTTP())
    result = await provider.fetch(provider.channel_by_key("rank_week"), page=2)
    assert len(result.items) == expected_count
    if expected_count:
        assert result.items[0].title == "示例漫画"
        assert result.items[0].rank == 81
        assert result.has_more
    else:
        assert not result.has_more


@pytest.mark.parametrize("channel, count", [("rank_list", 7), ("rank_recommend", 9)])
async def test_fanqie_fixed_rank_rails_do_not_invent_next_page(monkeypatch, channel, count):
    class HTTP:
        def __init__(self, *args, **kwargs):
            pass

        async def json(self, url, **kwargs):
            assert kwargs["params"]["offset"] == 0
            return {
                "code": 0,
                "data": {
                    "total": 10,
                    "list": [{"bookId": str(index), "bookName": f"示例{index}"} for index in range(count)],
                },
            }

        async def aclose(self):
            pass

    monkeypatch.setattr(service, "SiteHttp", HTTP)
    site = next(site for site in registry.list_sites() if site.site == "fanqie")
    assert not next(item for item in site.channels if item.key == channel).pageable
    first = await service.fetch_channel("fanqie", channel, page=1, limit=100)
    second = await service.fetch_channel("fanqie", channel, page=2, limit=100)
    assert first.count == second.count == count
    assert first.page == second.page == 1
    assert not first.has_more and not second.has_more
    assert first.items[0].rank == second.items[0].rank == 1


async def test_fanqie_category_rank_keeps_real_next_page_with_limit_100():
    from app.discovery.providers.fanqie import Provider

    class HTTP:
        async def json(self, url, **kwargs):
            assert kwargs["params"]["limit"] == 100
            offset = kwargs["params"]["offset"]
            return {
                "code": 0,
                "data": {
                    "total_num": 100,
                    "book_list": [
                        {
                            "bookId": str(offset + index),
                            "bookName": f"示例{offset + index}",
                            "currentPos": offset + index,
                        }
                        for index in range(1, 101)
                    ],
                },
            }

    provider = Provider(http=HTTP())
    channel = provider.channel_by_key("rank_hot_male")
    first = await provider.fetch(channel, page=1, limit=100)
    second = await provider.fetch(channel, page=2, limit=100)
    assert first.has_more and second.has_more
    assert second.items[0].rank == 101
    assert {item.book_id for item in first.items}.isdisjoint(item.book_id for item in second.items)


async def test_qidian_new_http_session_gets_its_own_csrf_before_paging():
    from app.discovery.providers.qidian import Provider

    class HTTP:
        def __init__(self, token):
            self.token = token
            self.bootstrapped = False

        async def get(self, url):
            self.bootstrapped = True
            return httpx.Response(
                200,
                request=httpx.Request("GET", url),
                headers={"Set-Cookie": f"_csrfToken={self.token}; Path=/"},
            )

        async def json(self, url, **kwargs):
            assert self.bootstrapped, "new HTTP sessions must get their own anonymous cookie"
            assert kwargs["params"]["_csrfToken"] == self.token
            return {
                "code": 0,
                "data": {
                    "isLast": False,
                    "records": [{"bid": str(kwargs["params"]["pageNum"]), "bName": "示例作品"}],
                },
            }

    first = Provider(http=HTTP("first-session"))
    second = Provider(http=HTTP("second-session"))
    channel = first.channel_by_key("rank_yuepiao")
    a = await first.fetch(channel, page=1, limit=100)
    b = await second.fetch(channel, page=2, limit=100)
    assert a.items[0].book_id == "1" and b.items[0].book_id == "2"
    assert a.has_more and b.has_more


async def test_copycomic_caps_upstream_page_size_without_skipping_items():
    from app.discovery.providers.copycomic import Provider

    class HTTP:
        async def json(self, url, **kwargs):
            assert kwargs["params"]["limit"] == 20
            assert kwargs["params"]["offset"] == 20
            return {
                "code": 200,
                "results": {
                    "total": 100,
                    "list": [{"sort": 21, "comic": {"path_word": "sample", "name": "示例漫画"}}],
                },
            }

    provider = Provider(http=HTTP())
    result = await provider.fetch(provider.channel_by_key("rank_day"), page=2, limit=100)
    assert result.items[0].rank == 21 and result.has_more


async def test_qidian_missing_rank_uses_native_twenty_item_page(monkeypatch):
    from app.discovery.providers.qidian import Provider

    async def rank_api(self, channel, page, opts, gender):
        return [{"bid": "123", "bName": "测试小说"}], False

    monkeypatch.setattr(Provider, "_rank_api", rank_api)
    result = await service.fetch_channel("qidian", "rank_yuepiao", page=2, limit=100)
    assert result.error is None
    assert result.items[0].rank == 21


async def test_ciweimao_missing_rank_uses_native_ten_item_page(monkeypatch):
    from app.discovery.providers.ciweimao import Provider

    async def get(self, url, channel):
        return '<li data-book-id="123"><h3 class="tit"><a href="/book/123">测试小说</a></h3></li>'

    monkeypatch.setattr(Provider, "_get", get)
    result = await service.fetch_channel("ciweimao", "rank_click", page=2, limit=100)
    assert result.error is None
    assert result.items[0].rank == 11


async def test_ehentai_ban_page_returns_actionable_sanitized_error(monkeypatch):
    from app.discovery.providers import ehentai

    async def throttle():
        return None

    class HTTP:
        def __init__(self, *args, **kwargs):
            pass

        async def get(self, url):
            return httpx.Response(
                200, text="This IP address has been temporarily banned due to an excessive request rate"
            )

        async def aclose(self):
            pass

    monkeypatch.setattr(service, "SiteHttp", HTTP)
    monkeypatch.setattr(ehentai, "_throttle", throttle)
    result = await service.fetch_channel("ehentai", "toplist_alltime")
    assert "限制当前网络访问" in result.error
    assert not result.items
    assert "This IP address" not in result.model_dump_json()
