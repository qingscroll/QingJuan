from __future__ import annotations

import ipaddress
from collections.abc import Iterable

import httpcore
import pytest

from app import model_endpoint_security as security
from app.model_endpoint_security import (
    MODEL_ENDPOINT_ALLOWLIST_ENV,
    ModelEndpointSecurityError,
    ValidatedModelHTTPTransport,
    ValidatedModelNetworkBackend,
    create_model_http_client,
    model_endpoint_origin,
    validate_model_endpoint_url,
    validate_model_endpoint_url_policy,
)
from app.public_dns import PublicDnsResolutionError


class _DummyStream(httpcore.AsyncNetworkStream):
    async def read(self, max_bytes: int, timeout: float | None = None) -> bytes:
        return b""

    async def write(self, buffer: bytes, timeout: float | None = None) -> None:
        return None

    async def aclose(self) -> None:
        return None

    async def start_tls(
        self,
        ssl_context,
        server_hostname: str | None = None,
        timeout: float | None = None,
    ) -> httpcore.AsyncNetworkStream:
        return self


class _RecordingBackend(httpcore.AsyncNetworkBackend):
    def __init__(self) -> None:
        self.connected_hosts: list[tuple[str, int]] = []

    async def connect_tcp(
        self,
        host: str,
        port: int,
        timeout: float | None = None,
        local_address: str | None = None,
        socket_options: Iterable[httpcore.SOCKET_OPTION] | None = None,
    ) -> httpcore.AsyncNetworkStream:
        self.connected_hosts.append((host, port))
        return _DummyStream()

    async def connect_unix_socket(
        self,
        path: str,
        timeout: float | None = None,
        socket_options: Iterable[httpcore.SOCKET_OPTION] | None = None,
    ) -> httpcore.AsyncNetworkStream:
        raise AssertionError("unix sockets are not expected")

    async def sleep(self, seconds: float) -> None:
        return None


def test_model_endpoint_origin_is_canonical_and_drops_path() -> None:
    assert model_endpoint_origin("HTTPS://Models.Example.Test:443/v1") == ("https://models.example.test")
    assert model_endpoint_origin("https://models.example.test:8443/v1") == (
        "https://models.example.test:8443"
    )


@pytest.mark.parametrize(
    "url",
    (
        "http://127.0.0.1:80",
        "https://127.0.0.1:443",
        "https://[::1]/v1",
        "https://localhost/v1",
        "https://169.254.169.254/latest/meta-data",
        "https://metadata.google.internal/computeMetadata/v1",
    ),
)
def test_model_endpoint_policy_rejects_local_and_metadata_urls(
    monkeypatch,
    url: str,
) -> None:
    monkeypatch.delenv(MODEL_ENDPOINT_ALLOWLIST_ENV, raising=False)

    with pytest.raises(ModelEndpointSecurityError):
        validate_model_endpoint_url_policy(url)


def test_private_http_endpoint_requires_exact_operator_allowlist(monkeypatch) -> None:
    monkeypatch.setenv(
        MODEL_ENDPOINT_ALLOWLIST_ENV,
        "http://10.20.30.40:11434",
    )

    assert validate_model_endpoint_url_policy("http://10.20.30.40:11434/v1") == ("http://10.20.30.40:11434")
    with pytest.raises(ModelEndpointSecurityError):
        validate_model_endpoint_url_policy("http://10.20.30.40:11435/v1")


def test_metadata_network_remains_blocked_when_misconfigured_in_allowlist(monkeypatch) -> None:
    monkeypatch.setenv(
        MODEL_ENDPOINT_ALLOWLIST_ENV,
        "http://169.254.169.254",
    )

    with pytest.raises(ModelEndpointSecurityError, match="云元数据"):
        validate_model_endpoint_url_policy("http://169.254.169.254/latest")

    monkeypatch.setenv(
        MODEL_ENDPOINT_ALLOWLIST_ENV,
        "http://[::ffff:169.254.169.254]",
    )
    with pytest.raises(ModelEndpointSecurityError, match="云元数据"):
        validate_model_endpoint_url_policy("http://[::ffff:169.254.169.254]/latest")


@pytest.mark.asyncio
async def test_dns_results_must_all_be_public(monkeypatch) -> None:
    monkeypatch.delenv(MODEL_ENDPOINT_ALLOWLIST_ENV, raising=False)

    async def mixed_resolver(host: str, port: int):
        assert (host, port) == ("models.example.test", 443)
        return (
            ipaddress.ip_address("93.184.216.34"),
            ipaddress.ip_address("10.0.0.5"),
        )

    with pytest.raises(ModelEndpointSecurityError, match="内网"):
        await validate_model_endpoint_url(
            "https://models.example.test/v1",
            resolver=mixed_resolver,
        )


@pytest.mark.asyncio
async def test_allowlisted_private_dns_result_is_accepted(monkeypatch) -> None:
    monkeypatch.setenv(
        MODEL_ENDPOINT_ALLOWLIST_ENV,
        "http://model-gateway.internal:11434",
    )

    async def private_resolver(host: str, port: int):
        assert (host, port) == ("model-gateway.internal", 11434)
        return (ipaddress.ip_address("10.20.30.40"),)

    origin = await validate_model_endpoint_url(
        "http://model-gateway.internal:11434/v1",
        resolver=private_resolver,
    )

    assert origin == "http://model-gateway.internal:11434"


