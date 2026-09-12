"""推荐抓取的进程内边界；公开书单统一匿名访问。"""

from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    timeout: float = 15.0
    channel_timeout: float = 45.0
    retries: int = 1
    cache_ttl: int = 600
    cache_max_items: int = 256
    default_limit: int = 20
    max_limit: int = 100
    global_concurrency: int = 6
    ehentai_cookies: str = ""
    shuqi_cookies: str = ""
    shaoniandream_cookies: str = ""
    bilibili_sessdata: str = ""


settings = Settings()
