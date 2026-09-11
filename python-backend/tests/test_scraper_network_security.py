from __future__ import annotations

import asyncio
import ipaddress
import json
import struct
from pathlib import Path
from types import SimpleNamespace

import httpcore
import httpx
import pytest

from app import scraper
from app.model_endpoint_security import ValidatedModelNetworkBackend
from app.models import AddBookPayload, BookSourceRecord


class WireStream(httpcore.AsyncNetworkStream):
    def __init__(self, response: bytes):
        self.response = response
        self.sni = None
        self.request_ready = asyncio.Event()

    async def read(self, max_bytes, timeout=None):
        await self.request_ready.wait()
        response, self.response = self.response, b""
        return response

    async def write(self, buffer, timeout=None):
        self.request_ready.set()

    async def aclose(self):
        pass

    async def start_tls(self, ssl_context, server_hostname=None, timeout=None):
        self.sni = server_hostname
        return self


class WireBackend(httpcore.AsyncNetworkBackend):
    def __init__(self, responses):
        self.responses = iter(responses)
        self.connected = []
        self.streams = []

    async def connect_tcp(self, host, port, **kwargs):
        self.connected.append((host, port))
        stream = WireStream(next(self.responses))
        self.streams.append(stream)
        return stream


def http_response(body=b"<title>Book</title><p>chapter</p>", *, location=None):
    if location:
        return f"HTTP/1.1 302 Found\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode()
    return (
        b"HTTP/1.1 200 OK\r\nContent-Length: "
        + str(len(body)).encode()
        + b"\r\nConnection: close\r\n\r\n"
        + body
    )


def wire_client(monkeypatch, responses, resolver=None):
    from app.scraper_network_security import PublicHTTPTransport, create_public_http_client

    wire = WireBackend(responses)
    client = create_public_http_client(timeout=1, resolver=resolver)
    assert isinstance(client._transport, PublicHTTPTransport)
    assert isinstance(client._transport._pool._network_backend, ValidatedModelNetworkBackend)
    client._transport._pool._network_backend._delegate = wire
    monkeypatch.setattr(scraper, "_build_http_client", lambda: client)
    monkeypatch.setattr(scraper, "is_site_plugin_enabled", lambda _: True)
    return client, wire


@pytest.mark.asyncio
async def test_public_preview_pins_ip_and_preserves_tls_hostname(monkeypatch):
    async def resolver(host, port):
        assert (host, port) == ("books.example", 443)
        return (ipaddress.ip_address("93.184.216.34"),)

    _, wire = wire_client(monkeypatch, [http_response()], resolver)
    preview = await scraper.preview_from_url(
        AddBookPayload(sourceUrl="https://books.example/book", bookKind="长小说", language="中文")
    )
    assert preview.title == "Book"
    assert wire.streams[0].sni == "books.example"
    assert wire.connected == [("93.184.216.34", 443)]


@pytest.mark.asyncio
async def test_chapter_redirect_failure_preserves_file(monkeypatch, tmp_path):
    from app.scraper_network_security import ScraperNetworkSecurityError

    async def resolver(host, port):
        return (ipaddress.ip_address("93.184.216.34"),)

    client, wire = wire_client(monkeypatch, [http_response(location="http://127.0.0.1/secret")], resolver)
    chapter = tmp_path / "chapter.txt"
    chapter.write_text("old content", encoding="utf-8")
    async with client:
        with pytest.raises(ScraperNetworkSecurityError):
            await scraper._download_single_chapter(
                client, tmp_path, 1, {"file_name": chapter.name, "url": "https://books.example/chapter"}
            )
    assert chapter.read_text(encoding="utf-8") == "old content"
    assert wire.connected == [("93.184.216.34", 443)]


def test_curl_pins_ip_and_revalidates_redirect_without_environment_proxy(monkeypatch):
    from curl_cffi import CurlOpt

    from app import scraper_network_security as security

    calls = []

    async def resolver(host, port):
        return (ipaddress.ip_address("10.0.0.1" if host == "internal.example" else "93.184.216.34"),)

    class Session:
        curl_options = {}

        def get(self, url, **kwargs):
            calls.append((url, dict(self.curl_options), kwargs))
            return SimpleNamespace(status_code=302, headers={"Location": "http://internal.example/"})

    monkeypatch.setattr(security, "resolve_model_endpoint_addresses", resolver)
    session = Session()
    with pytest.raises(security.ScraperNetworkSecurityError):
        security.public_curl_get(session, "https://books.example/chapter", timeout=10)
    assert len(calls) == 1
    assert calls[0][1][CurlOpt.RESOLVE] == ["books.example:443:93.184.216.34"]
    assert calls[0][1][CurlOpt.PROXY] == ""
    assert calls[0][2]["allow_redirects"] is False
    assert session.curl_options == {}


