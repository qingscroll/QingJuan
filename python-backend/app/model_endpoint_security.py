from __future__ import annotations

import asyncio
import ipaddress
import os
import re
import socket
import ssl
from collections.abc import Awaitable, Callable, Iterable
from functools import partial
from urllib.parse import SplitResult, urlsplit

import httpcore
import httpx

from .public_dns import PublicDnsResolutionError, is_fake_ip_address, resolve_public_dns_addresses

MODEL_ENDPOINT_ALLOWLIST_ENV = "QINGJUAN_MODEL_ENDPOINT_ALLOWLIST"

IPAddress = ipaddress.IPv4Address | ipaddress.IPv6Address
AddressResolver = Callable[[str, int], Awaitable[tuple[IPAddress, ...]]]

_METADATA_HOSTNAMES = {
    "instance-data",
    "metadata",
    "metadata.azure.internal",
    "metadata.google.internal",
}
_LOCAL_HOSTNAMES = {"ip6-localhost", "localhost", "localhost.localdomain"}
_METADATA_NETWORKS = (
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("fe80::/10"),
    ipaddress.ip_network("100.100.100.200/32"),
    ipaddress.ip_network("168.63.129.16/32"),
    ipaddress.ip_network("fd00:ec2::254/128"),
)


class ModelEndpointSecurityError(ValueError):
    """The configured model endpoint violates the outbound network policy."""


class ModelEndpointDnsError(ModelEndpointSecurityError):
    """A proxy's synthetic DNS answer could not be resolved to a public IP."""

    def __init__(self) -> None:
        super().__init__(
            "检测到代理 Fake-IP DNS，但无法解析模型服务的真实公网地址；"
            "请检查网络，或将代理 DNS 改为真实 IP 模式（redir-host）"
        )


def model_endpoint_origin(value: str) -> str:
    parsed = _parse_model_endpoint_url(value)
    host = _canonical_hostname(parsed.hostname or "")
    port = _parsed_port(parsed)
    default_port = 443 if parsed.scheme == "https" else 80
    rendered_host = f"[{host}]" if ":" in host else host
    port_suffix = "" if port == default_port else f":{port}"
    return f"{parsed.scheme}://{rendered_host}{port_suffix}"


def configured_model_endpoint_allowlist() -> frozenset[str]:
    raw_value = os.getenv(MODEL_ENDPOINT_ALLOWLIST_ENV, "")
    if not raw_value.strip():
        return frozenset()

    origins: set[str] = set()
    for raw_entry in re.split(r"[,;\r\n]+", raw_value):
        entry = raw_entry.strip()
        if not entry:
            continue
        try:
            parsed = _parse_model_endpoint_url(entry)
            if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
                raise ModelEndpointSecurityError("allowlist entries must be origins")
            origins.add(model_endpoint_origin(entry))
        except ModelEndpointSecurityError as error:
            raise RuntimeError(
                f"{MODEL_ENDPOINT_ALLOWLIST_ENV} 必须仅包含逗号分隔的 HTTP/HTTPS Origin"
            ) from error
    return frozenset(origins)


async def validate_model_endpoint_url(
    value: str,
    *,
    resolver: AddressResolver | None = None,
) -> str:
    """Validate and resolve an endpoint before persisting or probing it."""

    origin = validate_model_endpoint_url_policy(value)
    parsed = _parse_model_endpoint_url(value)
    allowlist = configured_model_endpoint_allowlist()
    addresses = await (resolver or resolve_model_service_addresses)(
        _canonical_hostname(parsed.hostname or ""),
        _parsed_port(parsed),
    )
    _validate_resolved_addresses(addresses, allow_private=origin in allowlist)
    return origin


def validate_model_endpoint_url_policy(value: str) -> str:
    """Validate URL syntax, scheme, direct IP, and operator allowlist policy."""

    parsed = _parse_model_endpoint_url(value)
    allowlist = configured_model_endpoint_allowlist()
    origin = model_endpoint_origin(value)
    _validate_scheme_policy(parsed, origin=origin, allowlist=allowlist)
    direct_address = _parse_ip_address(_canonical_hostname(parsed.hostname or ""))
    if direct_address is not None:
        _validate_resolved_addresses(
            (direct_address,),
            allow_private=origin in allowlist,
        )
    return origin


