from __future__ import annotations

import asyncio
import ipaddress
import json
import socket
from urllib.parse import parse_qs, urlsplit

import httpcore
import pytest

from app import model_endpoint_security as security
from app import scraper
from app.models import MangaOcrRegion, OpenAICompatibleConfig, TranslationSettings
from app.translation_model_health import probe_translation_model

PROVIDER_HOST = "models.example.test"
PROVIDER_ADDRESS = "93.184.216.34"
PROVIDER_KEY = "fake-ip-integration-provider-secret"
DNS_ADDRESSES = {"1.1.1.1", "8.8.8.8"}


class WireStream(httpcore.AsyncNetworkStream):
    def __init__(self, backend: WireBackend, host: str):
        self.backend = backend
        self.host = host
        self.sni = None
        self.request = bytearray()
        self.request_ready = asyncio.Event()
        self.response_sent = False

    async def read(self, max_bytes, timeout=None):
        await self.request_ready.wait()
        if self.response_sent:
            return b""
        self.response_sent = True
        return self.backend.response(self)

    async def write(self, buffer, timeout=None):
        self.request.extend(buffer)
        self.request_ready.set()

    async def aclose(self):
        pass

    async def start_tls(self, ssl_context, server_hostname=None, timeout=None):
        self.sni = server_hostname
        return self


class WireBackend(httpcore.AsyncNetworkBackend):
    """Fake only the socket boundary; use the real HTTP/DNS/model pipelines."""

    def __init__(self, *, dns_answers=(PROVIDER_ADDRESS,), dns_failure=False, redirect=False):
        self.dns_answers = dns_answers
        self.dns_failure = dns_failure
        self.redirect = redirect
        self.connected = []
        self.streams = []

    async def connect_tcp(self, host, port, **kwargs):
        self.connected.append((host, port))
        assert host in DNS_ADDRESSES | {PROVIDER_ADDRESS}, "Never connect to Fake-IP or private IP"
        assert port == 443
        stream = WireStream(self, host)
        self.streams.append(stream)
        return stream

    def response(self, stream):
        request_line = bytes(stream.request).split(b"\r\n", 1)[0].decode()
        method, target, _ = request_line.split(" ", 2)
        if stream.host in DNS_ADDRESSES:
            assert method == "GET"
            if self.dns_failure:
                return http_response({}, status="503 Service Unavailable")
            query = parse_qs(urlsplit(target).query)
            assert query["name"] == [PROVIDER_HOST]
            record_type = int(query["type"][0])
            answers = [
                {"name": PROVIDER_HOST, "type": record_type, "data": address}
                for address in self.dns_answers
                if ipaddress.ip_address(address).version == (4 if record_type == 1 else 6)
            ]
            return http_response({"Status": 0, "Answer": answers})
        assert method == "POST"
        assert target == "/v1/chat/completions"
        if self.redirect:
            return http_response({}, status="307 Temporary Redirect", location="https://evil.example/key")
        payload = json.loads(bytes(stream.request).split(b"\r\n\r\n", 1)[1])
        content = (
            "OK"
            if payload["max_tokens"] == 8
            else json.dumps({"translations": [{"order": 1, "translation": "你好"}]}, ensure_ascii=False)
        )
        return http_response({"choices": [{"message": {"content": content}, "finish_reason": "stop"}]})


def http_response(payload, *, status="200 OK", location=None):
    body = json.dumps(payload, ensure_ascii=False).encode()
    return (
        f"HTTP/1.1 {status}\r\nContent-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\nConnection: close\r\n"
        + (f"Location: {location}\r\n" if location else "")
        + "\r\n"
    ).encode() + body


def install_wire(monkeypatch, *, system_answers=("198.18.0.9",), **kwargs):
    wire = WireBackend(**kwargs)
    system_queries = []

    def system_dns(host, port, **_):
        system_queries.append((host, port))
        assert (host, port) == (PROVIDER_HOST, 443)
        return [
            (
                socket.AF_INET if ipaddress.ip_address(address).version == 4 else socket.AF_INET6,
                socket.SOCK_STREAM,
                socket.IPPROTO_TCP,
                "",
                (address, port),
            )
            for address in system_answers
        ]

    monkeypatch.delenv(security.MODEL_ENDPOINT_ALLOWLIST_ENV, raising=False)
    monkeypatch.setattr(security.socket, "getaddrinfo", system_dns)
    monkeypatch.setattr(httpcore, "AnyIOBackend", lambda: wire)
    return wire, system_queries


def settings():
    return TranslationSettings(
        translationModel=OpenAICompatibleConfig(
            enabled=True,
            baseUrl=f"https://{PROVIDER_HOST}/v1",
            model="translation-model",
            apiKey=PROVIDER_KEY,
        )
    )


