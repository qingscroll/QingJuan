"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

import time
from typing import Any

from ..utils import extract_json_after
from .base import BaseProvider, Channel, FetchResult, ProviderError, channel

BASE = "https://fanqienovel.com"
APP_ID = 2503

# /rank 页面 SSR 中的 rankCategoryTypeList（性别 -> 分类）
MALE_CATEGORIES = [
    ("1141", "西方奇幻"),
    ("1140", "东方仙侠"),
    ("8", "科幻末世"),
    ("261", "都市日常"),
    ("124", "都市修真"),
    ("1014", "都市高武"),
    ("273", "历史古代"),
    ("27", "战神赘婿"),
    ("263", "都市种田"),
    ("258", "传统玄幻"),
    ("272", "历史脑洞"),
    ("539", "悬疑脑洞"),
    ("262", "都市脑洞"),
    ("257", "玄幻脑洞"),
    ("751", "悬疑灵异"),
    ("504", "抗战谍战"),
    ("746", "游戏体育"),
    ("718", "动漫衍生"),
    ("1016", "男频衍生"),
]
FEMALE_CATEGORIES = [
    ("1139", "古风世情"),
    ("248", "玄幻言情"),
    ("23", "种田"),
    ("79", "年代"),
    ("267", "现言脑洞"),
    ("246", "宫斗宅斗"),
    ("253", "古言脑洞"),
    ("24", "快穿"),
    ("749", "青春甜宠"),
    ("745", "星光璀璨"),
    ("747", "女频悬疑"),
    ("750", "职场婚恋"),
    ("748", "豪门总裁"),
    ("1017", "民国言情"),
]

_CHANNELS: list[Channel] = [
    channel(
        "rank_list",
        "综合榜",
        kind="rank",
        group="综合",
        description="站点综合精选书单，固定单页",
        pageable=False,
    ),
    channel(
        "rank_recommend",
        "推荐榜",
        kind="rank",
        group="综合",
        description="官方推荐/热门书单，固定单页",
        pageable=False,
    ),
    channel(
        "rank_recent_update",
        "最近更新榜",
        kind="rank",
        group="综合",
        description="最近更新排行（/api/rank/recent/update/list）",
        pageable=True,
    ),
    channel(
        "rank_hot_male",
        "男频分类热榜",
        kind="rank",
        group="男频",
        description="男频分类热榜，默认西方奇幻；可用 options 传 category_id 切换分类",
        params={"category_id": MALE_CATEGORIES[0][0], "gender": 0},
        pageable=True,
    ),
    channel(
        "rank_hot_female",
        "女频分类热榜",
        kind="rank",
        group="女频",
        description="女频分类热榜，默认古风世情；可用 options 传 category_id 切换分类",
        params={"category_id": FEMALE_CATEGORIES[0][0], "gender": 1},
        pageable=True,
    ),
    channel(
        "recommend_editor",
        "编辑推荐",
        kind="recommend",
        group="首页推荐位",
        description="首页 SSR 的 editorList（编辑精选书单）",
        pageable=False,
    ),
    channel(
        "recommend_week",
        "本周推荐",
        kind="recommend",
        group="首页推荐位",
        description="首页 SSR 的 weekList（本周热门书单）",
        pageable=False,
    ),
    channel(
        "recommend_boy",
        "男生推荐",
        kind="recommend",
        group="首页推荐位",
        description="首页 SSR 的 boyList（男频推荐位）",
        pageable=False,
    ),
    channel(
        "recommend_girl",
        "女生推荐",
        kind="recommend",
        group="首页推荐位",
        description="首页 SSR 的 girlList（女频推荐位）",
        pageable=False,
    ),
]

# 首页 SSR 中的推荐位书单键 -> 通道
HOME_RAILS = {
    "recommend_editor": "editorList",
    "recommend_week": "weekList",
    "recommend_boy": "boyList",
    "recommend_girl": "girlList",
}
HOME_RAILS_CACHE_KEY = "fanqie:home_rails"

