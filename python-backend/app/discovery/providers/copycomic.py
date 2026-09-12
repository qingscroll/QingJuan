"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

from typing import Any

from .base import BaseProvider, Channel, FetchResult, ProviderError, channel

API_HOSTS = [
    "https://api.2024manga.com",
    "https://mapi.hotmangasg.com",
    "https://mapi.hotmangasd.com",
    "https://mapi.hotmangasf.com",
]
SITE_URL = "https://www.mangacopy.com"
PLATFORM = 2

HEADERS = {
    "Accept": "application/json",
    "platform": str(PLATFORM),
    "Referer": f"{SITE_URL}/",
}

# 榜单 date_type 合法值 -> (通道 key, 中文名)，顺序即站点枚举
DATE_TYPES: list[tuple[str, str, str]] = [
    ("day", "rank_day", "日榜"),
    ("week", "rank_week", "周榜"),
    ("month", "rank_month", "月榜"),
]

# 分类 path_word -> 中文名（取自站点分类页锚文本）；仅登记实测有数据的题材
THEMES: list[tuple[str, str]] = [
    ("aiqing", "愛情"),
    ("qihuan", "奇幻"),
    ("maoxian", "冒險"),
    ("rexue", "熱血"),
    ("baihe", "百合"),
    ("xiaoyuan", "校園"),
    ("kehuan", "科幻"),
    ("hougong", "後宮"),
    ("zhentan", "偵探"),
    ("jingsong", "驚悚"),
    ("danmei", "耽美"),
    ("wuxia", "武俠"),
]

_CHANNELS: list[Channel] = (
    [
        channel(
            key,
            name,
            kind="rank",
            group="榜单",
            description=f"站点榜单接口 date_type={dt}（GET /api/v3/ranks?type=1&date_type={dt}），"
            f"条目带名次 sort 与涨幅 rise_num",
            params={"date_type": dt, "type": 1},
            pageable=True,
        )
        for dt, key, name in DATE_TYPES
    ]
    + [
        channel(
            "latest",
            "最新更新",
            kind="rank",
            group="列表",
            description="按最近更新倒序（GET /api/v3/comics?ordering=-datetime_updated，即默认排序）",
            pageable=True,
        ),
        channel(
            "popular",
            "人氣總榜",
            kind="rank",
            group="列表",
            description="按人气字段 popular 倒序（GET /api/v3/comics?ordering=-popular）",
            params={"ordering": "-popular"},
            pageable=True,
        ),
    ]
    + [
        channel(
            f"theme_{slug}",
            f"分類·{name}（人氣）",
            kind="rank",
            group="分类",
            description=f"分类过滤 theme={slug}（{name}）+ 人气倒序 ordering=-popular；"
            f"上游无该分类的官方榜单，此为分类内人气排序",
            params={"theme": slug, "ordering": "-popular"},
            pageable=True,
        )
        for slug, name in THEMES
    ]
)

_PAGE_DEFAULTS = 20
_RANK_PAGE_MAX = 200  # /api/v3/ranks 实测最多 199~200 条


