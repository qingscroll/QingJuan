from __future__ import annotations

import asyncio
import ipaddress
import socket
import struct
from contextlib import suppress
from typing import Any
from urllib.parse import urljoin, urlsplit

import httpcore
import httpx

from .model_endpoint_security import (
    AddressResolver,
    IPAddress,
    ModelEndpointSecurityError,
    ValidatedModelHTTPTransport,
    ValidatedModelNetworkBackend,
    resolve_model_endpoint_addresses,
)
from .public_dns import PublicDnsResolutionError, is_fake_ip_address, resolve_public_dns_addresses


class ScraperNetworkSecurityError(ValueError):
    """A website request attempted to leave the public HTTP network boundary."""


def _public_addresses(addresses: tuple[IPAddress, ...]) -> tuple[IPAddress, ...]:
    if not addresses:
        raise ScraperNetworkSecurityError("抓取地址无法解析")
    for address in addresses:
        effective = address.ipv4_mapped if isinstance(address, ipaddress.IPv6Address) else None
        effective = effective or address
        if (
            not effective.is_global
            or effective.is_multicast
            or effective.is_reserved
            or effective.is_unspecified
            or str(effective) == "168.63.129.16"
        ):
            raise ScraperNetworkSecurityError("抓取地址不允许访问本机、内网或云元数据网络")
    return addresses


def validate_public_url(value: str) -> tuple[str, int]:
    if (
        not value
        or value != value.strip()
        or "\\" in value
        or any(ord(c) < 32 or ord(c) == 127 for c in value)
    ):
        raise ScraperNetworkSecurityError("抓取地址包含不允许的字符")
    try:
        parsed = urlsplit(value)
        host = (parsed.hostname or "").encode("idna").decode("ascii").lower().rstrip(".")
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
    except (ValueError, UnicodeError) as error:
        raise ScraperNetworkSecurityError("抓取地址格式无效") from error
    if parsed.scheme not in {"http", "https"} or not host or "%" in host:
        raise ScraperNetworkSecurityError("抓取地址必须是有效的 HTTP/HTTPS URL")
    if parsed.username is not None or parsed.password is not None:
        raise ScraperNetworkSecurityError("抓取地址不允许内嵌用户凭据")
    if host in {
        "localhost",
        "localhost.localdomain",
        "ip6-localhost",
        "metadata",
        "instance-data",
        "metadata.google.internal",
        "metadata.azure.internal",
    } or host.endswith(".localhost"):
        raise ScraperNetworkSecurityError("抓取地址不允许访问本机或云元数据服务")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        _public_addresses((address,))
    return host, port


async def _resolve_with_public_dns(host: str) -> tuple[IPAddress, ...]:
    try:
        addresses = await resolve_public_dns_addresses(host, transport_factory=ValidatedModelHTTPTransport)
    except PublicDnsResolutionError as error:
        raise ScraperNetworkSecurityError(
            "检测到代理 Fake-IP DNS，但无法解析真实公网地址；请检查网络，或将代理 DNS 改为真实 IP 模式（redir-host）"
        ) from error
    # A valid but forbidden answer is rejected, never retried via another provider.
    return _public_addresses(addresses)


async def resolve_scraper_addresses(host: str, port: int) -> tuple[IPAddress, ...]:
    rendered_host = f"[{host}]" if ":" in host else host
    host, port = validate_public_url(f"http://{rendered_host}:{port}/")
    try:
        addresses = await resolve_model_endpoint_addresses(host, port)
    except ModelEndpointSecurityError as error:
        raise ScraperNetworkSecurityError("抓取地址无法解析") from error

    if any(is_fake_ip_address(address) for address in addresses):
        # TUN DNS can synthesize 198.18/15 addresses for public domain names.
        # Never allow that range: resolve real IPs instead, then pin the connection.
        remaining = tuple(address for address in addresses if not is_fake_ip_address(address))
        if remaining:
            _public_addresses(remaining)
        return await _resolve_with_public_dns(host)
    return _public_addresses(addresses)


