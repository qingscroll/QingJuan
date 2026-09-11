from __future__ import annotations

from .alphapolis import PLUGIN as ALPHAPOLIS_PLUGIN
from .base import SitePlugin
from .bika import PLUGIN as BIKA_PLUGIN
from .biqvge import PLUGIN as BIQVGE_PLUGIN
from .ciweimao import PLUGIN as CIWEIMAO_PLUGIN
from .comic18 import PLUGIN as COMIC18_PLUGIN
from .comicores import PLUGIN as COMICORES_PLUGIN
from .copymanga import PLUGIN as COPYMANGA_PLUGIN
from .dmzj import PLUGIN as DMZJ_PLUGIN
from .ehentai import PLUGIN as EHENTAI_PLUGIN
from .fanqie import PLUGIN as FANQIE_PLUGIN
from .generic_web import PLUGIN as GENERIC_WEB_PLUGIN
from .hameln import PLUGIN as HAMELN_PLUGIN
from .kakuyomu import PLUGIN as KAKUYOMU_PLUGIN
from .linovelib import PLUGIN as LINOVELIB_PLUGIN
from .mangabz import PLUGIN as MANGABZ_PLUGIN
from .manhuagui import PLUGIN as MANHUAGUI_PLUGIN
from .novel18 import PLUGIN as NOVEL18_PLUGIN
from .novelup import PLUGIN as NOVELUP_PLUGIN
from .pixiv import PLUGIN as PIXIV_PLUGIN
from .pixiv_comic import PLUGIN as PIXIV_COMIC_PLUGIN
from .qidian import PLUGIN as QIDIAN_PLUGIN
from .quark import PLUGIN as QUARK_PLUGIN
from .sfacg import PLUGIN as SFACG_PLUGIN
from .shaoniandream import PLUGIN as SHAONIANDREAM_PLUGIN
from .syosetu import PLUGIN as SYOSETU_PLUGIN
from .webtoons import PLUGIN as WEBTOONS_PLUGIN
from .yanmaga import PLUGIN as YANMAGA_PLUGIN

# 顺序即匹配优先级。通用网页回退必须保持最后一项。
SITE_PLUGINS: tuple[SitePlugin, ...] = (
    FANQIE_PLUGIN,
    QIDIAN_PLUGIN,
    QUARK_PLUGIN,
    BIQVGE_PLUGIN,
    CIWEIMAO_PLUGIN,
    SFACG_PLUGIN,
    SHAONIANDREAM_PLUGIN,
    COMIC18_PLUGIN,
    BIKA_PLUGIN,
    EHENTAI_PLUGIN,
    PIXIV_COMIC_PLUGIN,
    PIXIV_PLUGIN,
    YANMAGA_PLUGIN,
    KAKUYOMU_PLUGIN,
    NOVEL18_PLUGIN,
    SYOSETU_PLUGIN,
    HAMELN_PLUGIN,
    NOVELUP_PLUGIN,
    ALPHAPOLIS_PLUGIN,
    LINOVELIB_PLUGIN,
    WEBTOONS_PLUGIN,
    MANGABZ_PLUGIN,
    MANHUAGUI_PLUGIN,
    COPYMANGA_PLUGIN,
    COMICORES_PLUGIN,
    DMZJ_PLUGIN,
    GENERIC_WEB_PLUGIN,
)

_SITE_PLUGINS_BY_ID = {plugin.id: plugin for plugin in SITE_PLUGINS}
_INSTALLED_BY_DATABASE: dict[str, tuple[SitePlugin, ...]] = {}


def installed_site_plugins() -> tuple[SitePlugin, ...]:
    from .. import db
    return _INSTALLED_BY_DATABASE.get(str(db.DB_PATH), ())


def replace_installed_site_plugins(plugins: tuple[SitePlugin, ...]) -> None:
    from .. import db
    _INSTALLED_BY_DATABASE[str(db.DB_PATH)] = tuple(sorted(plugins, key=lambda plugin: plugin.id))


def list_site_plugins() -> tuple[SitePlugin, ...]:
    return (*SITE_PLUGINS[:-1], *installed_site_plugins(), SITE_PLUGINS[-1])


def get_site_plugin(plugin_id: str) -> SitePlugin | None:
    return _SITE_PLUGINS_BY_ID.get(plugin_id) or next(
        (plugin for plugin in installed_site_plugins() if plugin.id == plugin_id), None
    )


def resolve_site_plugin(url: str) -> SitePlugin | None:
    return next((plugin for plugin in list_site_plugins() if plugin.matches(url)), None)


def site_plugin_matches(plugin_id: str, url: str) -> bool:
    plugin = get_site_plugin(plugin_id)
    return plugin.matches(url) if plugin is not None else False


def is_manga_site_url(url: str) -> bool:
    plugin = resolve_site_plugin(url)
    return plugin is not None and plugin.category == "manga"
