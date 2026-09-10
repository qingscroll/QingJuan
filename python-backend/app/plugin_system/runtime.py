from __future__ import annotations

import asyncio
from urllib.parse import urljoin

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from ..models import BuiltinSiteSearchResult, ChapterPreview, PreviewResponse
from ..scraper_network_security import create_public_http_client, validate_public_url
from ..site_plugins.base import SitePlugin, host_matches
from .sdk import PluginContext

CALL_TIMEOUT_SECONDS = 30


class _Output(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class _Chapter(_Output):
    title: str = Field(min_length=1, max_length=500)
    url: str = Field(min_length=1, max_length=4096)
    pageCount: int = Field(default=0, ge=0)
    accessRestricted: bool = False


class _Preview(_Output):
    title: str = Field(min_length=1, max_length=500)
    author: str | None = Field(default=None, max_length=500)
    synopsis: str = Field(default="", max_length=100000)
    cover: str | None = Field(default=None, max_length=4096)
    chapters: list[_Chapter] = Field(min_length=1, max_length=100000)


class _Content(_Output):
    text: str = Field(default="", max_length=4 * 1024 * 1024)
    imageUrls: list[str] = Field(default_factory=list, max_length=3000)


class _SearchItem(_Output):
    title: str = Field(min_length=1, max_length=500)
    sourceUrl: str = Field(min_length=1, max_length=4096)
    author: str | None = Field(default=None, max_length=500)
    synopsis: str = Field(default="", max_length=100000)
    cover: str | None = Field(default=None, max_length=4096)


def _url(plugin: SitePlugin, base: str, value: str, *, resource: bool = False) -> str:
    if not value.strip() or len(value) > 4096:
        raise ValueError("插件返回空链接或过长链接")
    url = urljoin(base, value)
    validate_public_url(url)
    if not host_matches(url, plugin.network_domains if resource else plugin.domains):
        raise ValueError("插件返回未声明的域名")
    return url


async def _invoke(plugin: SitePlugin, operation: str, base_url: str, *args):
    from ..db import is_site_plugin_enabled

    if not is_site_plugin_enabled(plugin.id):
        raise ValueError(f"站点插件“{plugin.name}”已停用，请在插件配置中启用")
    if plugin.load_error or plugin.runtime is None:
        raise ValueError(f"插件“{plugin.name}”加载失败，请在插件配置中更新或重新导入")
    handler = getattr(plugin.runtime, operation, None)
    if operation not in plugin.capabilities or handler is None:
        raise ValueError(f"插件“{plugin.name}”不支持此操作")
    try:
        async with (
            asyncio.timeout(CALL_TIMEOUT_SECONDS),
            create_public_http_client(
                timeout=15,
                follow_redirects=False,
                headers={"User-Agent": "QingJuan-Plugin/1", "Accept": "*/*"},
            ) as client,
        ):
            return await handler(*args, PluginContext(plugin, base_url, client))
    except TimeoutError:
        raise ValueError(f"插件“{plugin.name}”运行超时，请稍后重试") from None
    except (Exception, SystemExit):
        raise ValueError(f"插件“{plugin.name}”执行失败，请检查站点状态或更新插件") from None


def _invalid_output(plugin: SitePlugin) -> ValueError:
    return ValueError(f"插件“{plugin.name}”返回内容不符合规范，请更新插件")


async def preview_plugin(plugin: SitePlugin, url: str) -> PreviewResponse:
    raw = await _invoke(plugin, "preview", url, url)
    try:
        result = _Preview.model_validate(raw)
        if not result.title.strip() or any(not item.title.strip() for item in result.chapters):
            raise ValueError("标题为空")
        chapters = [
            ChapterPreview(
                title=item.title,
                url=_url(plugin, url, item.url),
                pageCount=item.pageCount,
                accessRestricted=item.accessRestricted,
            )
            for item in result.chapters
        ]
        if len({item.url for item in chapters}) != len(chapters):
            raise ValueError("章节链接重复")
        return PreviewResponse(
            title=result.title,
            author=result.author,
            synopsis=result.synopsis,
            cover=_url(plugin, url, result.cover, resource=True) if result.cover else None,
            chapters=chapters,
            chapterCount=len(chapters),
            bookKind=plugin.book_kinds[0],
        )
    except (ValueError, ValidationError):
        raise _invalid_output(plugin) from None


async def chapter_plugin(plugin: SitePlugin, url: str) -> tuple[str, list[str]]:
    raw = await _invoke(plugin, "chapter", url, url)
    try:
        result = _Content.model_validate(raw)
        if plugin.category == "manga":
            if not result.imageUrls:
                raise ValueError("漫画图片为空")
        elif not result.text.strip():
            raise ValueError("小说正文为空")
        return result.text.strip(), [_url(plugin, url, value, resource=True) for value in result.imageUrls]
    except (ValueError, ValidationError):
        raise _invalid_output(plugin) from None


async def search_plugin(plugin: SitePlugin, keyword: str, limit: int) -> list[BuiltinSiteSearchResult]:
    base = f"https://{plugin.domains[0]}/"
    raw = await _invoke(plugin, "search", base, keyword, limit)
    try:
        if not isinstance(raw, list) or len(raw) > 100:
            raise ValueError("搜索结果必须为至多 100 项的数组")
        results = []
        for value in raw[:limit]:
            item = _SearchItem.model_validate(value)
            if not item.title.strip():
                raise ValueError("标题为空")
            results.append(
                BuiltinSiteSearchResult(
                    **item.model_dump(exclude={"sourceUrl", "cover"}),
                    sourceUrl=_url(plugin, base, item.sourceUrl),
                    cover=_url(plugin, base, item.cover, resource=True) if item.cover else None,
                    bookKind=plugin.book_kinds[0],
                    providerName=plugin.name,
                )
            )
        return results
    except (ValueError, ValidationError):
        raise _invalid_output(plugin) from None
