"""Resolve DNS through fixed public HTTPS services without applying caller policy."""

from __future__ import annotations

import asyncio
import ipaddress
from collections.abc import Callable
from urllib.parse import urlsplit

import httpx

IPAddress = ipaddress.IPv4Address | ipaddress.IPv6Address
TransportFactory = Callable[..., httpx.AsyncBaseTransport]

_FAKE_IP_NETWORK = ipaddress.ip_network("198.18.0.0/15")
_DNS_HTTPS_SERVICES = (
    ("https://cloudflare-dns.com/dns-query", "1.1.1.1"),
    ("https://dns.google/resolve", "8.8.8.8"),
)
_DNS_HTTPS_TIMEOUT = 5.0


class PublicDnsResolutionError(ValueError):
    """No public DNS provider returned a complete, valid response."""


def is_fake_ip_address(address: IPAddress) -> bool:
    effective = address.ipv4_mapped if isinstance(address, ipaddress.IPv6Address) else address
    return effective is not None and effective in _FAKE_IP_NETWORK


async def _resolve_dns_service_addresses(host: str, port: int) -> tuple[IPAddress, ...]:
    # Bootstrap DoH without system DNS, which may itself return Fake-IP answers.
    for endpoint, address in _DNS_HTTPS_SERVICES:
        if host == urlsplit(endpoint).hostname and port == 443:
            return (ipaddress.ip_address(address),)
    raise PublicDnsResolutionError("不支持的加密 DNS 服务地址")


async def resolve_public_dns_addresses(
    host: str, *, transport_factory: TransportFactory
) -> tuple[IPAddress, ...]:
    """Return all A/AAAA answers; the caller must validate them before connecting.

    The injected transport must pin connections using the supplied resolver.
    Policy rejection is deliberately outside provider fallback: a private answer
    is not a DNS outage and must not silently be replaced by another provider.
    """
    last_error: Exception | None = None
    for endpoint, _ in _DNS_HTTPS_SERVICES:
        try:
            async with asyncio.timeout(_DNS_HTTPS_TIMEOUT):
                async with httpx.AsyncClient(
                    timeout=_DNS_HTTPS_TIMEOUT,
                    trust_env=False,
                    follow_redirects=False,
                    transport=transport_factory(
                        allowlist=frozenset(), resolver=_resolve_dns_service_addresses
                    ),
                ) as client:
                    responses = await asyncio.gather(
                        *(
                            client.get(
                                endpoint,
                                params={"name": host, "type": record_type},
                                headers={"Accept": "application/dns-json"},
                            )
                            for record_type in (1, 28)
                        ),
                        return_exceptions=True,
                    )
            addresses: list[IPAddress] = []
            for response in responses:
                if isinstance(response, BaseException):
                    raise response
                response.raise_for_status()
                payload = response.json()
                if (
                    not isinstance(payload, dict)
                    or type(payload.get("Status")) is not int
                    or payload["Status"] != 0
                    or type(payload.get("TC", False)) is not bool
                    or payload.get("TC", False)
                ):
                    raise ValueError("DNS lookup failed")
                answers = payload.get("Answer", [])
                if not isinstance(answers, list):
                    raise ValueError("Invalid DNS answers")
                for answer in answers:
                    if not isinstance(answer, dict) or type(answer.get("type")) is not int:
                        raise ValueError("Invalid DNS answer")
                    if answer["type"] not in {1, 28}:
                        continue
                    raw_address = answer.get("data")
                    if not isinstance(raw_address, str) or "%" in raw_address:
                        raise ValueError("Invalid DNS address")
                    address = ipaddress.ip_address(raw_address)
                    if address.version != (4 if answer["type"] == 1 else 6):
                        raise ValueError("Invalid DNS address family")
                    if address not in addresses:
                        addresses.append(address)
            if not addresses:
                raise ValueError("No DNS addresses")
        except (httpx.HTTPError, TimeoutError, ValueError, TypeError) as error:
            last_error = error
            continue
        return tuple(addresses)
    raise PublicDnsResolutionError("无法通过加密 DNS 解析地址") from last_error
