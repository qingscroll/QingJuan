"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

import asyncio
import re
import time
from typing import Any
from urllib.parse import urlencode

from bs4 import BeautifulSoup

from ..httpclient import UpstreamError
from ..utils import abs_url, clean, first_num, pick
from .base import BaseProvider, Channel, FetchResult, ProviderError, channel

BASE = "https://www.yoyomanga.com"
MIRROR = "https://www.colamanga.com"
SHOW_URL = f"{BASE}/show"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"
)

MIN_INTERVAL = 1.0  # 同站点请求最小间隔（秒）
PAGE_TTL = 120.0  # 页面内存 TTL（秒）
PAGE_SIZE = 30  # /show 每页条数（实测固定 30）
DEFAULT_SEED = ""  # 「猜你喜欢」默认种子为空：改为动态取周榜第 1 名

# 站点导航里实测可用的分类（mainCategoryId -> 名称），全部现场验证有真实书单
CATEGORIES: list[tuple[str, str]] = [
    ("10023", "热血"),
    ("10024", "玄幻"),
    ("10122", "搞笑"),
    ("10124", "都市"),
    ("10126", "恋爱"),
    ("10129", "穿越"),
    ("10131", "校园"),
    ("10143", "古风"),
    ("10210", "冒险"),
    ("10227", "魔幻"),
    ("10242", "奇幻"),
    ("10309", "战斗"),
    ("10321", "少年"),
    ("10453", "修仙"),
    ("10461", "重生"),
    ("10485", "异能"),
    ("10943", "逆袭"),
    ("10946", "末日"),
]
CATEGORY_NAMES = dict(CATEGORIES)

# 排序：key -> (orderBy 参数, 站点原文案)
ORDERS: list[tuple[str, str, str]] = [
    ("rank_weekly", "weeklyCount", "周点击榜"),
    ("rank_daily", "dailyCount", "日点击榜"),
]
ORDER_BY_KEY = {key: (value, label) for key, value, label in ORDERS}

HOME_SHELF = "本周热门/推荐"  # トップページ首个推荐书架（站点自己的 h2 文案）
YOULIKE_SHELF = "猜你喜欢"  # 作品页相关推荐（站点自己的 h2 文案）

_MANGA_RE = re.compile(r"/manga-([A-Za-z0-9]+)/")

# --------------------------------------------------------------------------
# 通道清单
# --------------------------------------------------------------------------
_CHANNELS: list[Channel] = [
    channel(
        key,
        label,
        kind="rank",
        group="排行榜",
        description=f"/show?orderBy={value}（站点排行榜默认排序即 {label}）",
        params={"order_by": value},
    )
    for key, value, label in ORDERS
]
_CHANNELS += [
    channel(
        f"rank_cat_{cid}",
        f"{name}排行榜",
        kind="rank",
        group="分类榜",
        description=f"/show?mainCategoryId={cid}&orderBy=weeklyCount（分类：{name}）",
        params={"order_by": "weeklyCount", "main_category_id": cid},
    )
    for cid, name in CATEGORIES
]
_CHANNELS += [
    channel(
        "recommend_home_hot",
        HOME_SHELF,
        kind="recommend",
        group="首页推荐位",
        description=f"トップページ书架「{HOME_SHELF}」（固定 6 条）",
        pageable=False,
    ),
    channel(
        "recommend_youlike",
        YOULIKE_SHELF,
        kind="recommend",
        group="作品页相关推荐",
        description="作品页「猜你喜欢」相关推荐（固定 6 条）；可用 options 传 book_id 指定种子作品，"
        "缺省时自动取周榜第 1 名作为种子",
        pageable=False,
    ),
]


# --------------------------------------------------------------------------
# 限速 + 页面缓存
# --------------------------------------------------------------------------
_rate_lock = asyncio.Lock()
_last_call = 0.0

_page_lock = asyncio.Lock()
_page_cache: dict[str, tuple[float, str]] = {}


async def _throttle() -> None:
    """同站点请求间隔 ≥ MIN_INTERVAL 秒。"""
    global _last_call
    async with _rate_lock:
        gap = MIN_INTERVAL - (time.monotonic() - _last_call)
        if gap > 0:
            await asyncio.sleep(gap)
        _last_call = time.monotonic()


# --------------------------------------------------------------------------
# 解析
# --------------------------------------------------------------------------
def _book_id(href: str) -> str:
    match = _MANGA_RE.search(href or "")
    return match.group(1) if match else ""


def _cards(container: Any) -> list[dict[str, Any]]:
    """从任意容器里按「封面 + 标题」配对抽卡片（``/show``、首页书架、猜你喜欢通用）。"""
    if container is None:
        return []
    rows: list[dict[str, Any]] = []
    for item in container.select("li.fed-list-item") or container.select("li"):
        pic = item.select_one("a.fed-list-pics")
        title_node = item.select_one("a.fed-list-title")
        href = (pic.get("href") if pic is not None else None) or (
            title_node.get("href") if title_node is not None else None
        )
        book_id = _book_id(href or "")
        if not book_id:
            continue
        rows.append(
            {
                "book_id": book_id,
                "title": clean(title_node.get_text(" ")) if title_node is not None else "",
                "cover": clean(pick(dict(pic.attrs or {}), "data-original", "src"))
                if pic is not None
                else "",
                "url": abs_url(BASE, href or ""),
            }
        )
    return rows