@pytest.mark.asyncio
@pytest.mark.parametrize("address, expected_status", [("93.184.216.34", 0), ("127.0.0.1", 2)])
async def test_browser_proxy_connects_only_to_validated_public_ip(address, expected_status):
    from app.scraper_network_security import PublicBrowserProxy

    async def resolver(host, port):
        assert (host, port) == ("books.example", 443)
        return (ipaddress.ip_address(address),)

    wire = WireBackend([b"test"])
    async with PublicBrowserProxy(resolver=resolver, delegate=wire) as proxy:
        reader, writer = await asyncio.open_connection("127.0.0.1", proxy.port)
        writer.write(b"\x05\x01\x00")
        await writer.drain()
        assert await reader.readexactly(2) == b"\x05\x00"
        domain = b"books.example"
        writer.write(b"\x05\x01\x00\x03" + bytes([len(domain)]) + domain + struct.pack("!H", 443))
        await writer.drain()
        reply = await asyncio.wait_for(reader.readexactly(10), timeout=2)
        assert reply[1] == expected_status
        writer.close()
        await writer.wait_closed()
    assert wire.connected == ([("93.184.216.34", 443)] if expected_status == 0 else [])


@pytest.mark.asyncio
async def test_browser_fallback_launches_with_proxy_and_no_direct_network(monkeypatch):
    launch_args = []
    commands = []

    class Connection:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            pass

    async def resolved(_url):
        return "books.example", 443, (ipaddress.ip_address("93.184.216.34"),)

    async def target(*args):
        return "ws://127.0.0.1/test"

    async def send(_socket, method, *args, **kwargs):
        commands.append(method)
        return {}

    async def evaluate(_socket, expression):
        return {
            "ready": True,
            "document.title || ''": "Book",
            "location.href || ''": "https://books.example/",
            "document.documentElement.outerHTML || ''": "<title>Book</title>",
        }[expression]

    def launch(args, **kwargs):
        launch_args.extend(args)
        return SimpleNamespace(kill=lambda: None, wait=lambda **kw: None)

    monkeypatch.setattr(scraper, "resolve_public_url", resolved)
    monkeypatch.setattr(scraper, "_find_browser_executable", lambda: Path("chromium"))
    monkeypatch.setattr(scraper, "_wait_for_edge_page_target", target)
    monkeypatch.setattr(scraper, "_cdp_send_command", send)
    monkeypatch.setattr(scraper, "_cdp_evaluate", evaluate)
    monkeypatch.setattr(scraper.websockets, "connect", lambda *args, **kwargs: Connection())
    monkeypatch.setattr(scraper.subprocess, "Popen", launch)
    result = await scraper._fetch_with_edge_cdp(
        "https://books.example/", ready_expression="ready", headless=True
    )
    assert result.html == "<title>Book</title>"
    assert any(arg.startswith("--proxy-server=socks5://127.0.0.1:") for arg in launch_args)
    assert "--proxy-bypass-list=<-loopback>" in launch_args
    assert "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1" in launch_args
    assert "--disable-quic" in launch_args
    assert "--force-webrtc-ip-handling-policy=disable_non_proxied_udp" in launch_args
    assert commands[-1] == "Browser.close"


@pytest.mark.asyncio
async def test_browser_proxy_shutdown_closes_incomplete_handshake():
    from app.scraper_network_security import PublicBrowserProxy

    async with PublicBrowserProxy() as proxy:
        reader, writer = await asyncio.open_connection("127.0.0.1", proxy.port)
        writer.write(b"\x05\x01\x00")
        await writer.drain()
        assert await asyncio.wait_for(reader.readexactly(2), timeout=1) == b"\x05\x00"
    assert await asyncio.wait_for(reader.read(1), timeout=1) == b""
    writer.close()
    await writer.wait_closed()


@pytest.mark.asyncio
async def test_browser_private_url_is_rejected_before_launch(monkeypatch):
    from app.scraper_network_security import ScraperNetworkSecurityError

    def unexpected_launch(*args, **kwargs):
        raise AssertionError("browser must not launch")

    monkeypatch.setattr(scraper.subprocess, "Popen", unexpected_launch)
    with pytest.raises(ScraperNetworkSecurityError):
        await scraper._fetch_with_edge_cdp("http://127.0.0.1/", ready_expression="true", headless=True)


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "target",
    [
        "http://127.0.0.1/a",
        "http://10.0.0.1/a",
        "http://169.254.169.254/latest",
        "http://[::ffff:127.0.0.1]/a",
    ],
)
async def test_direct_private_preview_never_connects(monkeypatch, target):
    from app.scraper_network_security import ScraperNetworkSecurityError

    async def resolver(host, port):
        return (ipaddress.ip_address(host),)

    _, wire = wire_client(monkeypatch, [], resolver)
    with pytest.raises(ScraperNetworkSecurityError):
        await scraper.preview_from_url(AddBookPayload(sourceUrl=target, bookKind="长小说", language="中文"))
    assert wire.connected == []


