"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

import hashlib
import time
import uuid
from typing import Any

from ..httpclient import UpstreamError
from ..utils import abs_url, clean, pick, trim
from .base import BaseProvider, Channel, FetchResult, ProviderError, channel

API = "https://api.sfacg.com"
WEB = "https://book.sfacg.com"

# 逆向常量（与 SF_boluobao_book/app/config.py 一致）
BASIC_AUTH = "Basic YW5kcm9pZHVzZXI6MWEjJDUxLXl0Njk7KkFjdkBxeHE="
APP_KEY = "FMLxgOdsfxmN!Dt4"
APP_VERSION = "4.8.42(android;25)"
CHANNEL_NAME = "HomePage"

# 设备令牌：进程级固定一个即可（客户端只在启动时生成一次）
DEVICE_TOKEN = str(uuid.uuid4()).upper()

# /noveltypes 实测返回的权威分类表（初始化通道时同步写入，见 _CHANNELS 注释）
TYPE_NAMES: dict[int, str] = {
    21: "魔幻",
    22: "玄幻",
    23: "古风",
    24: "科幻",
    25: "校园",
    26: "都市",
    27: "游戏",
    29: "悬疑",
}

# 分类推荐榜每页固定 20 条且不支持翻页，故 default_limit=20
_CATEGORY_TIDS = (21, 22, 23, 24, 25, 26, 27, 29)

_CHANNELS: list[Channel] = [
    channel(
        f"rank_cat_{tid}",
        f"{TYPE_NAMES[tid]}推荐榜",
        kind="rank",
        group="分类",
        description=f"分类「{TYPE_NAMES[tid]}」推荐榜（/novels?tid={tid}&filter=recom），上游不支持翻页",
        params={"tid": tid, "filter": "recom"},
        pageable=False,
        default_limit=20,
    )
    for tid in _CATEGORY_TIDS
] + [
    channel(
        "rank_workentities",
        "最新更新榜",
        kind="rank",
        group="综合",
        description="全站作品实体列表（/workentities），按最近更新时间倒序",
        params={"size": 12},
        pageable=True,
    ),
    channel(
        "recommend_hot",
        "热门推荐位",
        kind="recommend",
        group="首页推荐位",
        description="热门推荐位（/novels/specialpushs?pushNames=hotpush）",
        params={"push_name": "hotpush"},
        pageable=False,
        default_limit=8,
    ),
    channel(
        "recommend_new",
        "新书推荐位",
        kind="recommend",
        group="首页推荐位",
        description="新书推荐位（/novels/specialpushs?pushNames=newpush）",
        params={"push_name": "newpush"},
        pageable=False,
        default_limit=8,
    ),
    channel(
        "recommend_bigbrain",
        "脑洞推荐位",
        kind="recommend",
        group="首页推荐位",
        description="脑洞推荐位（/novels/specialpushs?pushNames=bigBrainPush）",
        params={"push_name": "bigBrainPush"},
        pageable=False,
        default_limit=8,
    ),
    channel(
        "recommend_chatnovel_daily",
        "对话小说热门推荐位",
        kind="recommend",
        group="对话小说",
        description="首页对话小说（chatnovel）每日热门推送位（/specialpush chatNovelHotDaily）",
        pageable=False,
        default_limit=12,
    ),
]

_ENVELOPE_CODE = (200, None)


def _simple_sign(nonce: str, timestamp_ms: int, device_token: str, app_key: str) -> str:
    """官方旧式签名：直接拼接后 MD5（大小写敏感，取大写十六进制）。"""
    source = f"{nonce}{timestamp_ms}{device_token.upper()}{app_key}"
    return hashlib.md5(source.encode("utf-8")).hexdigest().upper()


def build_sfsecurity(device_token: str, app_key: str = APP_KEY) -> str:
    """生成一次请求用的 `SFSecurity` 头（nonce 一次性，失败需重新生成）。"""
    nonce = str(uuid.uuid4()).upper()
    timestamp_ms = int(time.time() * 1000)
    device = device_token.upper()
    sign = _simple_sign(nonce, timestamp_ms, device, app_key)
    return f"nonce={nonce}&timestamp={timestamp_ms}&devicetoken={device}&sign={sign}"


