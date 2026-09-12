"""推荐抓取统一通过青卷公网地址验证与连接固定边界。"""

from __future__ import annotations

import asyncio
from collections.abc import Callable
from typing import Any

import httpx

from ..scraper_network_security import create_public_http_client, validate_public_url
from .config import settings

DEFAULT_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
)
MOBILE_UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
)


class UpstreamError(RuntimeError):
    """抓取失败；不携带上游正文、凭据或地址。"""


class SiteHttp:
    def __init__(
        self,
        base_url: str = "",
        *,
        headers: dict[str, str] | None = None,
        cookies: dict[str, str] | None = None,
        ua: str = DEFAULT_UA,
        timeout: float | None = None,
        follow_redirects: bool = True,
        encoding: str | None = None,
        allowed: Callable[[], bool] | None = None,
    ):
        self.base_url = base_url.rstrip("/")
        self.encoding = encoding
        self._allowed = allowed
        merged = {
            "User-Agent": ua,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8,ja;q=0.7",
            **(headers or {}),
        }
        self._client = create_public_http_client(
            timeout=httpx.Timeout(timeout or settings.timeout),
            headers=merged,
            follow_redirects=follow_redirects,
        )
        # Public discovery never reuses authenticated site-account cookies.
        if cookies:
            raise ValueError("推荐列表只允许匿名访问")

    async def aclose(self) -> None:
        await self._client.aclose()

    def absolute(self, url: str) -> str:
        if url.startswith("//"):
            return "https:" + url
        if url.startswith(("http://", "https://")):
            return url
        return f"{self.base_url}/{url.lstrip('/')}"

    async def request(self, method: str, url: str, **kwargs: Any) -> httpx.Response:
        target = self.absolute(url)
        validate_public_url(target)
        for attempt in range(settings.retries + 1):
            if self._allowed is not None and not self._allowed():
                raise UpstreamError("该站点插件已停用，请在插件管理中启用")
            try:
                async with self._client.stream(method, target, **kwargs) as upstream:
                    chunks = []
                    length = 0
                    async for chunk in upstream.aiter_bytes():
                        length += len(chunk)
                        if length > 8 * 1024 * 1024:
                            raise UpstreamError("站点返回的数据过大，请选择其他栏目")
                        chunks.append(chunk)
                    headers = httpx.Headers(upstream.headers)
                    headers.pop("content-encoding", None)
                    headers.pop("content-length", None)
                    response = httpx.Response(
                        upstream.status_code,
                        headers=headers,
                        content=b"".join(chunks),
                        request=upstream.request,
                    )
                if response.status_code not in {429, 500, 502, 503, 504} or attempt == settings.retries:
                    return response
            except (httpx.HTTPError, TimeoutError) as error:
                if attempt == settings.retries:
                    raise UpstreamError("站点连接失败，请稍后重试") from error
            await asyncio.sleep(0.5 * (attempt + 1))
        raise UpstreamError("站点连接失败，请稍后重试")

    async def get(self, url: str, **kwargs: Any) -> httpx.Response:
        return await self.request("GET", url, **kwargs)

    async def post(self, url: str, **kwargs: Any) -> httpx.Response:
        return await self.request("POST", url, **kwargs)

    async def text(self, url: str, *, encoding: str | None = None, **kwargs: Any) -> str:
        response = await self.get(url, **kwargs)
        if response.status_code >= 400:
            raise UpstreamError("站点暂时拒绝访问，请稍后重试")
        return decode(response, encoding or self.encoding)

    async def json(self, url: str, *, method: str = "GET", **kwargs: Any) -> Any:
        response = await self.request(method, url, **kwargs)
        if response.status_code >= 400:
            raise UpstreamError("站点暂时拒绝访问，请稍后重试")
        try:
            return response.json()
        except ValueError as error:
            raise UpstreamError("站点返回了无法解析的数据，请稍后重试") from error

    async def json_post(self, url: str, *, data: Any = None, json_body: Any = None, **kwargs: Any) -> Any:
        return await self.json(url, method="POST", data=data, json=json_body, **kwargs)


def decode(response: httpx.Response, encoding: str | None = None) -> str:
    for candidate in [encoding, response.charset_encoding, "utf-8", "gbk", "gb18030"]:
        if candidate:
            try:
                return response.content.decode(candidate)
            except (UnicodeDecodeError, LookupError):
                continue
    return response.content.decode("utf-8", errors="replace")