def _parse_show(html: str) -> tuple[list[dict[str, Any]], int, int]:
    """``/show`` 页 -> (条目, 当前页, 总页数)。"""
    soup = BeautifulSoup(html, "html.parser")
    rows = _cards(soup.select_one("ul.fed-list-info")) or _cards(soup)
    current_node = soup.select_one("#fed-now")
    total_node = soup.select_one("#fed-count")
    current = first_num(current_node.get_text() if current_node is not None else None, 1) or 1
    total = first_num(total_node.get_text() if total_node is not None else None, 0) or 0
    if not total:
        jump = soup.select_one(".show-page-jump")
        if jump is not None:
            total = first_num(jump.get("data-total"), 0) or 0
    return rows, current, total


def _parse_shelf(html: str, heading: str) -> list[dict[str, Any]]:
    """按栏目 h2 文案取书架（首页书架 / 作品页「猜你喜欢」）。"""
    soup = BeautifulSoup(html, "html.parser")
    for head in soup.select(".fed-list-head"):
        title_node = head.select_one("h2")
        if title_node is None or clean(title_node.get_text(" ")) != heading:
            continue
        layout = head.find_parent("div") or head.parent
        rows = _cards(layout)
        if rows:
            return rows
    return []


class Provider(BaseProvider):
    site = "yoyomanga"
    site_name = "YY漫画（COLAMANGA）"
    content = "comic"
    homepage = BASE
    description = "YY漫画 / COLAMANGA 公开页面：周榜 / 日榜、18 个分类排行榜（可翻页）＋ 首页与作品页推荐位"
    requires_login = False
    channels = tuple(_CHANNELS)
    ua = UA
    headers = {"Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8,ja;q=0.7"}

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

        if channel.key in ORDER_BY_KEY or channel.key.startswith("rank_cat_"):
            return await self._show(channel, page, limit, opts)
        if channel.key == "recommend_home_hot":
            rows = _parse_shelf(await self._page(f"{BASE}/"), str(opts.get("shelf") or HOME_SHELF))
            if not rows:
                raise ProviderError(f"{channel.name}: 首页未解析到「{HOME_SHELF}」书架")
            return FetchResult(items=self.make_many(channel, rows[:limit]), has_more=False)
        if channel.key == "recommend_youlike":
            return await self._youlike(channel, limit, opts)
        raise ProviderError(f"未实现的通道: {channel.key}")

    # ------------------------------------------------------------------
    async def _show(self, channel: Channel, page: int, limit: int, opts: dict[str, Any]) -> FetchResult:
        current_page = max(1, int(page))
        params: dict[str, Any] = {}
        order_by = str(opts.get("order_by") or "")
        if order_by:
            params["orderBy"] = order_by
        category = str(opts.get("main_category_id") or "")
        if category:
            params["mainCategoryId"] = category
        char_category = str(opts.get("char_category_id") or "")
        if char_category:
            params["charCategoryId"] = char_category
        if current_page > 1:
            params["page"] = current_page

        html = await self._page(SHOW_URL, params)
        rows, _, total_pages = _parse_show(html)
        if not rows:
            raise ProviderError(
                f"{channel.name}: 上游未返回条目（第 {current_page} 页；可能是分类 id 失效或页面结构变更）"
            )
        base = (current_page - 1) * PAGE_SIZE
        items = [
            self.make(channel, rank=base + index, extra={"page": current_page}, **row)
            for index, row in enumerate(rows[:limit], start=1)
        ]
        has_more = bool(total_pages) and current_page < total_pages
        return FetchResult(items=items, has_more=has_more)

    async def _youlike(self, channel: Channel, limit: int, opts: dict[str, Any]) -> FetchResult:
        book_id = str(opts.get("book_id") or DEFAULT_SEED)
        if not book_id:
            # 未指定种子作品：取站内周榜第 1 名（站点自己的「本周热门」）作为种子，避免写死作品短码
            seed_rows, _, _ = _parse_show(await self._page(SHOW_URL, {"orderBy": "weeklyCount"}))
            if not seed_rows:
                raise ProviderError(
                    f"{channel.name}: 无法从 /show 取到种子作品，可用 options={{'book_id': '...'}} 指定"
                )
            book_id = seed_rows[0]["book_id"]
        html = await self._page(f"{BASE}/manga-{book_id}/")
        rows = _parse_shelf(html, str(opts.get("shelf") or YOULIKE_SHELF))
        if not rows:
            raise ProviderError(f"{channel.name}: 作品页 manga-{book_id} 未解析到「{YOULIKE_SHELF}」书架")
        items = [self.make(channel, extra={"seed_book_id": book_id}, **row) for row in rows[:limit]]
        return FetchResult(items=items, has_more=False)

    # ------------------------------------------------------------------
    async def _page(self, url: str, params: dict[str, Any] | None = None) -> str:
        """抓页面（带 TTL 缓存：同一次榜单抓取里首页/作品页会被多个通道复用）。"""
        target = url + (f"?{urlencode(params)}" if params else "")
        cached = _page_cache.get(target)
        if cached and time.monotonic() - cached[0] < PAGE_TTL:
            return cached[1]
        async with _page_lock:
            cached = _page_cache.get(target)
            if cached and time.monotonic() - cached[0] < PAGE_TTL:
                return cached[1]
            http = await self.client()
            await _throttle()
            try:
                html = await http.text(target)
            except UpstreamError as exc:
                raise ProviderError(f"{self.site_name} 页面抓取失败 {target}: {exc}") from exc
            if not html.strip():
                raise ProviderError(
                    f"{self.site_name} 返回空响应体（mainCategoryId 之类的参数可能无效，或已被反爬拦截）: {target}"
                )
            if "fed-list" not in html:
                raise ProviderError(
                    f"{self.site_name} 返回内容不含站点结构（页面结构可能已变更，或已被反爬拦截）: {target}"
                )
            if len(_page_cache) >= 64:
                _page_cache.pop(next(iter(_page_cache)))
            _page_cache[target] = (time.monotonic(), html)
            return html
