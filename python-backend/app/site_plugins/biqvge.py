from .base import SitePlugin

PLUGIN = SitePlugin(
    id="biqvge",
    name="笔趣阁",
    description=(
        "聚合八零小说网、笔趣阁 5200 与笔趣看；自动适配八零搜索入口，"
        "镜像站使用公开目录索引并提供故障快速降级。"
    ),
    category="novel",
    domains=("txt80.net", "b520.cc", "blqukan.cc"),
    book_kinds=("长小说",),
    tags=("中文", "动态搜索", "镜像目录索引"),
    preview_handler="biqvge",
    chapter_handler="biqvge",
    search_handler="biqvge",
    supports_on_demand=True,
)