class Provider(BaseProvider):
    site = "copycomic"
    site_name = "拷貝漫畫"
    content = "comic"
    homepage = SITE_URL
    description = (
        "拷貝漫畫（CopyManga）移动端 API：日榜 / 周榜 / 月榜（/api/v3/ranks）、最新更新、"
        "人气总榜，以及 12 个题材的分类内人气排序"
    )
    requires_login = False
    headers = dict(HEADERS)
    ua = (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )
    channels = tuple(_CHANNELS)

    # ------------------------------------------------------------------
    async def fetch(
        self,
        channel: Channel,
        page: int = 1,
        limit: int | None = None,
        options: dict | None = None,
    ) -> FetchResult:
        opts = self.opts(channel, options)
        # 当前接口拒绝大于 20 的分页大小；按同一页长计算 offset，避免漏项。
        limit = min(self.resolve_limit(channel, limit), _PAGE_DEFAULTS)
        page = max(1, int(page))
        offset = (page - 1) * limit

        if channel.key in ("rank_day", "rank_week", "rank_month"):
            return await self._ranks(channel, page, limit, offset, opts)
        if channel.key in ("latest", "popular") or channel.key.startswith("theme_"):
            return await self._comics(channel, page, limit, offset, opts)
        raise ProviderError(f"未实现的通道: {channel.key}")

    # ------------------------------------------------------------------
    async def _ranks(
        self, channel: Channel, page: int, limit: int, offset: int, opts: dict[str, Any]
    ) -> FetchResult:
        data = await self._api_get(
            "/api/v3/ranks",
            {
                "limit": limit,
                "offset": offset,
                "type": int(opts.get("type", 1)),
                "date_type": str(opts.get("date_type") or "day"),
                "platform": PLATFORM,
            },
            channel.name,
        )
        rows = data.get("list") or []
        if not rows:
            if offset >= _RANK_PAGE_MAX:
                return FetchResult(items=[], has_more=False)
            raise ProviderError(f"{channel.name}: /api/v3/ranks 返回空榜单")
        total = _int(data.get("total")) or 0
        items = [
            self._rank_book(channel, row, _int(row.get("sort")) or offset + index)
            for index, row in enumerate(rows[:limit], start=1)
        ]
        has_more = bool(total and offset + len(rows) < min(total, _RANK_PAGE_MAX))
        return FetchResult(items=items, has_more=has_more)

    async def _comics(
        self, channel: Channel, page: int, limit: int, offset: int, opts: dict[str, Any]
    ) -> FetchResult:
        params: dict[str, Any] = {
            "limit": limit,
            "offset": offset,
            "ordering": str(opts.get("ordering") or "-datetime_updated"),
            "platform": PLATFORM,
        }
        for key in ("theme", "free_type", "region", "status"):
            if opts.get(key) not in (None, ""):
                params[key] = opts[key]
        data = await self._api_get("/api/v3/comics", params, channel.name)
        rows = data.get("list") or []
        if not rows:
            if offset:
                return FetchResult(items=[], has_more=False)
            raise ProviderError(f"{channel.name}: /api/v3/comics 返回空列表")
        total = _int(data.get("total")) or 0
        items = [
            self._comic_book(channel, row, offset + index) for index, row in enumerate(rows[:limit], start=1)
        ]
        has_more = bool(total and offset + len(rows) < total)
        return FetchResult(items=items, has_more=has_more)

    # ------------------------------------------------------------------
    async def _api_get(self, path: str, params: dict[str, Any], what: str) -> dict[str, Any]:
        """按 nodes 轮换请求上游；全部失败抛 ProviderError。"""
        http = await self.client()
        errors: list[str] = []
        for host in API_HOSTS:
            try:
                payload = await http.json(f"{host}{path}", params=params)
            except Exception as exc:  # noqa: BLE001 - 网络 / 非 JSON
                errors.append(f"{host}: {type(exc).__name__}: {exc}")
                continue
            if not isinstance(payload, dict):
                errors.append(f"{host}: 返回体非对象")
                continue
            code = payload.get("code")
            if code != 200:
                raise ProviderError(
                    f"{what}: 上游业务错误 code={code} "
                    f"message={payload.get('message') or payload.get('results')}"
                )
            results = payload.get("results")
            if not isinstance(results, dict):
                errors.append(f"{host}: results 非对象")
                continue
            return results
        raise ProviderError(f"{what}: 所有 API 节点均失败（{'; '.join(errors[:3])}）")

    # ------------------------------------------------------------------
    def _rank_book(self, channel: Channel, row: Any, rank: int) -> Any:
        row = row if isinstance(row, dict) else {}
        comic = row.get("comic") if isinstance(row.get("comic"), dict) else {}
        return self._book(
            channel,
            comic,
            rank=rank,
            score=str(row.get("popular") or comic.get("popular") or ""),
            extra={
                "sort": row.get("sort"),
                "sort_last": row.get("sort_last"),
                "rise_sort": row.get("rise_sort"),
                "rise_num": row.get("rise_num"),
                "date_type": row.get("date_type"),
                "popular": row.get("popular"),
                "comic": comic,
            },
        )

    def _comic_book(self, channel: Channel, row: Any, rank: int) -> Any:
        row = row if isinstance(row, dict) else {}
        return self._book(
            channel,
            row,
            rank=rank,
            score=str(row.get("popular") or ""),
            extra={
                "popular": row.get("popular"),
                "datetime_updated": row.get("datetime_updated"),
                "females": row.get("females") or [],
                "males": row.get("males") or [],
                "raw": row,
            },
        )

    def _book(self, channel: Channel, raw: dict[str, Any], **overrides: Any) -> Any:
        slug = str(raw.get("path_word") or "").strip()
        authors = raw.get("author")
        if isinstance(authors, list):
            author = "、".join(
                str(a.get("name") or "").strip() for a in authors if isinstance(a, dict)
            ).strip("、")
        else:
            author = str(authors or "")
        themes = raw.get("theme") or []
        theme_names = [str(t.get("name") or "").strip() for t in themes if isinstance(t, dict)]

        raw_extra: dict[str, Any] = {
            "path_word": slug,
            "theme": theme_names,
            "author": authors if isinstance(authors, list) else [],
            "datetime_updated": raw.get("datetime_updated"),
        }
        fields: dict[str, Any] = {
            "book_id": slug,
            "title": str(raw.get("name") or ""),
            "author": author,
            "cover": str(raw.get("cover") or ""),
            "intro": "",
            "category": "、".join(n for n in theme_names if n),
            "status": "",
            "word_count": "",
            "score": "",
            "url": f"{SITE_URL}/comic/{slug}" if slug else "",
            "extra": raw_extra,
        }
        fields.update(overrides)
        extra = dict(raw_extra)
        extra.update(overrides.pop("extra", None) or {})
        fields["extra"] = extra
        return self.make(channel, **fields)


def _int(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None
