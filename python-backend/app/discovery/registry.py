"""固定站点目录；显式导入保证 Windows 打包包含全部解析器。"""

from ..db import is_site_plugin_enabled
from ..site_plugins.registry import resolve_site_plugin
from .models import ChannelInfo, SiteInfo
from .providers import (
    bilibili,
    biqvge,
    ciweimao,
    copycomic,
    ehentai,
    fanqie,
    jm18,
    kakuyomu,
    ores,
    qidian,
    quark,
    sfacg,
    shaonianmeng,
    yanmaga,
    yoyomanga,
)
from .providers.base import BaseProvider

PROVIDER_MODULES = (
    fanqie,
    qidian,
    ciweimao,
    biqvge,
    sfacg,
    shaonianmeng,
    quark,
    kakuyomu,
    bilibili,
    jm18,
    copycomic,
    ores,
    ehentai,
    yanmaga,
    yoyomanga,
)
PROVIDERS: dict[str, type[BaseProvider]] = {
    module.Provider.site: module.Provider for module in PROVIDER_MODULES
}


def is_site_enabled(site: str) -> bool:
    provider = PROVIDERS[site]
    plugin = resolve_site_plugin(provider.homepage)
    return provider.enabled and plugin is not None and is_site_plugin_enabled(plugin.id)


def list_sites() -> list[SiteInfo]:
    return [
        SiteInfo(
            site=provider.site,
            site_name=provider.site_name,
            content=provider.content,
            homepage=provider.homepage,
            description=f"{provider.site_name}的公开书单",
            requires_login=provider.requires_login,
            enabled=is_site_enabled(provider.site),
            channel_count=len(provider.channels),
            channels=[ChannelInfo(**channel.info(provider.site)) for channel in provider.channels],
        )
        for provider in PROVIDERS.values()
    ]


def clear_provider_caches(site: str | None = None) -> None:
    if site in (None, "shaonianmeng"):
        shaonianmeng.Provider._ranking_cache = None
    if site in (None, "quark"):
        quark.Provider._home_cache = None
    if site in (None, "yanmaga"):
        yanmaga._page_cache.clear()
    if site in (None, "yoyomanga"):
        yoyomanga._page_cache.clear()