@pytest.mark.asyncio
async def test_network_backend_connects_to_the_validated_ip_not_hostname() -> None:
    delegate = _RecordingBackend()

    async def public_resolver(host: str, port: int):
        assert (host, port) == ("models.example.test", 443)
        return (ipaddress.ip_address("93.184.216.34"),)

    backend = ValidatedModelNetworkBackend(
        allowlist=frozenset(),
        resolver=public_resolver,
        delegate=delegate,
    )

    await backend.connect_tcp("models.example.test", 443)

    assert delegate.connected_hosts == [("93.184.216.34", 443)]


@pytest.mark.asyncio
async def test_network_backend_blocks_private_dns_before_connecting() -> None:
    delegate = _RecordingBackend()

    async def private_resolver(host: str, port: int):
        return (ipaddress.ip_address("127.0.0.1"),)

    backend = ValidatedModelNetworkBackend(
        allowlist=frozenset(),
        resolver=private_resolver,
        delegate=delegate,
    )

    with pytest.raises(ModelEndpointSecurityError):
        await backend.connect_tcp("models.example.test", 443)

    assert delegate.connected_hosts == []


@pytest.mark.asyncio
async def test_model_http_client_disables_redirects_and_uses_validated_transport() -> None:
    async def public_resolver(host: str, port: int):
        return (ipaddress.ip_address("93.184.216.34"),)

    client = create_model_http_client(timeout=1.0, resolver=public_resolver)
    try:
        assert client.follow_redirects is False
        assert isinstance(client._transport, ValidatedModelHTTPTransport)
    finally:
        await client.aclose()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "system_addresses",
    [("198.18.1.30",), ("198.19.1.30", "2606:4700::1111"), ("::ffff:198.18.1.30",)],
)
async def test_model_validation_recovers_fake_ip_dns(monkeypatch, system_addresses):
    async def system_resolver(host, port):
        assert (host, port) == ("models.example.test", 443)
        return tuple(ipaddress.ip_address(address) for address in system_addresses)

    async def public_dns(host, *, transport_factory):
        assert host == "models.example.test"
        assert transport_factory is ValidatedModelHTTPTransport
        return (ipaddress.ip_address("93.184.216.34"),)

    monkeypatch.setattr(security, "resolve_model_endpoint_addresses", system_resolver)
    monkeypatch.setattr(security, "resolve_public_dns_addresses", public_dns)
    assert await validate_model_endpoint_url("https://models.example.test/v1") == (
        "https://models.example.test"
    )


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("system_addresses", "accepted"),
    [(("93.184.216.34",), True), (("10.0.0.5",), False), (("198.18.1.30", "::1"), False)],
)
async def test_model_dns_recovery_does_not_override_other_answers(monkeypatch, system_addresses, accepted):
    monkeypatch.delenv(MODEL_ENDPOINT_ALLOWLIST_ENV, raising=False)

    async def system_resolver(host, port):
        return tuple(ipaddress.ip_address(address) for address in system_addresses)

    async def public_dns(*args, **kwargs):
        raise AssertionError("Only synthetic DNS answers may trigger public DNS")

    monkeypatch.setattr(security, "resolve_model_endpoint_addresses", system_resolver)
    monkeypatch.setattr(security, "resolve_public_dns_addresses", public_dns)
    if accepted:
        await validate_model_endpoint_url("https://models.example.test/v1")
    else:
        with pytest.raises(ModelEndpointSecurityError):
            await validate_model_endpoint_url("https://models.example.test/v1")


@pytest.mark.asyncio
@pytest.mark.parametrize("address", ["198.18.2.3", "127.0.0.1", "169.254.169.254", "::ffff:10.0.0.1"])
async def test_model_fake_ip_recovery_requires_every_answer_to_be_public(monkeypatch, address):
    # Even an explicitly allowlisted model cannot use the DNS recovery as an SSRF bypass.
    monkeypatch.setenv(MODEL_ENDPOINT_ALLOWLIST_ENV, "https://models.example.test")

    async def system_resolver(host, port):
        return (ipaddress.ip_address("198.18.1.30"),)

    async def public_dns(*args, **kwargs):
        return (ipaddress.ip_address("93.184.216.34"), ipaddress.ip_address(address))

    monkeypatch.setattr(security, "resolve_model_endpoint_addresses", system_resolver)
    monkeypatch.setattr(security, "resolve_public_dns_addresses", public_dns)
    with pytest.raises(ModelEndpointSecurityError):
        await validate_model_endpoint_url("https://models.example.test/v1")


@pytest.mark.asyncio
async def test_model_fake_ip_dns_failure_has_actionable_sanitized_message(monkeypatch):
    async def system_resolver(host, port):
        return (ipaddress.ip_address("198.18.1.30"),)

    async def public_dns(*args, **kwargs):
        raise PublicDnsResolutionError("upstream details must not be shown")

    monkeypatch.setattr(security, "resolve_model_endpoint_addresses", system_resolver)
    monkeypatch.setattr(security, "resolve_public_dns_addresses", public_dns)
    with pytest.raises(security.ModelEndpointDnsError, match="Fake-IP.*redir-host") as failure:
        await validate_model_endpoint_url("https://models.example.test/v1")
    assert "upstream details" not in str(failure.value)
    assert "models.example.test" not in str(failure.value)
