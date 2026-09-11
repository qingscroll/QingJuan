from .base import SitePlugin

PLUGIN = SitePlugin(
    id="shaoniandream",
    name="少年梦阅读",
    description="解析少年梦作品、分卷目录与章节正文，支持账号密码登录与极验验证。",
    category="novel",
    domains=("shaoniandream.com",),
    book_kinds=("长小说",),
    tags=("中文", "原创小说", "章节解析"),
    preview_handler="shaoniandream",
    chapter_handler="shaoniandream",
    search_handler="shaoniandream",
    supports_account_login=True,
    supports_browser_login=True,
    version="1.1.0",
)