async def resolve_public_url(
    value: str, *, resolver: AddressResolver | None = None
) -> tuple[str, int, tuple[IPAddress, ...]]:
    host, port = validate_public_url(value)
    try:
        addresses = await (resolver or resolve_scraper_addresses)(host, port)
    except ModelEndpointSecurityError as error:
        raise ScraperNetworkSecurityError("抓取地址无法解析") from error
    return host, port, _public_addresses(addresses)


class PublicHTTPTransport(ValidatedModelHTTPTransport):
    def __init__(self, *, resolver: AddressResolver | None = None) -> None:
        # Website requests never inherit the operator's model endpoint allowlist.
        super().__init__(allowlist=frozenset(), resolver=resolver or resolve_scraper_addresses)

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        validate_public_url(str(request.url))
        try:
            return await super().handle_async_request(request)
        except ModelEndpointSecurityError as error:
            raise ScraperNetworkSecurityError("抓取地址不允许访问本机、内网或云元数据网络") from error


def create_public_http_client(
    *,
    timeout: float | httpx.Timeout,
    headers: dict[str, str] | None = None,
    follow_redirects: bool = True,
    resolver: AddressResolver | None = None,
) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        timeout=timeout,
        headers=headers,
        follow_redirects=follow_redirects,
        trust_env=False,
        transport=PublicHTTPTransport(resolver=resolver),
    )


def public_curl_get(session: Any, url: str, **kwargs: Any) -> Any:
    """Keep curl impersonation, pin DNS, and validate every redirect before sending."""
    from curl_cffi import CurlOpt

    original_options = dict(session.curl_options)
    current_url = url
    headers = dict(kwargs.pop("headers", None) or {})
    cookies = kwargs.pop("cookies", None)
    try:
        for _ in range(11):
            host, port, addresses = asyncio.run(resolve_public_url(current_url))
            # CURLOPT_RESOLVE preserves both the HTTP Host and TLS SNI. PROXY=""
            # overrides environment proxies that would resolve the hostname again.
            rendered = ",".join(f"[{ip}]" if ip.version == 6 else str(ip) for ip in addresses)
            resolve_host = f"[{host}]" if ":" in host else host
            session.curl_options = {
                **original_options,
                CurlOpt.RESOLVE: [f"{resolve_host}:{port}:{rendered}"],
                CurlOpt.PROXY: "",
            }
            response = session.get(
                current_url, headers=headers, cookies=cookies, allow_redirects=False, **kwargs
            )
            location = response.headers.get("Location")
            if response.status_code not in {301, 302, 303, 307, 308} or not location:
                return response
            next_url = urljoin(current_url, location)
            next_host, next_port = validate_public_url(next_url)
            if (next_host, next_port, urlsplit(next_url).scheme) != (
                host,
                port,
                urlsplit(current_url).scheme,
            ):
                headers = {
                    key: val
                    for key, val in headers.items()
                    if key.lower() not in {"authorization", "cookie", "proxy-authorization"}
                }
                cookies = None
            current_url = next_url
        raise ScraperNetworkSecurityError("抓取地址重定向次数过多")
    finally:
        session.curl_options = original_options


