import hashlib
import ipaddress
import json
import os
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient

from app import admin_auth, db, model_endpoint_security
from app.admin_auth import (
    ADMIN_CSRF_HEADER,
    ADMIN_PASSWORD_HASH_ENV,
    ADMIN_SESSION_SECRET_ENV,
    LOCAL_ADMIN_REQUEST_HEADER,
    TRUST_LOCAL_ADMIN_ENV,
    hash_admin_password,
)
from app.api import translation_model as translation_model_api
from app.api.admin import router as admin_router
from app.application import create_application
from app.models import OpenAICompatibleConfig, TranslationSettings
from app.security import API_PREFIX
from app.translation_model_health import (
    TranslationModelCheckResponse,
    check_translation_model,
    get_translation_model_check_snapshot,
    probe_translation_model,
    reset_translation_model_check_cache,
)


def _settings(
    *,
    enabled: bool = True,
    api_key: str = "provider-secret-key",
    model: str = "translation-model",
    base_url: str = "https://models.example.test/v1/chat/completions",
) -> TranslationSettings:
    return TranslationSettings(
        translationModel=OpenAICompatibleConfig(
            enabled=enabled,
            baseUrl=base_url,
            apiKey=api_key,
            model=model,
            supportsVision=False,
        )
    )


@pytest.mark.asyncio
async def test_disabled_model_check_does_not_contact_provider() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError(f"disabled model must not request {request.url}")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await probe_translation_model(_settings(enabled=False), client=client)

    assert result.status == "disabled"
    assert result.available is False
    assert result.enabled is False


@pytest.mark.asyncio
async def test_model_probe_uses_minimal_completion_without_exposing_secret() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        assert request.url == "https://models.example.test/v1/chat/completions"
        assert request.headers["Authorization"] == "Bearer provider-secret-key"
        payload = json.loads(request.content)
        assert payload["model"] == "translation-model"
        assert payload["max_tokens"] == 8
        assert payload["messages"] == [{"role": "user", "content": "Reply with OK."}]
        assert "chapter" not in request.content.decode().lower()
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "message": {"role": "assistant", "content": "OK"},
                        "finish_reason": "stop",
                    }
                ]
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await probe_translation_model(_settings(), client=client)

    assert result.status == "ready"
    assert result.available is True
    assert result.configured is True
    assert result.model == "translation-model"
    assert "provider-secret-key" not in result.model_dump_json()
    assert "models.example.test" not in result.model_dump_json()


@pytest.mark.asyncio
async def test_model_probe_maps_provider_auth_error_without_response_leak() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            401,
            json={"error": {"message": "bad key provider-secret-key"}},
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await probe_translation_model(_settings(), client=client)

    assert result.status == "failed"
    assert result.available is False
    assert "认证失败" in result.message
    assert "provider-secret-key" not in result.model_dump_json()
    assert "bad key" not in result.model_dump_json()


@pytest.mark.asyncio
async def test_model_probe_blocks_loopback_before_sending_authorization(monkeypatch) -> None:
    monkeypatch.delenv("QINGJUAN_MODEL_ENDPOINT_ALLOWLIST", raising=False)

    result = await probe_translation_model(
        _settings(base_url="https://127.0.0.1:443/v1"),
    )

    assert result.status == "failed"
    assert result.available is False
    assert "出站安全策略" in result.message
    assert "provider-secret-key" not in result.model_dump_json()


@pytest.mark.asyncio
async def test_model_probe_blocks_hostname_that_resolves_to_private_ip(monkeypatch) -> None:
    monkeypatch.delenv("QINGJUAN_MODEL_ENDPOINT_ALLOWLIST", raising=False)

    async def private_resolver(host: str, port: int):
        assert (host, port) == ("models.example.test", 443)
        return (ipaddress.ip_address("10.0.0.8"),)

    monkeypatch.setattr(
        model_endpoint_security,
        "resolve_model_endpoint_addresses",
        private_resolver,
    )

    result = await probe_translation_model(_settings())

    assert result.status == "failed"
    assert "出站安全策略" in result.message