CATEGORY_NAMES = dict(MALE_CATEGORIES + FEMALE_CATEGORIES)


class Provider(BaseProvider):
    site = "fanqie"
    site_name = "番茄小说"
    content = "novel"
    homepage = BASE
    description = "番茄小说公开 Web 接口：综合榜 / 推荐榜 / 最近更新榜 / 男女频分类热榜 / 首页编辑、本周、男频、女频推荐位"
    requires_login = False
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
        limit = self.resolve_limit(channel, limit)
        if channel.key == "rank_list":
            return await self._rank_list(channel, page, limit)
        if channel.key == "rank_recommend":
            return await self._rank_recommend(channel, page, limit)
        if channel.key == "rank_recent_update":
            return await self._rank_recent(channel, page, limit)
        if channel.key in ("rank_hot_male", "rank_hot_female"):
            return await self._rank_category(channel, page, limit, opts)
        if channel.key in HOME_RAILS:
            return await self._home_rail(channel, limit)
        raise ProviderError(f"未实现的通道: {channel.key}")

    # ------------------------------------------------------------------
    async def _rank_list(self, channel: Channel, page: int, limit: int) -> FetchResult:
        http = await self.client()
        data = await http.json(
            f"{BASE}/api/rank/list",
            params={"limit": limit, "offset": 0},
        )
        self._raise_if_error(data, "综合榜")
        rows = ((data.get("data") or {}).get("list")) or []
        return FetchResult(items=[self._book(channel, r) for r in rows[:limit]], has_more=False)

    async def _rank_recommend(self, channel: Channel, page: int, limit: int) -> FetchResult:
        http = await self.client()
        data = await http.json(
            f"{BASE}/api/rank/recommend/list",
            params={"limit": limit, "offset": 0},
        )
        self._raise_if_error(data, "推荐榜")
        rows = ((data.get("data") or {}).get("list")) or []
        items = [self._book(channel, r) for r in rows[:limit]]
        return FetchResult(items=items, has_more=False)

    async def _rank_recent(self, channel: Channel, page: int, limit: int) -> FetchResult:
        http = await self.client()
        offset = (page - 1) * limit
        data = await http.json(
            f"{BASE}/api/rank/recent/update/list",
            params={"limit": limit, "offset": offset},
        )
        self._raise_if_error(data, "最近更新榜")
        rows = ((data.get("data") or {}).get("data")) or []
        items = []
        for idx, r in enumerate(rows[:limit], start=1):
            ts = r.get("updateTime")
            try:
                stamp = time.strftime("%Y-%m-%d %H:%M", time.localtime(int(ts)))
            except (TypeError, ValueError, OSError):
                stamp = ""
            items.append(
                self._book(
                    channel,
                    r,
                    rank=offset + idx,
                    title=r.get("bookName") or r.get("title") or "",
                    latest_chapter=r.get("title") or "",
                    update_time=stamp,
                )
            )
        return FetchResult(items=items, has_more=len(rows) >= limit)

    async def _rank_category(
        self, channel: Channel, page: int, limit: int, opts: dict[str, Any]
    ) -> FetchResult:
        http = await self.client()
        data = await http.json(
            f"{BASE}/api/rank/category/list",
            params={
                "app_id": APP_ID,
                "rank_list_type": 3,  # 3 = 热榜
                "category_id": opts.get("category_id", "0"),
                "gender": opts.get("gender", 0),
                "rank_version": "",
                "rank_mold": "",
                "limit": limit,
                "offset": (page - 1) * limit,
            },
        )
        self._raise_if_error(data, "分类热榜")
        body = data.get("data") or {}
        rows = body.get("book_list") or body.get("rank_list") or body.get("list") or []
        items = []
        cat_name = CATEGORY_NAMES.get(str(opts.get("category_id", "")), "")
        for r in rows[:limit]:
            rank = r.get("currentPos")
            items.append(
                self._book(
                    channel,
                    r,
                    rank=int(rank) if isinstance(rank, int) else None,
                    category=r.get("category") or r.get("categoryV2") or cat_name,
                )
            )
        return FetchResult(items=items, has_more=len(rows) >= limit)

    async def _list_endpoint(self, path: str, channel: Channel, limit: int) -> FetchResult:
        http = await self.client()
        data = await http.json(f"{BASE}{path}")
        self._raise_if_error(data, channel.name)
        rows = ((data.get("data") or {}).get("list")) or []
        items = []
        for r in rows[:limit]:
            bid = str(r.get("bookId") or r.get("book_id") or r.get("id") or "")
            items.append(
                self._book(
                    channel,
                    r,
                    book_id=bid,
                    title=r.get("bookName") or r.get("title") or r.get("name") or "",
                    cover=r.get("thumbUri") or r.get("thumbUrl") or r.get("imageUrl") or "",
                    intro=r.get("abstract") or r.get("description") or "",
                    url=f"{BASE}/page/{bid}" if bid else "",
                )
            )
        return FetchResult(items=items, has_more=False)

    # ------------------------------------------------------------------
    def _book(self, channel: Channel, raw: dict[str, Any], **overrides: Any) -> Any:
        bid = str(raw.get("bookId") or "")
        cat_id = str(raw.get("cureent_category_id") or "")
        fields: dict[str, Any] = {
            "book_id": bid,
            "title": raw.get("bookName") or "",
            "author": raw.get("author") or "",
            "cover": raw.get("thumbUri") or "",
            "intro": raw.get("abstract") or "",
            "category": raw.get("category") or raw.get("categoryV2") or CATEGORY_NAMES.get(cat_id, ""),
            "status": str(raw.get("creationStatus") or ""),
            "word_count": str(raw.get("wordNumber") or ""),
            "score": str(raw.get("readCount") or raw.get("read_count") or ""),
            "url": f"{BASE}/page/{bid}" if bid else "",
        }
        fields.update(overrides)
        return self.make(channel, extra=raw, **fields)

    async def _home_rail(self, channel: Channel, limit: int) -> FetchResult:
        """从首页 SSR（window.__INITIAL_STATE__.home）取推荐位书单。

        首页一次请求即可拿到 editorList / weekList / boyList / girlList，
        因此整体缓存这一个响应，避免每个推荐位都重新抓首页。
        """
        rails = await self._home_rails()
        rows = rails.get(HOME_RAILS[channel.key]) or []
        items = []
        for idx, r in enumerate(rows[:limit], start=1):
            bid = str(r.get("bookId") or "")
            items.append(
                self._book(
                    channel,
                    r,
                    rank=idx,
                    book_id=bid,
                    title=r.get("bookName") or "",
                    url=f"{BASE}/page/{bid}" if bid else "",
                )
            )
        return FetchResult(items=items, has_more=False)

    async def _home_rails(self) -> dict[str, Any]:
        from ..cache import cache

        async def load() -> dict[str, Any]:
            http = await self.client()
            html = await http.text("/")
            state = extract_json_after(html, "window.__INITIAL_STATE__")
            if not isinstance(state, dict):
                raise ProviderError("番茄首页 SSR 状态解析失败（页面结构可能已改版）")
            home = state.get("home") or {}
            return {k: v for k, v in home.items() if isinstance(v, list)}

        rails, _ = await cache.get_or_load(HOME_RAILS_CACHE_KEY, load)
        return rails

    @staticmethod
    def _raise_if_error(data: Any, what: str) -> None:
        if not isinstance(data, dict):
            raise ProviderError(f"{what}: 返回体非对象")
        code = data.get("code")
        if code not in (0, None):
            raise ProviderError(f"{what} 失败: code={code} msg={data.get('message')}")