async def resolve_model_endpoint_addresses(host: str, port: int) -> tuple[IPAddress, ...]:
    normalized_host = _canonical_hostname(host)
    direct_address = _parse_ip_address(normalized_host)
    if direct_address is not None:
        return (direct_address,)

    try:
        address_info = await asyncio.to_thread(
            partial(
                socket.getaddrinfo,
                normalized_host,
                port,
                family=socket.AF_UNSPEC,
                type=socket.SOCK_STREAM,
                proto=socket.IPPROTO_TCP,
            )
        )
    except (OSError, UnicodeError) as error:
        raise ModelEndpointSecurityError("模型服务地址无法解析") from error

    addresses: list[IPAddress] = []
    seen: set[IPAddress] = set()
    for item in address_info:
        raw_address = str(item[4][0]).split("%", 1)[0]
        try:
            address = ipaddress.ip_address(raw_address)
        except ValueError as error:  # pragma: no cover - getaddrinfo should return IP literals
            raise ModelEndpointSecurityError("模型服务地址解析结果无效") from error
        if address not in seen:
            seen.add(address)
            addresses.append(address)
    if not addresses:
        raise ModelEndpointSecurityError("模型服务地址无法解析")
    return tuple(addresses)


async def resolve_model_service_addresses(host: str, port: int) -> tuple[IPAddress, ...]:
    """Recover public model DNS behind a TUN proxy without authorizing private IPs."""

    normalized_host = _canonical_hostname(host)
    addresses = await resolve_model_endpoint_addresses(normalized_host, port)
    # An explicit IP is an endpoint, never a domain to look up through public DNS.
    if _parse_ip_address(normalized_host) is not None or not any(
        is_fake_ip_address(address) for address in addresses
    ):
        return addresses
    remaining = tuple(address for address in addresses if not is_fake_ip_address(address))
    if remaining:
        _validate_resolved_addresses(remaining, allow_private=False)
    try:
        resolved = await resolve_public_dns_addresses(
            normalized_host, transport_factory=ValidatedModelHTTPTransport
        )
    except PublicDnsResolutionError as error:
        raise ModelEndpointDnsError() from error
    # All recovered A/AAAA answers must be public, even with an operator allowlist.
    _validate_resolved_addresses(resolved, allow_private=False)
    return resolved


class ValidatedModelNetworkBackend(httpcore.AsyncNetworkBackend):
    """Resolve, validate, and connect to the same IP to prevent DNS rebinding."""

    def __init__(
        self,
        *,
        allowlist: frozenset[str],
        resolver: AddressResolver | None = None,
        delegate: httpcore.AsyncNetworkBackend | None = None,
    ) -> None:
        self._allowlisted_targets = {
            (_canonical_hostname(urlsplit(origin).hostname or ""), _parsed_port(urlsplit(origin)))
            for origin in allowlist
        }
        self._resolver = resolver or resolve_model_endpoint_addresses
        self._delegate = delegate or httpcore.AnyIOBackend()

    async def connect_tcp(
        self,
        host: str,
        port: int,
        timeout: float | None = None,
        local_address: str | None = None,
        socket_options: Iterable[httpcore.SOCKET_OPTION] | None = None,
    ) -> httpcore.AsyncNetworkStream:
        normalized_host = _canonical_hostname(host)
        addresses = await self._resolver(normalized_host, port)
        _validate_resolved_addresses(
            addresses,
            allow_private=(normalized_host, port) in self._allowlisted_targets,
        )

        last_error: Exception | None = None
        for address in addresses:
            try:
                return await self._delegate.connect_tcp(
                    str(address),
                    port,
                    timeout=timeout,
                    local_address=local_address,
                    socket_options=socket_options,
                )
            except (httpcore.ConnectError, httpcore.ConnectTimeout) as error:
                last_error = error
        if last_error is not None:
            raise last_error
        raise httpcore.ConnectError("模型服务地址无可用网络地址")

    async def connect_unix_socket(
        self,
        path: str,
        timeout: float | None = None,
        socket_options: Iterable[httpcore.SOCKET_OPTION] | None = None,
    ) -> httpcore.AsyncNetworkStream:
        raise httpcore.ConnectError("模型服务不允许使用 Unix Socket")

    async def sleep(self, seconds: float) -> None:
        await self._delegate.sleep(seconds)


class ValidatedModelHTTPTransport(httpx.AsyncHTTPTransport):
    """HTTPX transport with a validated, IP-pinning httpcore backend."""

    def __init__(
        self,
        *,
        allowlist: frozenset[str],
        resolver: AddressResolver | None = None,
    ) -> None:
        ssl_context = ssl.create_default_context()
        limits = httpx.Limits(
            max_connections=20,
            max_keepalive_connections=10,
            keepalive_expiry=5.0,
        )
        super().__init__(
            verify=ssl_context,
            trust_env=False,
            http1=True,
            http2=False,
            limits=limits,
            retries=0,
        )
        # HTTPX 0.28.1 and HTTPCore 1.0.9 are locked by requirements.txt.
        # Replacing the pool preserves the original TLS SNI while pinning TCP
        # to the already-validated IP.
        self._pool = httpcore.AsyncConnectionPool(
            ssl_context=ssl_context,
            max_connections=20,
            max_keepalive_connections=10,
            keepalive_expiry=5.0,
            http1=True,
            http2=False,
            retries=0,
            network_backend=ValidatedModelNetworkBackend(
                allowlist=allowlist,
                resolver=resolver,
            ),
        )