@pytest.mark.asyncio
async def test_public_redirect_to_private_domain_cannot_connect(monkeypatch):
    from app.scraper_network_security import ScraperNetworkSecurityError

    async def resolver(host, port):
        return (ipaddress.ip_address("10.0.0.1" if host == "internal.example" else "93.184.216.34"),)

    _, wire = wire_client(monkeypatch, [http_response(location="https://internal.example/secret")], resolver)
    with pytest.raises(ScraperNetworkSecurityError):
        await scraper.preview_from_url(
            AddBookPayload(sourceUrl="https://books.example/", bookKind="长小说", language="中文")
        )
    assert wire.connected == [("93.184.216.34", 443)]


@pytest.mark.asyncio
async def test_mixed_dns_answer_is_rejected_before_connect(monkeypatch):
    from app.scraper_network_security import ScraperNetworkSecurityError

    async def resolver(host, port):
        return (ipaddress.ip_address("93.184.216.34"), ipaddress.ip_address("::1"))

    client, wire = wire_client(monkeypatch, [], resolver)
    async with client:
        with pytest.raises(ScraperNetworkSecurityError):
            await client.get("http://books.example/a")
    assert wire.connected == []


@pytest.mark.asyncio
async def test_dns_rebinding_on_next_connection_is_rejected(monkeypatch):
    from app.scraper_network_security import ScraperNetworkSecurityError

    answers = iter(["93.184.216.34", "127.0.0.1"])

    async def resolver(host, port):
        return (ipaddress.ip_address(next(answers)),)

    client, wire = wire_client(monkeypatch, [http_response()], resolver)
    async with client:
        assert (await client.get("http://books.example/first")).status_code == 200
        with pytest.raises(ScraperNetworkSecurityError):
            await client.get("http://books.example/second")
    assert wire.connected == [("93.184.216.34", 80)]


@pytest.mark.asyncio
async def test_cover_redirect_cannot_use_model_private_allowlist(monkeypatch, tmp_path):
    from app.scraper_network_security import ScraperNetworkSecurityError

    monkeypatch.setenv("QINGJUAN_MODEL_ENDPOINT_ALLOWLIST", "http://10.0.0.1")

    async def resolver(host, port):
        return (ipaddress.ip_address("93.184.216.34"),)

    client, wire = wire_client(monkeypatch, [http_response(location="http://10.0.0.1/cover")], resolver)
    async with client:
        with pytest.raises(ScraperNetworkSecurityError):
            await scraper._download_cover_image(
                client, tmp_path, "https://books.example/cover", "https://books.example/"
            )
    assert wire.connected == [("93.184.216.34", 443)]


def mock_fake_ip_dns(monkeypatch, handler, *, system_addresses=("198.18.1.30",)):
    from app import model_endpoint_security
    from app import scraper_network_security as security

    requests = []

    async def system_resolver(host, port):
        return tuple(ipaddress.ip_address(address) for address in system_addresses)

    def doh_transport(*, allowlist, resolver):
        assert allowlist == frozenset()

        async def respond(request):
            pinned = await resolver(request.url.host, request.url.port or 443)
            requests.append((request, tuple(str(address) for address in pinned)))
            return handler(request)

        return httpx.MockTransport(respond)

    monkeypatch.setattr(security, "resolve_model_endpoint_addresses", system_resolver)
    monkeypatch.setattr(model_endpoint_security, "resolve_model_endpoint_addresses", system_resolver)
    monkeypatch.setattr(security, "ValidatedModelHTTPTransport", doh_transport)
    return requests


def dns_response(request, *, ipv4="93.184.216.34", ipv6="2606:4700:4700::1111"):
    record_type = int(request.url.params["type"])
    address = ipv4 if record_type == 1 else ipv6
    return httpx.Response(
        200,
        json={
            "Status": 0,
            "Answer": [
                {"type": 5, "data": "cdn.example."},
                *([{"type": record_type, "data": address}] if address else []),
            ],
        },
    )


