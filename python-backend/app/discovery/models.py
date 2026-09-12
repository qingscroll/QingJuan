"""统一响应模型。"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

Kind = Literal["rank", "recommend"]


class ChannelInfo(BaseModel):
    """一个榜单 / 推荐位通道的元信息。"""

    site: str = Field(description="站点标识")
    key: str = Field(description="通道标识，如 rank_yuepiao")
    name: str = Field(description="通道中文名，如 月票榜")
    kind: Kind = Field(description="rank=排行榜, recommend=推荐位")
    group: str = Field(default="", description="分组，如 男频/女频/综合/分类")
    description: str = ""
    pageable: bool = True
    params: dict[str, Any] = Field(default_factory=dict, description="默认参数")


class SiteInfo(BaseModel):
    """一个站点的元信息与可用通道。"""

    site: str
    site_name: str
    content: Literal["novel", "comic"] = "novel"
    homepage: str = ""
    description: str = ""
    requires_login: bool = False
    enabled: bool = True
    channel_count: int = 0
    channels: list[ChannelInfo] = Field(default_factory=list)


class BookItem(BaseModel):
    """归一化后的书籍 / 漫画条目。"""

    site: str
    site_name: str = ""
    channel: str = ""
    channel_name: str = ""
    kind: Kind = "rank"
    rank: int | None = Field(default=None, description="榜单名次；推荐位可能为空")
    book_id: str = ""
    title: str = ""
    author: str = ""
    cover: str = ""
    intro: str = ""
    category: str = ""
    status: str = ""
    word_count: str = ""
    score: str = Field(default="", description="票数 / 热度 / 评分等展示值")
    url: str = ""
    extra: dict[str, Any] = Field(default_factory=dict, description="站点原始字段")


class ChannelResult(BaseModel):
    """单个通道的抓取结果（含错误信息，便于部分降级）。"""

    site: str
    site_name: str = ""
    channel: str
    channel_name: str = ""
    kind: Kind = "rank"
    group: str = ""
    page: int = 1
    limit: int = 20
    count: int = 0
    has_more: bool = False
    cached: bool = False
    elapsed_ms: int = 0
    error: str | None = None
    items: list[BookItem] = Field(default_factory=list)


class SitesResponse(BaseModel):
    sites: list[SiteInfo] = Field(default_factory=list)
