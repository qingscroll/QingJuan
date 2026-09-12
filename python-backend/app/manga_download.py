from __future__ import annotations

import asyncio
import time
from collections.abc import Awaitable, Callable, Mapping
from datetime import UTC
from email.utils import parsedate_to_datetime
from io import BytesIO
from pathlib import Path
from urllib.parse import urlparse

import httpx
from PIL import Image, UnidentifiedImageError

MANGA_RETRYABLE_STATUS_CODES = {408, 409, 425, 429, 500, 502, 503, 504}
MANGA_IMAGE_MAX_ATTEMPTS = 4
MANGA_IMAGE_MAX_RETRY_DELAY_SECONDS = 12.0
SUPPORTED_IMAGE_FORMATS = {"BMP", "GIF", "JPEG", "PNG", "WEBP"}

SleepCallback = Callable[[float], Awaitable[None]]


class InvalidMangaImageError(ValueError):
    """远端返回成功状态，但正文不是可解码的漫画图片。"""


def is_valid_image_bytes(content: bytes) -> bool:
    if len(content) < 16:
        return False
    try:
        with Image.open(BytesIO(content)) as image:
            image.verify()
            return (image.format or "").upper() in SUPPORTED_IMAGE_FORMATS
    except (OSError, UnidentifiedImageError, ValueError):
        return False


def is_valid_image_file(path: Path) -> bool:
    try:
        if not path.is_file() or path.stat().st_size < 16:
            return False
        with Image.open(path) as image:
            image.verify()
            return (image.format or "").upper() in SUPPORTED_IMAGE_FORMATS
    except (OSError, UnidentifiedImageError, ValueError):
        return False


def write_image_atomic(target_path: Path, content: bytes) -> None:
    from .storage_quota import quota_replace

    if not is_valid_image_bytes(content):
        raise InvalidMangaImageError("响应内容不是有效图片")

    target_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = target_path.with_suffix(f"{target_path.suffix}.part")
    try:
        temporary_path.write_bytes(content)
        if not is_valid_image_file(temporary_path):
            raise InvalidMangaImageError("临时文件不是有效图片")
        quota_replace(temporary_path, target_path)
    finally:
        temporary_path.unlink(missing_ok=True)


def _retry_delay_seconds(response: httpx.Response | None, attempt: int, base_delay: float) -> float:
    if response is not None:
        retry_after = response.headers.get("Retry-After", "").strip()
        if retry_after:
            try:
                return min(MANGA_IMAGE_MAX_RETRY_DELAY_SECONDS, max(0.0, float(retry_after)))
            except ValueError:
                try:
                    retry_at = parsedate_to_datetime(retry_after)
                    if retry_at.tzinfo is None:
                        retry_at = retry_at.replace(tzinfo=UTC)
                    return min(
                        MANGA_IMAGE_MAX_RETRY_DELAY_SECONDS,
                        max(0.0, retry_at.timestamp() - time.time()),
                    )
                except (TypeError, ValueError, OverflowError):
                    pass

    return min(MANGA_IMAGE_MAX_RETRY_DELAY_SECONDS, max(0.0, base_delay) * (2**attempt))


async def fetch_image_with_retry(
    client: httpx.AsyncClient,
    url: str,
    *,
    headers: Mapping[str, str],
    max_attempts: int = MANGA_IMAGE_MAX_ATTEMPTS,
    base_delay: float = 0.6,
    sleep: SleepCallback = asyncio.sleep,
) -> bytes:
    attempts = max(1, min(max_attempts, 8))
    last_transport_error: httpx.TransportError | None = None
    host = urlparse(url).hostname or "未知图片主机"

    for attempt in range(attempts):
        response: httpx.Response | None = None
        try:
            response = await client.get(url, headers=dict(headers))
            if response.status_code in MANGA_RETRYABLE_STATUS_CODES:
                if attempt < attempts - 1:
                    await sleep(_retry_delay_seconds(response, attempt, base_delay))
                    continue
                response.raise_for_status()

            response.raise_for_status()
            if is_valid_image_bytes(response.content):
                return response.content
            if attempt >= attempts - 1:
                raise InvalidMangaImageError(f"{host} 连续返回了不可解码的图片内容")
        except httpx.TransportError as exc:
            last_transport_error = exc
            if attempt >= attempts - 1:
                raise

        await sleep(_retry_delay_seconds(response, attempt, base_delay))

    if last_transport_error is not None:
        raise last_transport_error
    raise InvalidMangaImageError(f"{host} 图片下载失败")
