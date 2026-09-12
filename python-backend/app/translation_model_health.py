from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import re
import time
from datetime import UTC, datetime
from typing import Literal
from urllib.parse import urlparse

import httpx
from pydantic import BaseModel

from .chat_completion_response import decode_chat_completion_response
from .model_endpoint_security import (
    ModelEndpointDnsError,
    ModelEndpointSecurityError,
    create_model_http_client,
    model_endpoint_origin,
)
from .models import TranslationSettings

TranslationModelCheckStatus = Literal["ready", "disabled", "unconfigured", "failed"]

_CHECK_CACHE_TTL_SECONDS = 60.0
_LOGGER = logging.getLogger("qingjuan.translation")
_CACHE_KEY: str | None = None
_CACHE_CREATED_AT = 0.0
_CACHE_VALUE: TranslationModelCheckResponse | None = None
_CACHE_LOCK: asyncio.Lock | None = None
_CACHE_LOCK_LOOP: asyncio.AbstractEventLoop | None = None


class TranslationModelCheckResponse(BaseModel):
    enabled: bool
    configured: bool
    available: bool
    status: TranslationModelCheckStatus
    model: str | None
    supportsVision: bool
    checkedAt: str
    latencyMs: int | None = None
    message: str
    cached: bool = False


def normalize_openai_compatible_base_url(value: str) -> str:
    normalized_value = value.strip()
    if not normalized_value:
        return ""
    try:
        model_endpoint_origin(normalized_value)
        parsed = urlparse(normalized_value)
    except (ModelEndpointSecurityError, ValueError):
        return ""
    normalized_path = parsed.path.rstrip("/")
    endpoint_suffix = "/chat/completions"
    if normalized_path.lower().endswith(endpoint_suffix):
        normalized_path = normalized_path[: -len(endpoint_suffix)].rstrip("/")
    if not normalized_path:
        normalized_path = "/v1"
    return (
        parsed._replace(
            path=normalized_path,
            params="",
            query="",
            fragment="",
        )
        .geturl()
        .rstrip("/")
    )


def resolve_openai_compatible_model_config(
    settings: TranslationSettings,
    *,
    feature_name: str,
) -> tuple[str, str, str]:
    model_config = settings.translationModel
    if not model_config.enabled:
        raise ValueError(f"{feature_name}模型未启用，请先在管理界面启用翻译模型")
    base_url = normalize_openai_compatible_base_url(str(model_config.baseUrl or ""))
    api_key = str(model_config.apiKey or "").strip()
    configured_model = str(model_config.model or "").strip()

    if not base_url:
        raise ValueError(f"{feature_name} API 地址未配置或无效")
    base_host = (urlparse(base_url).hostname or "").lower()
    if base_host in {"example.com", "www.example.com", "your-newapi-endpoint"}:
        raise ValueError(f"{feature_name} API 地址仍是占位值，请在管理界面填写真实地址")
    if not api_key:
        raise ValueError(f"{feature_name} API 密钥未配置")
    if not configured_model:
        raise ValueError(f"{feature_name}模型未配置")
    return base_url, api_key, configured_model


async def check_translation_model(
    settings: TranslationSettings,
    *,
    force: bool = False,
    timeout_seconds: float = 12.0,
) -> TranslationModelCheckResponse:
    global _CACHE_CREATED_AT, _CACHE_KEY, _CACHE_VALUE
    cache_key = _configuration_fingerprint(settings)
    async with _cache_lock():
        now = time.monotonic()
        if (
            not force
            and cache_key == _CACHE_KEY
            and _CACHE_VALUE is not None
            and now - _CACHE_CREATED_AT < _CHECK_CACHE_TTL_SECONDS
        ):
            return _CACHE_VALUE.model_copy(update={"cached": True})
        result = await probe_translation_model(
            settings,
            timeout_seconds=timeout_seconds,
        )
        _CACHE_KEY = cache_key
        _CACHE_CREATED_AT = time.monotonic()
        _CACHE_VALUE = result.model_copy(update={"cached": False})
        return result