@pytest.mark.asyncio
async def test_model_check_caches_same_configuration_and_supports_force(monkeypatch) -> None:
    reset_translation_model_check_cache()
    calls = 0

    async def fake_probe(
        settings: TranslationSettings,
        *,
        timeout_seconds: float = 12.0,
        client: httpx.AsyncClient | None = None,
    ) -> TranslationModelCheckResponse:
        nonlocal calls
        calls += 1
        return TranslationModelCheckResponse(
            enabled=True,
            configured=True,
            available=True,
            status="ready",
            model="translation-model",
            supportsVision=False,
            checkedAt="2030-01-01T00:00:00Z",
            latencyMs=12,
            message="自检通过",
        )

    monkeypatch.setattr("app.translation_model_health.probe_translation_model", fake_probe)
    first = await check_translation_model(_settings())
    second = await check_translation_model(_settings())
    forced = await check_translation_model(_settings(), force=True)

    assert calls == 2
    assert first.cached is False
    assert second.cached is True
    assert forced.cached is False


def test_model_check_snapshot_never_probes_and_hides_uncached_provider() -> None:
    reset_translation_model_check_cache()

    result = get_translation_model_check_snapshot(_settings())

    assert result.status == "failed"
    assert result.available is False
    assert result.configured is True
    assert result.cached is False
    assert "管理员" in result.message
    assert "models.example.test" not in result.model_dump_json()


@pytest.mark.asyncio
async def test_passive_model_status_retains_last_check_after_probe_cache_expires(monkeypatch):
    from app import translation_model_health as health

    reset_translation_model_check_cache()
    clock = [100.0]
    calls = []
    monkeypatch.setattr(health.time, "monotonic", lambda: clock[0])

    async def probe(settings, **kwargs):
        calls.append(settings)
        return TranslationModelCheckResponse(
            enabled=True, configured=True, available=len(calls) == 1,
            status="ready" if len(calls) == 1 else "failed", model="translation-model",
            supportsVision=False, checkedAt="2030-01-01T00:00:00Z", message="last probe result",
        )

    monkeypatch.setattr(health, "probe_translation_model", probe)
    try:
        await check_translation_model(_settings(), force=True)
        for seconds in (59, 61, 3600):
            clock[0] = 100 + seconds
            snapshot = get_translation_model_check_snapshot(_settings())
            assert snapshot.available and snapshot.status == "ready" and snapshot.cached
            assert snapshot.checkedAt == "2030-01-01T00:00:00Z"
        assert len(calls) == 1
        assert not get_translation_model_check_snapshot(_settings(api_key="changed-key")).available
        assert not get_translation_model_check_snapshot(_settings(enabled=False)).available
        assert not (await check_translation_model(_settings(), force=True)).available
        clock[0] += 3600
        assert get_translation_model_check_snapshot(_settings()).status == "failed"
        assert len(calls) == 2
    finally:
        reset_translation_model_check_cache()