class PublicBrowserProxy:
    """Per-browser SOCKS5 proxy: validate all addresses and connect to that exact IP.

    Redirects, subresources and websocket connections share this boundary. Chromium
    is configured to proxy loopback too, disable direct DNS/QUIC and prohibit
    non-proxied WebRTC UDP; no user-controlled page can select a different proxy.
    """

    def __init__(
        self,
        *,
        resolver: AddressResolver | None = None,
        delegate: httpcore.AsyncNetworkBackend | None = None,
    ) -> None:
        self._backend = ValidatedModelNetworkBackend(
            allowlist=frozenset(), resolver=resolver or resolve_scraper_addresses, delegate=delegate
        )
        self._tasks: set[asyncio.Task[None]] = set()
        self._connections: set[socket.socket] = set()
        self._listener: socket.socket | None = None
        self._accept_task: asyncio.Task[None] | None = None
        self.port = 0

    async def __aenter__(self) -> PublicBrowserProxy:
        # Use nonblocking sockets directly. Python 3.13's Windows Proactor
        # stream transport can raise during shutdown after Chromium resets a
        # speculative connection, leaving that transport incompletely closed.
        self._listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._listener.setblocking(False)
        try:
            self._listener.bind(("127.0.0.1", 0))
            self._listener.listen(128)
        except BaseException:
            self._listener.close()
            raise
        self.port = self._listener.getsockname()[1]
        self._accept_task = asyncio.create_task(self._accept())
        return self

    async def __aexit__(self, *_args: object) -> None:
        assert self._listener is not None and self._accept_task is not None
        self._accept_task.cancel()
        self._listener.close()
        await asyncio.gather(self._accept_task, return_exceptions=True)
        tasks = list(self._tasks)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        for connection in self._connections:
            connection.close()
        self._connections.clear()

    @property
    def chromium_arguments(self) -> list[str]:
        return [
            f"--proxy-server=socks5://127.0.0.1:{self.port}",
            "--proxy-bypass-list=<-loopback>",
            "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1",
            "--disable-quic",
            "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
            "--disable-background-networking",
        ]

    async def _accept(self) -> None:
        assert self._listener is not None
        loop = asyncio.get_running_loop()
        while True:
            connection, _ = await loop.sock_accept(self._listener)
            connection.setblocking(False)
            self._connections.add(connection)
            task = asyncio.create_task(self._serve(connection))
            self._tasks.add(task)
            task.add_done_callback(self._tasks.discard)

    async def _serve(self, connection: socket.socket) -> None:
        upstream = None
        pumps = []
        loop = asyncio.get_running_loop()

        async def readexactly(size: int) -> bytes:
            data = b""
            while len(data) < size:
                chunk = await loop.sock_recv(connection, size - len(data))
                if not chunk:
                    raise asyncio.IncompleteReadError(data, size)
                data += chunk
            return data

        try:
            async with asyncio.timeout(20):
                version, methods_count = await readexactly(2)
                methods = await readexactly(methods_count)
                if version != 5 or 0 not in methods:
                    return
                await loop.sock_sendall(connection, b"\x05\x00")
                version, command, reserved, address_type = await readexactly(4)
                if version != 5 or command != 1 or reserved != 0:
                    return
                if address_type == 1:
                    host = str(ipaddress.ip_address(await readexactly(4)))
                elif address_type == 4:
                    host = str(ipaddress.ip_address(await readexactly(16)))
                elif address_type == 3:
                    length = (await readexactly(1))[0]
                    host = (await readexactly(length)).decode("ascii")
                else:
                    return
                port = struct.unpack("!H", await readexactly(2))[0]
                rendered_host = f"[{host}]" if ":" in host else host
                validate_public_url(f"http://{rendered_host}:{port}/")
                upstream = await self._backend.connect_tcp(host, port, timeout=15)
                await loop.sock_sendall(connection, b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")

            async def upload():
                while data := await loop.sock_recv(connection, 65536):
                    await upstream.write(data, timeout=30)

            async def download():
                while data := await upstream.read(65536, timeout=30):
                    await loop.sock_sendall(connection, data)

            pumps = [asyncio.create_task(upload()), asyncio.create_task(download())]
            await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
        except (
            OSError,
            ValueError,
            httpcore.NetworkError,
            httpcore.TimeoutException,
            asyncio.IncompleteReadError,
            TimeoutError,
        ):
            with suppress(OSError):
                await loop.sock_sendall(connection, b"\x05\x02\x00\x01\x00\x00\x00\x00\x00\x00")
        finally:
            for task in pumps:
                task.cancel()
            await asyncio.gather(*pumps, return_exceptions=True)
            if upstream is not None:
                with suppress(OSError):
                    await upstream.aclose()
            connection.close()
            self._connections.discard(connection)