def get_translation_model_check_snapshot(
    settings: TranslationSettings,
) -> TranslationModelCheckResponse:
    """Return cached/passive status without making an outbound request."""

    cache_key = _configuration_fingerprint(settings)
    # Passive readers need the last check for this configuration. The TTL only
    # controls when an explicit active check probes again; age is not failure.
    if cache_key == _CACHE_KEY and _CACHE_VALUE is not None:
        return _CACHE_VALUE.model_copy(update={"cached": True})

    model_config = settings.translationModel
    public_model = _public_model_name(model_config.model)
    configured = bool(
        normalize_openai_compatible_base_url(str(model_config.baseUrl or ""))
        and str(model_config.apiKey or "").strip()
        and str(model_config.model or "").strip()
    )
    if not model_config.enabled:
        return _result(
            enabled=False,
            configured=configured,
            available=False,
            status="disabled",
            model=public_model,
            supports_vision=model_config.supportsVision,
            message="翻译模型未启用",
        )
    if not configured:
        return _result(
            enabled=True,
            configured=False,
            available=False,
            status="unconfigured",
            model=public_model,
            supports_vision=model_config.supportsVision,
            message="翻译模型配置不完整，请补充地址、密钥和模型名",
        )
    return _result(
        enabled=True,
        configured=True,
        available=False,
        status="failed",
        model=public_model,
        supports_vision=model_config.supportsVision,
        message="翻译模型尚未由管理员执行安全自检",
    )


async def probe_translation_model(
    settings: TranslationSettings,
    *,
    timeout_seconds: float = 12.0,
    client: httpx.AsyncClient | None = None,
) -> TranslationModelCheckResponse:
    model_config = settings.translationModel
    public_model = _public_model_name(model_config.model)
    raw_base_url = str(model_config.baseUrl or "").strip()
    raw_api_key = str(model_config.apiKey or "").strip()
    raw_model = str(model_config.model or "").strip()
    configured = bool(normalize_openai_compatible_base_url(raw_base_url) and raw_api_key and raw_model)
    if not model_config.enabled:
        return _result(
            enabled=False,
            configured=configured,
            available=False,
            status="disabled",
            model=public_model,
            supports_vision=model_config.supportsVision,
            message="翻译模型未启用",
        )
    try:
        base_url, api_key, model = resolve_openai_compatible_model_config(
            settings,
            feature_name="翻译",
        )
    except ValueError:
        return _result(
            enabled=True,
            configured=False,
            available=False,
            status="unconfigured",
            model=public_model,
            supports_vision=model_config.supportsVision,
            message="翻译模型配置不完整，请补充地址、密钥和模型名",
        )

    payload: dict[str, object] = {
        "model": model,
        "stream": False,
        "temperature": 0,
        "max_tokens": 8,
        "messages": [
            {
                "role": "user",
                "content": "Reply with OK.",
            }
        ],
    }
    if "deepseek-v4" in model.lower():
        payload["thinking"] = {"type": "disabled"}
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    started = time.perf_counter()
    owns_client = client is None
    active_client = client or create_model_http_client(
        timeout=httpx.Timeout(timeout_seconds, connect=min(timeout_seconds, 5.0)),
    )
    try:
        response = await active_client.post(
            f"{base_url}/chat/completions",
            headers=headers,
            json=payload,
        )
        latency_ms = max(0, round((time.perf_counter() - started) * 1000))
        if response.status_code < 200 or response.status_code >= 300:
            message = _status_error_message(response.status_code)
            _LOGGER.warning("翻译模型自检失败：model=%s status=%s", public_model, response.status_code)
            return _result(
                enabled=True,
                configured=True,
                available=False,
                status="failed",
                model=public_model,
                supports_vision=model_config.supportsVision,
                latency_ms=latency_ms,
                message=message,
            )
        try:
            response_payload = decode_chat_completion_response(response)
        except ValueError:
            response_payload = None
        if not _valid_completion_payload(response_payload):
            _LOGGER.warning("翻译模型自检返回不兼容响应：model=%s", public_model)
            return _result(
                enabled=True,
                configured=True,
                available=False,
                status="failed",
                model=public_model,
                supports_vision=model_config.supportsVision,
                latency_ms=latency_ms,
                message="翻译服务返回不兼容的响应，请检查 OpenAI 兼容接口配置",
            )
        _LOGGER.info("翻译模型自检通过：model=%s latency_ms=%s", public_model, latency_ms)
        return _result(
            enabled=True,
            configured=True,
            available=True,
            status="ready",
            model=public_model,
            supports_vision=model_config.supportsVision,
            latency_ms=latency_ms,
            message="翻译模型自检通过",
        )
    except ModelEndpointSecurityError as error:
        _LOGGER.warning("翻译模型自检地址校验或解析失败：model=%s", public_model)
        return _result(
            enabled=True,
            configured=True,
            available=False,
            status="failed",
            model=public_model,
            supports_vision=model_config.supportsVision,
            message=str(error)
            if isinstance(error, ModelEndpointDnsError)
            else "翻译模型 API 地址不符合服务端出站安全策略",
        )
    except httpx.TimeoutException:
        _LOGGER.warning("翻译模型自检超时：model=%s", public_model)
        return _result(
            enabled=True,
            configured=True,
            available=False,
            status="failed",
            model=public_model,
            supports_vision=model_config.supportsVision,
            message="翻译服务自检超时，请检查服务状态",
        )
    except httpx.HTTPError:
        _LOGGER.warning("翻译模型自检无法连接：model=%s", public_model)
        return _result(
            enabled=True,
            configured=True,
            available=False,
            status="failed",
            model=public_model,
            supports_vision=model_config.supportsVision,
            message="无法连接翻译服务，请检查服务器网络和供应商状态",
        )
    finally:
        if owns_client:
            await active_client.aclose()


