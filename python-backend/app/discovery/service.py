"""单频道抓取编排：有界并发、缓存、错误隔离和公开 DTO。"""

import asyncio
import logging
import time

from ..scraper_network_security import ScraperNetworkSecurityError, validate_public_url
from .cache import cache
from .config import settings
from .httpclient import SiteHttp, UpstreamError
from .models import ChannelResult
from .providers.base import BaseProvider, Channel, SiteAccessLimited
from .registry import PROVIDERS, clear_provider_caches, is_site_enabled

logger = logging.getLogger(__name__)
_semaphore = asyncio.Semaphore(settings.global_concurrency)


class UnknownDiscoveryChannel(LookupError):
    pass


def resolve_channel(site: str, key: str) -> tuple[type[BaseProvider], Channel]:
    provider = PROVIDERS.get(site)
    if provider is None:
        raise UnknownDiscoveryChannel("推荐站点不存在")
    channel = provider.channel_by_key(key)
    if channel is None:
        raise UnknownDiscoveryChannel("推荐栏目不存在")
    return provider, channel


def _safe_url(value: str) -> str:
    if not value:
        return ""
    if value.startswith("//"):
        value = "https:" + value
    try:
        validate_public_url(value)
    except ScraperNetworkSecurityError:
        return ""
    return value


async def fetch_channel(
    site: str, key: str, *, page: int = 1, limit: int = 20, refresh: bool = False
) -> ChannelResult:
    started = time.monotonic()
    provider_class, channel = resolve_channel(site, key)
    if not channel.pageable:
        page = 1
    result_fields = dict(
        site=site,
        site_name=provider_class.site_name,
        channel=key,
        channel_name=channel.name,
        kind=channel.kind,
        group=channel.group,
        page=page,
        limit=limit,
    )
    if not is_site_enabled(site):
        return ChannelResult(**result_fields, error="该站点插件已停用，请在插件管理中启用")

    async def load() -> ChannelResult:
        async with _semaphore:
            if refresh:
                # Providers may share cached homepage sections across channels.
                clear_provider_caches(site)
                cache.invalidate_prefix(f"{site}:")
                cache.invalidate_prefix(f"channel:{site}:")
            http = SiteHttp(
                provider_class.homepage,
                **provider_class.client_kwargs(),
                allowed=lambda: is_site_enabled(site),
            )
            try:
                fetched = await provider_class(http=http).fetch(channel, page=page, limit=limit)
            finally:
                await http.aclose()
        items = fetched.items[:limit]
        for index, item in enumerate(items, start=1):
            item.extra = {}
            item.url = _safe_url(item.url)
            item.cover = _safe_url(item.cover)
            if channel.kind == "rank" and not item.rank:
                item.rank = (page - 1) * (fetched.page_size or limit) + index
        return ChannelResult(
            **result_fields,
            count=len(items),
            has_more=channel.pageable and fetched.has_more,
            items=items,
        )

    try:
        async with asyncio.timeout(settings.channel_timeout):
            result, hit = await cache.get_or_load(
                f"channel:{site}:{key}:{page}:{limit}",
                load,
                refresh=refresh,
            )
        result.cached = hit
    except TimeoutError:
        result = ChannelResult(**result_fields, error="该栏目加载超时，请稍后重试或选择其他栏目")
    except Exception as error:
        # Never reflect provider exceptions, upstream bodies, cookies or local paths.
        logger.warning("推荐栏目加载失败 site=%s channel=%s type=%s", site, key, type(error).__name__)
        if isinstance(error, SiteAccessLimited):
            message = "该站点暂时限制当前网络访问，请稍后重试或选择其他站点"
        elif isinstance(error, (UpstreamError, ScraperNetworkSecurityError)):
            message = "站点暂时无法连接，请稍后重试"
        else:
            message = "该栏目暂时不可用，站点可能限制访问或已调整页面，请稍后重试"
        result = ChannelResult(**result_fields, error=message)
    result.elapsed_ms = round((time.monotonic() - started) * 1000)
    return result


async def shutdown() -> None:
    await cache.aclose()
    clear_provider_caches()
