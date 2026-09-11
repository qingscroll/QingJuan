from .base import SitePlugin

PLUGIN = SitePlugin(
    id="18comic",
    name="18Comic",
    description="支持输入禁漫本子号或专辑链接，获取章节、漫画图片并自动还原图片，也提供内置作品搜索。",
    category="manga",
    domains=("18comic.vip",),
    book_kinds=("漫画",),
    tags=("中文", "漫画", "R18"),
    preview_handler="18comic",
    chapter_handler="18comic",
    search_handler="18comic",
)