@pytest.mark.asyncio
@pytest.mark.parametrize("system_addresses", [("198.18.1.30",), ("198.19.1.30", "2606:4700::1111")])
async def test_fake_ip_dns_recovers_public_preview_and_pins_real_ip(monkeypatch, system_addresses):
    requests = mock_fake_ip_dns(monkeypatch, dns_response, system_addresses=system_addresses)
    _, wire = wire_client(monkeypatch, [http_response()])

    preview = await scraper.preview_from_url(
        AddBookPayload(sourceUrl="https://books.example/book", bookKind="长小说", language="中文")
    )

    assert preview.title == "Book"
    assert wire.connected == [("93.184.216.34", 443)]
    assert wire.streams[0].sni == "books.example"
    assert {request.url.params["type"] for request, _ in requests} == {"1", "28"}
    assert all(request.url.params["name"] == "books.example" for request, _ in requests)
    assert all(request.headers["accept"] == "application/dns-json" for request, _ in requests)
    assert all(addresses == ("1.1.1.1",) for _, addresses in requests)


@pytest.mark.asyncio
async def test_fake_ip_dns_recovers_builtin_site_search(monkeypatch):
    mock_fake_ip_dns(monkeypatch, dns_response)
    body = json.dumps(
        {
            "status": 200,
            "data": {
                "modulesInfos": [
                    {"data": {"bookId": "46543", "displayBookName": "斗罗大陆", "authorName": "唐家三少"}}
                ]
            },
        }
    ).encode()
    _, wire = wire_client(monkeypatch, [http_response(body)])
    source = BookSourceRecord(
        id="source-builtin-quark",
        name="夸克小说",
        baseUrl="https://www.shuqi.com",
        bookKind="长小说",
        language="中文",
        origin="builtin",
    )

    results = await scraper.search_builtin_site_books(source, "斗罗大陆")

    assert len(results) == 1
    assert results[0].title == "斗罗大陆"
    assert str(results[0].sourceUrl) == "https://www.shuqi.com/book/46543.html"
    assert wire.connected == [("93.184.216.34", 443)]


def test_fake_ip_dns_recovers_curl_and_validates_redirects(monkeypatch):
    from curl_cffi import CurlOpt

    from app import scraper_network_security as security

    mock_fake_ip_dns(monkeypatch, dns_response)
    calls = []

    class Session:
        curl_options = {CurlOpt.TIMEOUT: 10}

        def get(self, url, **kwargs):
            calls.append((url, dict(self.curl_options)))
            return SimpleNamespace(status_code=302, headers={"Location": "http://127.0.0.1/secret"})

    session = Session()
    with pytest.raises(security.ScraperNetworkSecurityError):
        security.public_curl_get(session, "https://books.example/chapter")

    assert len(calls) == 1
    assert calls[0][1][CurlOpt.RESOLVE] == ["books.example:443:93.184.216.34,[2606:4700:4700::1111]"]
    assert calls[0][1][CurlOpt.PROXY] == ""
    assert session.curl_options == {CurlOpt.TIMEOUT: 10}


@pytest.mark.asyncio
async def test_fake_ip_dns_recovers_browser_proxy(monkeypatch):
    from app.scraper_network_security import PublicBrowserProxy

    mock_fake_ip_dns(monkeypatch, dns_response)
    wire = WireBackend([b"test"])
    async with PublicBrowserProxy(delegate=wire) as proxy:
        reader, writer = await asyncio.open_connection("127.0.0.1", proxy.port)
        try:
            writer.write(b"\x05\x01\x00")
            await writer.drain()
            assert await asyncio.wait_for(reader.readexactly(2), timeout=1) == b"\x05\x00"
            host = b"books.example"
            writer.write(b"\x05\x01\x00\x03" + bytes([len(host)]) + host + struct.pack("!H", 443))
            await writer.drain()
            reply = await asyncio.wait_for(reader.readexactly(10), timeout=1)
            assert reply[1] == 0
            assert wire.connected == [("93.184.216.34", 443)]
        finally:
            writer.close()
            await writer.wait_closed()


@pytest.mark.asyncio
@pytest.mark.parametrize("address", ["127.0.0.1", "10.0.0.1", "169.254.169.254", "198.18.2.1"])
async def test_fake_ip_dns_never_connects_to_nonpublic_doh_answer(monkeypatch, address):
    from app.scraper_network_security import ScraperNetworkSecurityError

    mock_fake_ip_dns(monkeypatch, lambda request: dns_response(request, ipv4=address))
    client, wire = wire_client(monkeypatch, [])
    async with client:
        with pytest.raises(ScraperNetworkSecurityError):
            await client.get("https://books.example/book")
    assert wire.connected == []