def _headers() -> dict[str, str]:
    """每个请求都要重新构造（含一次性 SFSecurity）。"""
    return {
        "Accept": "application/vnd.sfacg.api+json;version=1",
        "Accept-Charset": "UTF-8",
        "Authorization": BASIC_AUTH,
        "User-Agent": f"boluobao/{APP_VERSION}/{CHANNEL_NAME}/{DEVICE_TOKEN.lower()}",
        "SFSecurity": build_sfsecurity(DEVICE_TOKEN),
    }


def _push_rows(data: Any, push_name: str) -> list[Any]:
    """从推送字典里取列表。

    注意：请求参数与响应键的大小写并不一致（`pushNames=hotpush` 的响应键是
    `hotPush`、`newpush` 对应 `newPush`），故做一次大小写无关的兜底匹配。
    """
    if not isinstance(data, dict):
        return []
    rows = data.get(push_name)
    if rows is None:
        wanted = push_name.lower()
        for key, value in data.items():
            if str(key).lower() == wanted:
                rows = value
                break
    return rows if isinstance(rows, list) else []


class Provider(BaseProvider):
    site = "sfacg"
    site_name = "SF轻小说"
    content = "novel"
    homepage = WEB
    description = "SF轻小说（菠萝包）客户端 API：分类推荐榜 / 最新更新榜 / 热门·新书·脑洞推荐位"
    requires_login = False
    channels = tuple(_CHANNELS)

    @classmethod
    def client_kwargs(cls) -> dict[str, Any]:
        return {
            "headers": {
                "Accept": "application/vnd.sfacg.api+json;version=1",
                "Accept-Charset": "UTF-8",
                "Authorization": BASIC_AUTH,
            },
            "cookies": {},
            "ua": f"boluobao/{APP_VERSION}/{CHANNEL_NAME}/{DEVICE_TOKEN.lower()}",
            "encoding": "utf-8",
        }

    # ------------------------------------------------------------------
    async def fetch(
        self,
        channel: Channel,
        page: int = 1,
        limit: int | None = None,
        options: dict | None = None,
    ) -> FetchResult:
        opts = self.opts(channel, options)
        limit = self.resolve_limit(channel, limit)
        if channel.key.startswith("rank_cat_"):
            return await self._rank_category(channel, limit, opts)
        if channel.key == "rank_workentities":
            return await self._workentities(channel, page, limit)
        if channel.key in ("recommend_hot", "recommend_new", "recommend_bigbrain"):
            return await self._special_pushs(channel, limit, opts)
        if channel.key == "recommend_chatnovel_daily":
            return await self._chatnovel_daily(channel, limit)
        raise ProviderError(f"未实现的通道: {channel.key}")

    # ------------------------------------------------------------------
    async def _rank_category(self, channel: Channel, limit: int, opts: dict[str, Any]) -> FetchResult:
        """分类推荐榜：每页固定 20 条，上游忽略 page，故不翻页。"""
        tid = str(opts.get("tid") or "")
        rows = await self._data(
            "/novels",
            {
                "page": 0,
                "size": limit,
                "tid": tid,
                "categoryId": 0,
                "filter": opts.get("filter") or "recom",
                "expand": "discount,discountExpireDate,typeName,intro",
            },
            channel.name,
        )
        rows = rows if isinstance(rows, list) else []
        items = [
            self._book(channel, row, rank=idx)
            for idx, row in enumerate(rows[:limit], start=1)
            if isinstance(row, dict)
        ]
        return FetchResult(items=items, has_more=False)

    async def _workentities(self, channel: Channel, page: int, limit: int) -> FetchResult:
        """作品实体列表：`page` 从 0 开始，实测可翻页。

        上游 `size` 由本方法控制，故让其等于 `limit`，页码窗口才能严丝合缝地
        铺满 `[(page-1)*limit, page*limit)`，不会漏条。
        """
        size = max(1, min(limit, 50))
        offset = max(0, page - 1)
        rows = await self._data(
            "/workentities",
            {"page": offset, "size": size, "expand": "authorName,typeName,sysTags,intro"},
            channel.name,
        )
        rows = rows if isinstance(rows, list) else []
        base = offset * size
        items = []
        for idx, row in enumerate(rows, start=1):
            if not isinstance(row, dict):
                continue
            # 元素形如 {"novel": {...}, "album": ...}，只取小说部分
            novel = row.get("novel") if isinstance(row.get("novel"), dict) else row
            item = self._book(channel, novel, rank=base + idx)
            if item.book_id or item.title:
                items.append(item)
            if len(items) >= limit:
                break
        return FetchResult(items=items, has_more=len(rows) >= size)

    async def _special_pushs(self, channel: Channel, limit: int, opts: dict[str, Any]) -> FetchResult:
        """推荐位：`/novels/specialpushs` 的数据是以 push 名为键的字典。"""
        push_name = str(opts.get("push_name") or "")
        data = await self._data(
            "/novels/specialpushs",
            {
                "pushNames": push_name,
                "page": 0,
                "size": max(limit, 8),
                "expand": "sysTags,discount,discountExpireDate,homeFlag",
            },
            channel.name,
        )
        rows = _push_rows(data, push_name)
        items = [
            self._book(channel, row, rank=idx)
            for idx, row in enumerate(rows[:limit], start=1)
            if isinstance(row, dict)
        ]
        return FetchResult(items=items, has_more=False)

    async def _chatnovel_daily(self, channel: Channel, limit: int) -> FetchResult:
        """首页对话小说推送位：元素自带完整 `entity`（novel 对象）。"""
        data = await self._data(
            "/specialpush",
            {"pushNames": "chatNovelHotDaily"},
            channel.name,
        )
        rows = (data or {}).get("chatNovelHotDaily") if isinstance(data, dict) else None
        rows = rows if isinstance(rows, list) else []
        items = []
        for idx, row in enumerate(rows, start=1):
            if not isinstance(row, dict):
                continue
            novel = row.get("entity")
            if not isinstance(novel, dict) or not novel.get("novelId"):
                # 没有完整 entity 的推送项不构成书籍条目，跳过而不是编造
                continue
            items.append(self._book(channel, novel, rank=idx, intro=row.get("desc") or ""))
            if len(items) >= limit:
                break
        return FetchResult(items=items, has_more=False)

    # ------------------------------------------------------------------
    async def _data(self, path: str, params: dict[str, Any], what: str) -> Any:
        """请求上游并校验 `status.httpCode`，返回 `data`。"""
        http = await self.client()
        try:
            payload = await http.json(f"{API}{path}", params=params, headers=_headers())
        except UpstreamError as exc:
            raise ProviderError(f"{what} 请求失败: {exc}") from exc
        if not isinstance(payload, dict):
            raise ProviderError(f"{what}: 返回体非对象")
        status = payload.get("status") or {}
        code = status.get("httpCode")
        if code not in _ENVELOPE_CODE:
            raise ProviderError(f"{what} 失败: httpCode={code} msg={status.get('msg') or ''}")
        return payload.get("data")

    def _book(self, channel: Channel, raw: dict[str, Any], **overrides: Any) -> Any:
        # 推荐位元素会把小说包在 `novel` 键里
        if isinstance(raw.get("novel"), dict):
            raw = raw["novel"]
        expand = raw.get("expand") if isinstance(raw.get("expand"), dict) else {}
        book_id = str(pick(raw, "novelId", "bookId", "id", default=""))
        type_id = raw.get("typeId")
        try:
            category = TYPE_NAMES.get(int(type_id), "") if type_id is not None else ""
        except (TypeError, ValueError):
            category = ""
        fields: dict[str, Any] = {
            "book_id": book_id,
            "title": clean(raw.get("novelName") or raw.get("title") or ""),
            "author": clean(raw.get("authorName") or ""),
            "cover": abs_url(WEB, clean(raw.get("novelCover") or "")),
            "intro": trim(pick(expand, "intro", "description", default=raw.get("intro") or ""), 400),
            "category": clean(expand.get("typeName") or category),
            "status": "完结" if raw.get("isFinish") else "连载中",
            "word_count": clean(raw.get("charCount") or ""),
            "score": clean(pick(raw, "point", default="")),
            "url": f"{WEB}/Novel/{book_id}/" if book_id else "",
        }
        fields.update(overrides)
        return self.make(channel, extra=raw, **fields)


__all__ = ["Provider", "build_sfsecurity", "TYPE_NAMES"]
