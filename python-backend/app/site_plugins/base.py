from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from types import ModuleType
from typing import Literal
from urllib.parse import urlparse

SitePluginCategory = Literal["novel", "manga", "general"]
UrlMatcher = Callable[[str], bool]


def host_matches(url: str, domains: tuple[str, ...]) -> bool:
    parsed = urlparse(url)
    if parsed.scheme.lower() not in {"http", "https"}:
        return False
    host = (parsed.hostname or "").lower().rstrip(".")
    return any(host == domain or host.endswith(f".{domain}") for domain in domains)


def is_http_url(url: str) -> bool:
    parsed = urlparse(url)
    return parsed.scheme.lower() in {"http", "https"} and bool(parsed.hostname)


@dataclass(frozen=True, slots=True)
class SitePlugin:
    id: str
    name: str
    description: str
    category: SitePluginCategory
    domains: tuple[str, ...]
    book_kinds: tuple[str, ...]
    tags: tuple[str, ...]
    preview_handler: str
    chapter_handler: str | None
    search_handler: str | None = None
    supports_on_demand: bool = False
    supports_account_login: bool = False
    supports_cookie_login: bool = False
    supports_bookshelf_import: bool = False
    default_enabled: bool = True
    version: str = "1.0.0"
    matcher: UrlMatcher | None = field(default=None, repr=False, compare=False)
    origin: Literal["builtin", "installed"] = "builtin"
    author: str = ""
    api_version: int = 1
    language: str = "中文"
    network_domains: tuple[str, ...] = ()
    load_error: str | None = None
    runtime: ModuleType | None = field(default=None, repr=False, compare=False)

    @property
    def capabilities(self) -> tuple[str, ...]:
        values = ["preview"]
        if self.chapter_handler:
            values.append("chapter")
        if self.search_handler:
            values.append("search")
        if self.supports_on_demand:
            values.append("on_demand")
        if self.supports_account_login:
            values.append("account_login")
        if self.supports_cookie_login:
            values.append("cookie_login")
        if self.supports_bookshelf_import:
            values.append("bookshelf_import")
        return tuple(values)

    def matches(self, url: str) -> bool:
        if self.matcher is not None:
            return self.matcher(url)
        return host_matches(url, self.domains)