def assert_private_key_only_reaches_provider(wire):
    for stream in wire.streams:
        headers = bytes(stream.request).split(b"\r\n\r\n", 1)[0].lower()
        if stream.host == PROVIDER_ADDRESS:
            assert stream.sni == PROVIDER_HOST
            assert f"host: {PROVIDER_HOST}\r\n".encode() in headers
            assert f"authorization: bearer {PROVIDER_KEY}".encode() in headers
        else:
            assert stream.host in DNS_ADDRESSES
            assert stream.sni in {"cloudflare-dns.com", "dns.google"}
            assert b"authorization:" not in headers
            assert PROVIDER_KEY.encode() not in stream.request


@pytest.mark.asyncio
async def test_selfcheck_uses_default_transport_and_real_ip_after_fake_dns(monkeypatch):
    wire, system_queries = install_wire(monkeypatch)
    result = await probe_translation_model(settings(), timeout_seconds=2)
    assert result.available is True
    assert result.status == "ready"
    assert PROVIDER_KEY not in result.model_dump_json()
    assert system_queries == [(PROVIDER_HOST, 443)]
    assert (PROVIDER_ADDRESS, 443) in wire.connected
    assert any(host in DNS_ADDRESSES for host, _ in wire.connected)
    assert_private_key_only_reaches_provider(wire)


@pytest.mark.asyncio
async def test_manga_text_translation_uses_default_transport_after_fake_dns(monkeypatch):
    wire, system_queries = install_wire(monkeypatch)
    result = await scraper._translate_manga_region_batch(
        settings=settings(),
        base_url=f"https://{PROVIDER_HOST}/v1",
        api_key=PROVIDER_KEY,
        model="translation-model",
        target_language="简体中文",
        chapter_title="试读章节",
        chapter_index=1,
        page_number=1,
        total_pages=1,
        regions=[MangaOcrRegion(order=1, bbox=(10, 10, 500, 200), source_text="こんにちは")],
        timeout_seconds=2,
    )
    assert result[0].translation == "你好"
    assert system_queries == [(PROVIDER_HOST, 443)]
    assert sum(host == PROVIDER_ADDRESS for host, _ in wire.connected) == 1
    assert_private_key_only_reaches_provider(wire)


@pytest.mark.asyncio
async def test_fake_ip_recovery_does_not_enable_model_redirects(monkeypatch):
    wire, _ = install_wire(monkeypatch, redirect=True)
    async with security.create_model_http_client(timeout=2) as client:
        response = await client.post(
            f"https://{PROVIDER_HOST}/v1/chat/completions",
            headers={"Authorization": f"Bearer {PROVIDER_KEY}"},
            json={"max_tokens": 8},
        )
    assert response.status_code == 307
    assert response.history == []
    assert sum(host == PROVIDER_ADDRESS for host, _ in wire.connected) == 1
    assert_private_key_only_reaches_provider(wire)


@pytest.mark.asyncio
async def test_manga_dns_failure_keeps_actionable_error_without_sending_provider_key(monkeypatch):
    wire, _ = install_wire(monkeypatch, dns_failure=True)
    with pytest.raises(security.ModelEndpointDnsError, match="Fake-IP") as error:
        await scraper._translate_manga_region_batch(
            settings=settings(),
            base_url=f"https://{PROVIDER_HOST}/v1",
            api_key=PROVIDER_KEY,
            model="translation-model",
            target_language="简体中文",
            chapter_title="试读章节",
            chapter_index=1,
            page_number=1,
            total_pages=1,
            regions=[MangaOcrRegion(order=1, bbox=(10, 10, 500, 200), source_text="こんにちは")],
            timeout_seconds=2,
        )
    assert "redir-host" in str(error.value)
    assert PROVIDER_KEY not in str(error.value)
    assert all(host in DNS_ADDRESSES for host, _ in wire.connected)
    assert_private_key_only_reaches_provider(wire)


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "options",
    [
        {"dns_answers": ("127.0.0.1",)},
        {"dns_answers": (PROVIDER_ADDRESS, "10.0.0.1")},
        {"dns_answers": ("169.254.169.254",)},
        {"dns_answers": ("198.19.0.1",)},
        {"dns_failure": True},
        {"system_answers": ("198.18.0.9", "10.0.0.1")},
    ],
    ids=["loopback", "mixed-private", "metadata", "fake-again", "dns-failed", "system-mixed-private"],
)
async def test_unsafe_or_failed_recovery_never_connects_or_leaks_key(monkeypatch, caplog, options):
    wire, _ = install_wire(monkeypatch, **options)
    result = await probe_translation_model(settings(), timeout_seconds=2)
    assert result.status == "failed"
    assert result.available is False
    assert all(host in DNS_ADDRESSES for host, _ in wire.connected)
    assert PROVIDER_KEY not in result.model_dump_json()
    assert PROVIDER_KEY not in caplog.text
    assert_private_key_only_reaches_provider(wire)