@pytest.mark.asyncio
async def test_fake_ip_dns_rejects_mixed_public_and_private_doh_answers(monkeypatch):
    from app.scraper_network_security import ScraperNetworkSecurityError

    mock_fake_ip_dns(monkeypatch, lambda request: dns_response(request, ipv6="::ffff:127.0.0.1"))
    client, wire = wire_client(monkeypatch, [])
    async with client:
        with pytest.raises(ScraperNetworkSecurityError):
            await client.get("https://books.example/book")
    assert wire.connected == []


@pytest.mark.asyncio
async def test_fake_ip_dns_revalidates_http_redirects_and_new_connections(monkeypatch):
    from app.scraper_network_security import ScraperNetworkSecurityError

    def respond(request):
        address = "127.0.0.1" if request.url.params["name"] == "internal.example" else "93.184.216.34"
        return dns_response(request, ipv4=address)

    mock_fake_ip_dns(monkeypatch, respond)
    client, wire = wire_client(monkeypatch, [http_response(location="https://internal.example/secret")])
    async with client:
        with pytest.raises(ScraperNetworkSecurityError):
            await client.get("https://books.example/book")
    assert wire.connected == [("93.184.216.34", 443)]


@pytest.mark.asyncio
@pytest.mark.parametrize("system_addresses", [("93.184.216.34",), ("10.0.0.1",), ("198.18.1.1", "::1")])
async def test_only_fake_ip_dns_uses_doh(monkeypatch, system_addresses):
    from app.scraper_network_security import ScraperNetworkSecurityError, resolve_public_url

    requests = mock_fake_ip_dns(monkeypatch, dns_response, system_addresses=system_addresses)
    if system_addresses == ("93.184.216.34",):
        _, _, addresses = await resolve_public_url("https://books.example/book")
        assert tuple(str(address) for address in addresses) == system_addresses
    else:
        with pytest.raises(ScraperNetworkSecurityError):
            await resolve_public_url("https://books.example/book")
    assert requests == []


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "host", ["198.18.1.30", "[::ffff:198.18.1.30]", "localhost", "metadata.google.internal"]
)
async def test_fake_ip_dns_does_not_allow_direct_ips_or_internal_hostnames(monkeypatch, host):
    from app.scraper_network_security import ScraperNetworkSecurityError, resolve_public_url

    requests = mock_fake_ip_dns(monkeypatch, dns_response)
    with pytest.raises(ScraperNetworkSecurityError):
        await resolve_public_url(f"https://{host}/book")
    assert requests == []


@pytest.mark.asyncio
async def test_fake_ip_dns_uses_second_provider_without_following_doh_redirect(monkeypatch):
    from app.scraper_network_security import resolve_public_url

    def respond(request):
        if request.url.host == "cloudflare-dns.com":
            return httpx.Response(302, headers={"Location": "http://127.0.0.1/secret"})
        return dns_response(request, ipv4=None)

    requests = mock_fake_ip_dns(monkeypatch, respond)
    _, _, addresses = await resolve_public_url("https://books.example/book")
    assert addresses == (ipaddress.ip_address("2606:4700:4700::1111"),)
    assert {request.url.host for request, _ in requests} == {"cloudflare-dns.com", "dns.google"}
    assert {pinned for _, pinned in requests} == {("1.1.1.1",), ("8.8.8.8",)}


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "failure", ["timeout", "invalid-json", "invalid-answer", "servfail", "truncated", "empty"]
)
async def test_fake_ip_dns_failure_is_actionable_and_never_uses_fake_ip(monkeypatch, failure):
    from app.scraper_network_security import ScraperNetworkSecurityError

    def respond(request):
        if failure == "timeout":
            raise httpx.ConnectTimeout("DNS unavailable")
        if failure == "invalid-json":
            return httpx.Response(200, text="not JSON")
        if failure == "invalid-answer":
            return httpx.Response(200, json={"Status": 0, "Answer": [{"type": 1, "data": "not an IP"}]})
        if failure == "truncated":
            return httpx.Response(
                200, json={"Status": 0, "TC": True, "Answer": [{"type": 1, "data": "93.184.216.34"}]}
            )
        return httpx.Response(200, json={"Status": 2 if failure == "servfail" else 0})

    requests = mock_fake_ip_dns(monkeypatch, respond)
    client, wire = wire_client(monkeypatch, [])
    async with client:
        with pytest.raises(ScraperNetworkSecurityError, match="Fake-IP.*DNS"):
            await client.get("https://books.example/book")
    assert wire.connected == []
    assert {request.url.host for request, _ in requests} == {"cloudflare-dns.com", "dns.google"}
