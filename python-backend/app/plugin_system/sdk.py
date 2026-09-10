"""Public plugin API v1. This module is available in source and frozen backends."""

from __future__ import annotations

import json
from urllib.parse import urljoin

import httpx
from bs4 import BeautifulSoup

from ..scraper_network_security import validate_public_url
from ..site_plugins.base import SitePlugin, host_matches

API_VERSION = 1
MAX_RESPONSE_BYTES = 4 * 1024 * 1024


class PluginContext:
    """One invocation's public HTTP client; never receives user or admin credentials."""

    def __init__(self, plugin: SitePlugin, base_url: str, client: httpx.AsyncClient):
        self.plugin_id = plugin.id
        self.base_url = base_url
        self._domains = plugin.network_domains
        self._client = client
        self._requests = 0

    def resolve_url(self, value: str) -> str:
        url = urljoin(self.base_url, value)
        validate_public_url(url)
        if not host_matches(url, self._domains):
            raise ValueError("链接超出插件声明的网络域名")
        return url

    async def get_text(self, url: str, *, params: dict[str, str] | None = None) -> str:
        current = self.resolve_url(url)
        for _ in range(6):
            self._requests += 1
            if self._requests > 30:
                raise ValueError("单次插件调用请求数超限")
            async with self._client.stream("GET", current, params=params, follow_redirects=False) as response:
                if response.is_redirect:
                    current = self.resolve_url(urljoin(str(response.url), response.headers["location"]))
                    params = None
                    continue
                response.raise_for_status()
                data = bytearray()
                async for chunk in response.aiter_bytes():
                    data.extend(chunk)
                    if len(data) > MAX_RESPONSE_BYTES:
                        raise ValueError("插件上游响应超过 4 MiB")
                return bytes(data).decode(response.encoding or "utf-8", errors="replace")
        raise ValueError("插件上游重定向次数超限")

    async def get_json(self, url: str, *, params: dict[str, str] | None = None):
        return json.loads(await self.get_text(url, params=params))

    @staticmethod
    def parse_html(text: str) -> BeautifulSoup:
        return BeautifulSoup(text, "html.parser")