def create_model_http_client(
    *,
    timeout: float | httpx.Timeout,
    resolver: AddressResolver | None = None,
) -> httpx.AsyncClient:
    allowlist = configured_model_endpoint_allowlist()

    async def validate_request(request: httpx.Request) -> None:
        validate_model_endpoint_url_policy(str(request.url))
        if request.method == "POST":
            from .resource_limits import reserve_current_model_request

            reserve_current_model_request()

    return httpx.AsyncClient(
        timeout=timeout,
        follow_redirects=False,
        trust_env=False,
        transport=ValidatedModelHTTPTransport(
            allowlist=allowlist,
            resolver=resolver or resolve_model_service_addresses,
        ),
        event_hooks={"request": [validate_request]},
    )


def _parse_model_endpoint_url(value: str) -> SplitResult:
    raw_value = str(value or "")
    if not raw_value or raw_value != raw_value.strip():
        raise ModelEndpointSecurityError("模型服务地址不能为空或包含首尾空白")
    if "\\" in raw_value or any(ord(character) < 32 or ord(character) == 127 for character in raw_value):
        raise ModelEndpointSecurityError("模型服务地址包含不允许的字符")

    try:
        parsed = urlsplit(raw_value)
        hostname = parsed.hostname
        _parsed_port(parsed)
    except ValueError as error:
        raise ModelEndpointSecurityError("模型服务地址格式无效") from error
    if parsed.scheme.lower() not in {"http", "https"} or not hostname:
        raise ModelEndpointSecurityError("模型服务地址必须是有效的 HTTP/HTTPS URL")
    if parsed.username is not None or parsed.password is not None:
        raise ModelEndpointSecurityError("模型服务地址不允许内嵌用户凭据")

    canonical_host = _canonical_hostname(hostname)
    if (
        canonical_host in _LOCAL_HOSTNAMES
        or canonical_host in _METADATA_HOSTNAMES
        or canonical_host.endswith(".localhost")
    ):
        raise ModelEndpointSecurityError("模型服务地址不允许访问本机或云元数据服务")
    return parsed._replace(scheme=parsed.scheme.lower(), netloc=parsed.netloc)


def _canonical_hostname(value: str) -> str:
    host = str(value or "").strip().strip("[]").rstrip(".")
    if not host or "%" in host:
        raise ModelEndpointSecurityError("模型服务主机名无效")
    direct_address = _parse_ip_address(host)
    if direct_address is not None:
        return direct_address.compressed.lower()
    try:
        return host.encode("idna").decode("ascii").lower()
    except UnicodeError as error:
        raise ModelEndpointSecurityError("模型服务主机名无效") from error


def _parsed_port(parsed: SplitResult) -> int:
    try:
        return parsed.port or (443 if parsed.scheme.lower() == "https" else 80)
    except ValueError as error:
        raise ModelEndpointSecurityError("模型服务端口无效") from error


def _parse_ip_address(host: str) -> IPAddress | None:
    try:
        return ipaddress.ip_address(host)
    except ValueError:
        return None


def _validate_scheme_policy(
    parsed: SplitResult,
    *,
    origin: str,
    allowlist: frozenset[str],
) -> None:
    if parsed.scheme == "https" or origin in allowlist:
        return
    raise ModelEndpointSecurityError("模型服务默认必须使用 HTTPS，私网 HTTP 需由服务端白名单授权")


def _validate_resolved_addresses(
    addresses: tuple[IPAddress, ...],
    *,
    allow_private: bool,
) -> None:
    if not addresses:
        raise ModelEndpointSecurityError("模型服务地址无法解析")
    for address in addresses:
        effective_address = address.ipv4_mapped if isinstance(address, ipaddress.IPv6Address) else None
        effective_address = effective_address or address
        if any(effective_address in network for network in _METADATA_NETWORKS):
            raise ModelEndpointSecurityError("模型服务地址不允许访问云元数据网络")
        if (
            effective_address.is_multicast
            or effective_address.is_reserved
            or effective_address.is_unspecified
        ):
            raise ModelEndpointSecurityError("模型服务地址解析到不可用网络")
        if not effective_address.is_global and not allow_private:
            raise ModelEndpointSecurityError("模型服务地址不允许访问本机或内网")
