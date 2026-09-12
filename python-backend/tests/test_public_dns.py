import ipaddress

import httpx
import pytest

from app.public_dns import PublicDnsResolutionError, is_fake_ip_address, resolve_public_dns_addresses


@pytest.mark.parametrize(
    "value,expected",
    [
        ("198.17.255.255", False),
        ("198.18.0.0", True),
        ("198.19.255.255", True),
        ("198.20.0.0", False),
        ("::ffff:198.18.0.7", True),
        ("::1", False),
    ],
)
def test_fake_ip_classification_includes_only_benchmark_range_and_mapped_ipv4(value, expected):
    assert is_fake_ip_address(ipaddress.ip_address(value)) is expected


async def test_returns_all_addresses_for_caller_policy_without_retrying_private_answers():
    requests = []
    bootstrap_resolvers = []

    def transport_factory(*, allowlist, resolver):
        assert allowlist == frozenset()
        bootstrap_resolvers.append(resolver)

        async def respond(request):
            pinned = await resolver(request.url.host, request.url.port or 443)
            requests.append((request.url.host, request.url.params["type"], pinned))
            record_type = int(request.url.params["type"])
            return httpx.Response(
                200,
                json={
                    "Status": 0,
                    "TC": False,
                    "Answer": [
                        {"type": 5, "data": "gateway.example"},
                        {
                            "type": record_type,
                            "data": "10.0.0.2" if record_type == 1 else "2606:4700::1111",
                        },
                    ],
                },
            )

        return httpx.MockTransport(respond)

    result = await resolve_public_dns_addresses("models.example", transport_factory=transport_factory)
    assert result == (ipaddress.ip_address("10.0.0.2"), ipaddress.ip_address("2606:4700::1111"))
    assert {host for host, _, _ in requests} == {"cloudflare-dns.com"}
    assert {record_type for _, record_type, _ in requests} == {"1", "28"}
    assert all(addresses == (ipaddress.ip_address("1.1.1.1"),) for _, _, addresses in requests)
    for host, port in [("cloudflare-dns.com", 80), ("evil.example", 443)]:
        with pytest.raises(PublicDnsResolutionError):
            await bootstrap_resolvers[0](host, port)


@pytest.mark.parametrize(
    "invalid",
    [
        {"Status": False},
        {"Status": 0.0},
        {"Status": 0, "TC": "false"},
        {"Status": 0, "Answer": {}},
        {"Status": 0, "Answer": [{"type": True, "data": "93.184.216.34"}]},
        {"Status": 0, "Answer": [{"type": 1.0, "data": "93.184.216.34"}]},
        {"Status": 0, "Answer": [{"type": 28, "data": "93.184.216.34"}]},
        {"Status": 0, "Answer": [{"type": 28, "data": "fe80::1%eth0"}]},
    ],
)
async def test_malformed_provider_answers_use_backup_without_accepting_coerced_values(invalid):
    requests = []

    def transport_factory(*, allowlist, resolver):
        async def respond(request):
            addresses = await resolver(request.url.host, request.url.port or 443)
            requests.append((request.url.host, addresses))
            if request.url.host == "cloudflare-dns.com":
                return httpx.Response(200, json=invalid)
            return httpx.Response(
                200,
                json={
                    "Status": 0,
                    "Answer": [{"type": 1, "data": "93.184.216.34"}]
                    if request.url.params["type"] == "1"
                    else [],
                },
            )

        return httpx.MockTransport(respond)

    result = await resolve_public_dns_addresses("models.example", transport_factory=transport_factory)
    assert result == (ipaddress.ip_address("93.184.216.34"),)
    assert requests == [
        ("cloudflare-dns.com", (ipaddress.ip_address("1.1.1.1"),)),
        ("cloudflare-dns.com", (ipaddress.ip_address("1.1.1.1"),)),
        ("dns.google", (ipaddress.ip_address("8.8.8.8"),)),
        ("dns.google", (ipaddress.ip_address("8.8.8.8"),)),
    ]