def test_model_check_endpoint_requires_backend_auth_and_returns_safe_dto(
    monkeypatch,
    tmp_path: Path,
) -> None:
    token = "client-connection-token"
    monkeypatch.setenv(
        "QINGJUAN_AUTH_TOKEN_SHA256",
        hashlib.sha256(token.encode()).hexdigest(),
    )
    monkeypatch.setenv(
        ADMIN_PASSWORD_HASH_ENV,
        hash_admin_password(
            "diagnostic-admin-password",
            salt=b"0123456789abcdef",
            iterations=100_000,
        ),
    )
    monkeypatch.setenv(ADMIN_SESSION_SECRET_ENV, "55" * 32)
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    db.init_db()

    force_values: list[bool] = []
    snapshot_calls = 0

    async def fake_check(
        settings: TranslationSettings,
        *,
        force: bool = False,
        timeout_seconds: float = 12.0,
    ) -> TranslationModelCheckResponse:
        force_values.append(force)
        return TranslationModelCheckResponse(
            enabled=True,
            configured=True,
            available=True,
            status="ready",
            model="translation-model",
            supportsVision=False,
            checkedAt="2030-01-01T00:00:00Z",
            latencyMs=18,
            message="Linux 服务端翻译模型自检通过",
        )

    monkeypatch.setattr(translation_model_api, "check_translation_model", fake_check)

    def fake_snapshot(settings: TranslationSettings) -> TranslationModelCheckResponse:
        nonlocal snapshot_calls
        snapshot_calls += 1
        return TranslationModelCheckResponse(
            enabled=True,
            configured=True,
            available=True,
            status="ready",
            model="translation-model",
            supportsVision=False,
            checkedAt="2030-01-01T00:00:00Z",
            latencyMs=18,
            message="Linux 服务端翻译模型已缓存",
            cached=True,
        )

    monkeypatch.setattr(
        translation_model_api,
        "get_translation_model_check_snapshot",
        fake_snapshot,
    )
    application = create_application(
        routers=[translation_model_api.router],
        public_routers=[admin_router],
        api_prefix=API_PREFIX,
        authenticate=True,
    )

    with TestClient(application) as client:
        rejected = client.post(f"{API_PREFIX}/translation-model/check?force=true")
        accepted = client.post(
            f"{API_PREFIX}/translation-model/check?force=false",
            headers={"Authorization": f"Bearer {token}"},
        )
        forced_bearer = client.post(
            f"{API_PREFIX}/translation-model/check?force=true",
            headers={"Authorization": f"Bearer {token}"},
        )
        session = client.post(
            "/admin/api/login",
            json={"password": "diagnostic-admin-password"},
        ).json()
        forced_admin = client.post(
            f"{API_PREFIX}/translation-model/check?force=true",
            headers={ADMIN_CSRF_HEADER: session["csrfToken"]},
        )

    assert rejected.status_code == 401
    assert accepted.status_code == 200
    assert forced_bearer.status_code == 401
    assert forced_admin.status_code == 200
    assert force_values == [True]
    assert snapshot_calls == 1
    assert accepted.json()["available"] is True
    assert "provider-secret-key" not in accepted.text
    assert "models.example.test" not in accepted.text


def test_trusted_windows_loopback_can_force_model_check_without_admin_web(
    monkeypatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setenv(TRUST_LOCAL_ADMIN_ENV, "1")
    monkeypatch.setattr(
        admin_auth,
        "os",
        SimpleNamespace(name="nt", getenv=os.getenv),
    )
    monkeypatch.delenv("QINGJUAN_AUTH_TOKEN_SHA256", raising=False)
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    db.init_db()
    force_values: list[bool] = []

    async def fake_check(
        settings: TranslationSettings,
        *,
        force: bool = False,
    ) -> TranslationModelCheckResponse:
        force_values.append(force)
        return TranslationModelCheckResponse(
            enabled=True,
            configured=True,
            available=True,
            status="ready",
            model="local-model",
            supportsVision=False,
            checkedAt="2030-01-01T00:00:00Z",
            latencyMs=8,
            message="模型可用",
            cached=False,
        )

    monkeypatch.setattr(translation_model_api, "check_translation_model", fake_check)
    application = create_application(
        routers=[translation_model_api.router],
        api_prefix=API_PREFIX,
        authenticate=True,
    )

    with TestClient(
        application,
        base_url="http://127.0.0.1",
        client=("127.0.0.1", 50000),
    ) as client:
        response = client.post(
            f"{API_PREFIX}/translation-model/check?force=true",
            headers={LOCAL_ADMIN_REQUEST_HEADER: "1"},
        )

    assert response.status_code == 200
    assert response.json()["model"] == "local-model"
    assert force_values == [True]
