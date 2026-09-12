"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

from ..config import settings
from ..httpclient import SiteHttp
from ..models import BookItem


@dataclass(frozen=True)
class Channel:
    key: str
    name: str
    kind: str = "rank"  # rank | recommend
    group: str = ""  # 男频 / 女频 / 综合 / 分类 / …
    description: str = ""
    params: Mapping[str, Any] = field(default_factory=dict)
    pageable: bool = True
    default_limit: int | None = None

    def info(self, site: str) -> dict[str, Any]:
        return {
            "site": site,
            "key": self.key,
            "name": self.name,
            "kind": self.kind,
            "group": self.group,
            "description": self.description,
            "pageable": self.pageable,
            "params": dict(self.params),
        }


@dataclass
class FetchResult:
    """一次通道抓取的返回。"""

    items: list[BookItem]
    has_more: bool = False
    page_size: int | None = None


class ProviderError(RuntimeError):
    """Provider 层错误（携带给用户的简短说明）。"""


class SiteAccessLimited(ProviderError):
    """站点明确限制当前出口网络访问。"""


class BaseProvider:
    """所有站点 Provider 的基类。

    子类只需：
      1. 覆盖类属性 `site / site_name / content / homepage / description`
      2. 声明 `channels`
      3. 实现 `async def fetch(self, channel, page, limit) -> FetchResult`
    """

    site: str = ""
    site_name: str = ""
    content: str = "novel"  # novel | comic
    homepage: str = ""
    description: str = ""
    requires_login: bool = False
    enabled: bool = True

    channels: Sequence[Channel] = ()

    # 需要 Cookie / Token 的站点可在子类里覆盖
    headers: Mapping[str, str] = {}
    cookies: Mapping[str, str] = {}
    ua: str | None = None
    encoding: str | None = None

    def __init__(self, http: SiteHttp | None = None):
        self.http = http

    # ------------------------------------------------------------------
    # 客户端参数（子类可覆盖以支持动态 Cookie / Token）
    # ------------------------------------------------------------------
    @classmethod
    def client_kwargs(cls) -> dict[str, Any]:
        from ..httpclient import DEFAULT_UA

        return {
            "headers": dict(cls.headers or {}),
            "cookies": dict(cls.cookies or {}),
            "ua": cls.ua or DEFAULT_UA,
            "encoding": cls.encoding,
        }

    # ------------------------------------------------------------------
    # 客户端
    # ------------------------------------------------------------------
    async def client(self) -> SiteHttp:
        """取本站点复用的 HTTP 客户端（由 registry 注入池化实例）。"""
        if self.http is None:
            raise ProviderError(f"{self.site}: HTTP 客户端未初始化")
        return self.http

    # ------------------------------------------------------------------
    # 子类实现
    # ------------------------------------------------------------------
    async def fetch(
        self,
        channel: Channel,
        page: int = 1,
        limit: int | None = None,
        options: Mapping[str, Any] | None = None,
    ) -> FetchResult:
        """抓取一个通道。

        `options` 为调用方传入的额外参数（与 channel.params 合并），
        用于「同一榜单按分类/时间切换」这类细化需求。
        """
        raise NotImplementedError

    # ------------------------------------------------------------------
    # 工具
    # ------------------------------------------------------------------
    def opts(self, channel: Channel, options: Mapping[str, Any] | None = None) -> dict[str, Any]:
        """合并通道默认参数与调用方覆盖参数。"""
        merged: dict[str, Any] = dict(channel.params or {})
        if options:
            merged.update({k: v for k, v in options.items() if v is not None})
        return merged

    def make(self, channel: Channel, **fields: Any) -> BookItem:
        """构造带站点/通道上下文的 BookItem。"""
        fields.setdefault("site", self.site)
        fields.setdefault("site_name", self.site_name)
        fields.setdefault("channel", channel.key)
        fields.setdefault("channel_name", channel.name)
        fields.setdefault("kind", channel.kind)
        return BookItem(**fields)

    def make_many(self, channel: Channel, rows: list[dict[str, Any]]) -> list[BookItem]:
        """批量构造，并按顺序补 rank（若条目里没有 rank 字段）。"""
        items: list[BookItem] = []
        auto_rank = 1
        for row in rows:
            if row.get("rank") in (None, 0, ""):
                row = {**row, "rank": auto_rank}
            auto_rank += 1
            items.append(self.make(channel, **row))
        return items

    def resolve_limit(self, channel: Channel, limit: int | None) -> int:
        """把请求的 limit 收敛到 [1, max_limit]；无参数时用通道默认值。"""
        base = limit or channel.default_limit or settings.default_limit
        return max(1, min(int(base), settings.max_limit))

    @classmethod
    def channel_by_key(cls, key: str) -> Channel | None:
        for ch in cls.channels:
            if ch.key == key:
                return ch
        return None


def channel(key: str, name: str, **kwargs: Any) -> Channel:
    """Channel 的简写构造器。"""
    return Channel(key=key, name=name, **kwargs)