def reset_translation_model_check_cache() -> None:
    global _CACHE_CREATED_AT, _CACHE_KEY, _CACHE_VALUE
    _CACHE_KEY = None
    _CACHE_CREATED_AT = 0.0
    _CACHE_VALUE = None


def _cache_lock() -> asyncio.Lock:
    global _CACHE_LOCK, _CACHE_LOCK_LOOP
    loop = asyncio.get_running_loop()
    if _CACHE_LOCK is None or _CACHE_LOCK_LOOP is not loop:
        _CACHE_LOCK = asyncio.Lock()
        _CACHE_LOCK_LOOP = loop
    return _CACHE_LOCK


def _configuration_fingerprint(settings: TranslationSettings) -> str:
    model_config = settings.translationModel
    payload = json.dumps(
        {
            "enabled": model_config.enabled,
            "baseUrl": normalize_openai_compatible_base_url(model_config.baseUrl),
            "apiKeyHash": hashlib.sha256(model_config.apiKey.encode("utf-8")).hexdigest(),
            "model": model_config.model.strip(),
            "supportsVision": model_config.supportsVision,
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _valid_completion_payload(payload: object) -> bool:
    if not isinstance(payload, dict):
        return False
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        return False
    return isinstance(choices[0].get("message"), dict)


def _status_error_message(status_code: int) -> str:
    if status_code in {401, 403}:
        return "翻译服务认证失败，请在管理界面检查 API 密钥"
    if status_code == 404:
        return "翻译接口或模型不存在，请检查 API 地址和模型名"
    if status_code == 429:
        return "翻译服务当前限流，请稍后重新检测"
    if status_code >= 500:
        return "翻译服务暂时不可用，请稍后重新检测"
    return "翻译服务拒绝了自检请求，请检查接口配置和模型名"


def _public_model_name(value: str) -> str | None:
    normalized = re.sub(r"[\x00-\x1f\x7f]+", " ", str(value or "")).strip()
    if not normalized:
        return None
    return normalized[:120]


def _result(
    *,
    enabled: bool,
    configured: bool,
    available: bool,
    status: TranslationModelCheckStatus,
    model: str | None,
    supports_vision: bool,
    message: str,
    latency_ms: int | None = None,
) -> TranslationModelCheckResponse:
    return TranslationModelCheckResponse(
        enabled=enabled,
        configured=configured,
        available=available,
        status=status,
        model=model,
        supportsVision=supports_vision,
        checkedAt=datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z"),
        latencyMs=latency_ms,
        message=message,
    )
