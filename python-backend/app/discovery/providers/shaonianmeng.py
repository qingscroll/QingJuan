"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

import asyncio
import re
import time
from typing import Any

from bs4 import BeautifulSoup

from ..config import settings
from ..httpclient import UpstreamError
from ..utils import abs_url, clean, trim
from .base import BaseProvider, Channel, FetchResult, ProviderError, channel

BASE = "https://www.shaoniandream.com"

# 站点自身的榜单类型（URL 段 -> 中文名，中文名取自页面 <title> 与 /ranking 板块名）
RANK_TYPES: tuple[tuple[str, str], ...] = (
    ("Favo", "收藏榜"),
    ("Subscribe", "畅销榜"),
    ("Recommendeds", "硬币榜"),
    ("MonthlyTickets", "月票榜"),
)

# /ranking 页面里的板块名（页面上写入的文案）
RANKING_SECTIONS: tuple[tuple[str, str], ...] = (
    ("人气榜", "rank_popular"),
    ("催更榜", "rank_urge"),
    ("打赏榜", "rank_reward"),
)

# /library/str 的 sort 枚举（站点自身文案）
LIBRARY_SORTS: dict[int, str] = {
    0: "默认排序",
    1: "周点击",
    2: "月点击",
    3: "总点击",
    4: "周推荐",
    5: "月推荐",
    6: "总推荐",
    7: "总收藏",
    8: "更新时间",
}

# /library/str 的分类枚举（站点自身文案）
LIBRARY_CATEGORIES: dict[int, str] = {
    0: "全部",
    6: "奇幻冒险",
    2: "仙侠玄幻",
    9: "游戏科幻",
    8: "动漫幻想",
    7: "历史军事",
    10: "恐怖生存",
    11: "都市人生",
}

RANKLIST_PAGE_SIZE = 10
LIBRARY_PAGE_SIZE = 12

_CHANNELS: list[Channel] = (
    [
        channel(
            f"rank_{key.lower()}",
            name,
            kind="rank",
            group="综合",
            description=f"{name}（/ranklist/{key}/Week），可用 options 传 period=Day|Week|Month|All",
            params={"type": key, "period": "Week"},
            pageable=True,
            default_limit=RANKLIST_PAGE_SIZE,
        )
        for key, name in RANK_TYPES
    ]
    + [
        channel(
            key,
            name,
            kind="rank",
            group="综合",
            description=f"{name}（/ranking 页面板块），该页不支持翻页",
            params={"section": name},
            pageable=False,
            default_limit=RANKLIST_PAGE_SIZE,
        )
        for name, key in RANKING_SECTIONS
    ]
    + [
        channel(
            "rank_week_recommend",
            "周推荐榜",
            kind="rank",
            group="书库",
            description="书库按「周推荐」排序（/library/str sort=4），可用 options 传 category 切换分类",
            params={"sort": 4, "category": 0},
            pageable=True,
            default_limit=LIBRARY_PAGE_SIZE,
        ),
        channel(
            "rank_month_recommend",
            "月推荐榜",
            kind="rank",
            group="书库",
            description="书库按「月推荐」排序（/library/str sort=5），可用 options 传 category 切换分类",
            params={"sort": 5, "category": 0},
            pageable=True,
            default_limit=LIBRARY_PAGE_SIZE,
        ),
    ]
)

# 桌面 Chrome UA（与 shaonianmeng_book/app/config.py 一致）
_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
_HEADERS = {
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    "Referer": BASE + "/",
    "Origin": BASE,
    "X-Requested-With": "XMLHttpRequest",
}

# ---------------------------------------------------------------------------
# 同源节流：间隔不小于 _MIN_INTERVAL 秒
# ---------------------------------------------------------------------------
_MIN_INTERVAL = 1.0
_throttle_lock: asyncio.Lock | None = None
_last_request_at = 0.0


async def _throttle() -> None:
    global _throttle_lock, _last_request_at
    if _throttle_lock is None:
        _throttle_lock = asyncio.Lock()
    async with _throttle_lock:
        wait = _last_request_at + _MIN_INTERVAL - time.monotonic()
        if wait > 0:
            await asyncio.sleep(wait)
        _last_request_at = time.monotonic()


def _cookie_dict(raw: str) -> dict[str, str]:
    """把 `a=1; b=2` 形式的 Cookie 串解析成字典。"""
    out: dict[str, str] = {}
    for part in (raw or "").split(";"):
        if "=" in part:
            key, _, value = part.partition("=")
            if key.strip():
                out[key.strip()] = value.strip()
    return out


def _book_id(href: str) -> str:
    match = re.search(r"/book_detail/(\d+)", href or "")
    return match.group(1) if match else ""


_STATUS_WORDS = ("连载中", "已完结", "完结", "暂停", "断更")


def _split_info(text: str) -> tuple[str, str, str]:
    """拆 `.info` / `dd.author` 的「作者 / 分类 / 状态」。

    两种页面形态并存：`/ranklist` 与 `/library` 是「作者 / 分类 / 状态」三段，
    而 `/ranking` 板块只有「作者 / 状态」两段。故先按状态关键词剥掉尾段，
    避免把「连载中」当成分类。
    """
    parts = [clean(part) for part in clean(text).split("/")]
    parts = [part for part in parts if part]
    status = ""
    if parts and any(word in parts[-1] for word in _STATUS_WORDS):
        status = parts.pop()
    return (
        parts[0] if len(parts) >= 1 else "",
        parts[1] if len(parts) >= 2 else "",
        status,
    )


def _cover_of(node) -> str:
    img = node.select_one("img")
    if img is None:
        return ""
    return abs_url(BASE, img.get("data-original") or img.get("src") or "")


def parse_ranklist(html: str, page: int, limit: int) -> list[dict[str, Any]]:
    """解析 `/ranklist/{Type}/{Period}` 的 `.ranking-piclist .list` 列表。

    上游每页只画名次角标、不给全局名次，故按「页码 + 页内位置」给出连续名次
    （第 2 页即 11~20），避免各页都从 1 开始导致名次重复。
    """
    soup = BeautifulSoup(html, "html.parser")
    base = (max(1, int(page or 1)) - 1) * RANKLIST_PAGE_SIZE
    rows: list[dict[str, Any]] = []
    for idx, node in enumerate(soup.select(".ranking-piclist .list"), start=1):
        link = node.select_one(".title a[href*='/book_detail/']") or node.select_one(
            "a[href*='/book_detail/']"
        )
        if link is None:
            continue
        book_id = _book_id(link.get("href"))
        if not book_id:
            continue
        author, category, status = _split_info(
            node.select_one(".info").get_text(" ", strip=True) if node.select_one(".info") else ""
        )
        jianjie = node.select_one(".jianjie")
        rows.append(
            {
                "rank": base + idx,
                "book_id": book_id,
                "title": clean(link.get("title") or link.get_text(" ", strip=True)),
                "author": author,
                "category": category,
                "status": status,
                "cover": _cover_of(node),
                "intro": trim(jianjie.get_text(" ", strip=True) if jianjie else "", 400),
                "url": abs_url(BASE, link.get("href") or ""),
            }
        )
        if len(rows) >= limit:
            break
    return rows


def parse_ranking_sections(html: str) -> dict[str, list[dict[str, Any]]]:
    """解析 `/ranking` 的板块 -> 书籍列表。

    板块名取自 `.title em a` 的 `title`（即「更多」链接指向的榜单名），
    缺失时退回 `.title span` 文本。板块内前 3 名是 `.pic-list .top`（带封面与作者），
    第 4 名起是 `ul li dl`（只有名次/书名/热度）。
    """
    soup = BeautifulSoup(html, "html.parser")
    out: dict[str, list[dict[str, Any]]] = {}
    for section in soup.select(".ranking-main .list"):
        more = section.select_one(".title em a")
        name_node = section.select_one(".title span")
        name = clean(
            (more.get("title") if more is not None else "")
            or (name_node.get_text(strip=True) if name_node is not None else "")
        )
        if not name:
            continue
        rows: list[dict[str, Any]] = []
        # 前 3 名
        for node in section.select(".pic-list .top"):
            link = node.select_one(".caption a[href*='/book_detail/']")
            if link is None:
                continue
            book_id = _book_id(link.get("href"))
            if not book_id:
                continue
            author, category, status = _split_info(
                node.select_one(".info").get_text(" ", strip=True) if node.select_one(".info") else ""
            )
            hot = node.select_one(".hot")
            rows.append(
                {
                    "rank": len(rows) + 1,
                    "book_id": book_id,
                    "title": clean(link.get("title") or link.get_text(" ", strip=True)),
                    "author": author,
                    "category": category,
                    "status": status,
                    "cover": _cover_of(node),
                    "score": clean(hot.get_text(strip=True) if hot is not None else ""),
                    "url": abs_url(BASE, link.get("href") or ""),
                }
            )
        # 第 4 名起
        for node in section.select("ul li dl"):
            link = node.select_one("dd.font a[href*='/book_detail/']")
            if link is None:
                continue
            book_id = _book_id(link.get("href"))
            if not book_id:
                continue
            num = node.select_one("dd.num")
            hot = node.select_one("dd.hot")
            rows.append(
                {
                    "rank": _int_or_none(num.get_text(strip=True) if num is not None else "")
                    or len(rows) + 1,
                    "book_id": book_id,
                    "title": clean(link.get("title") or link.get_text(" ", strip=True)),
                    "score": clean(hot.get_text(strip=True) if hot is not None else ""),
                    "url": abs_url(BASE, link.get("href") or ""),
                }
            )
        if rows:
            out[name] = rows
    return out


def parse_library(html: str, page: int, limit: int) -> list[dict[str, Any]]:
    """解析 `/library/str/...` 的 `.BookPicList ul li dl`（沿用既有解析器的选择器）。

    同 `parse_ranklist`：名次按「页码 + 页内位置」连续给出。
    """
    soup = BeautifulSoup(html, "html.parser")
    base = (max(1, int(page or 1)) - 1) * LIBRARY_PAGE_SIZE
    rows: list[dict[str, Any]] = []
    for node in soup.select(".BookPicList ul li dl"):
        link = node.select_one("dd.title a[href*='/book_detail/']")
        if link is None:
            continue
        book_id = _book_id(link.get("href"))
        if not book_id:
            continue
        author_link = node.select_one("dd.author a[href*='/author/index/id/']")
        author_node = node.select_one("dd.author")
        _, category, status = _split_info(
            author_node.get_text(" ", strip=True) if author_node is not None else ""
        )
        jianjie = node.select_one("dd.jianjie")
        chapter = node.select_one("dd.newChapter a")
        rows.append(
            {
                "rank": base + len(rows) + 1,
                "book_id": book_id,
                "title": clean(link.get("title") or link.get_text(" ", strip=True)),
                "author": clean(author_link.get_text(strip=True) if author_link is not None else ""),
                "category": category,
                "status": status,
                "cover": _cover_of(node),
                "intro": trim(jianjie.get_text(" ", strip=True) if jianjie is not None else "", 400),
                "extra": {
                    "latest_chapter": clean(chapter.get_text(strip=True) if chapter is not None else "")
                },
                "url": abs_url(BASE, link.get("href") or ""),
            }
        )
        if len(rows) >= limit:
            break
    return rows


def _int_or_none(value: Any) -> int | None:
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


class Provider(BaseProvider):
    site = "shaonianmeng"
    site_name = "少年梦阅读"
    content = "novel"
    homepage = BASE
    description = "少年梦阅读：收藏/畅销/硬币/月票榜、完整榜单页的人气·催更·打赏榜、书库周月推荐"
    requires_login = False
    channels = tuple(_CHANNELS)

    headers = _HEADERS
    ua = _UA
    encoding = "utf-8"

    # /ranking 单页 66KB 且被 3 个通道共用，做 60 秒短缓存减少上游压力
    _RANKING_TTL = 60.0
    _ranking_cache: tuple[float, dict[str, list[dict[str, Any]]]] | None = None

    @classmethod
    def client_kwargs(cls) -> dict[str, Any]:
        return {
            "headers": dict(_HEADERS),
            "cookies": _cookie_dict(settings.shaoniandream_cookies),
            "ua": _UA,
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
        if channel.key in _RANKLIST_KEYS:
            return await self._ranklist(channel, page, limit, opts)
        if channel.key in _RANKING_KEYS:
            return await self._ranking_section(channel, limit, opts)
        if channel.key in ("rank_week_recommend", "rank_month_recommend"):
            return await self._library(channel, page, limit, opts)
        raise ProviderError(f"未实现的通道: {channel.key}")

    # ------------------------------------------------------------------
    async def _ranklist(self, channel: Channel, page: int, limit: int, opts: dict[str, Any]) -> FetchResult:
        rank_type = str(opts.get("type") or "")
        period = str(opts.get("period") or "Week")
        path = f"/ranklist/{rank_type}/{period}"
        html = await self._get_page(path, page, channel.name)
        rows = parse_ranklist(html, page, limit)
        if not rows:
            raise ProviderError(f"{channel.name}: 页面未解析到书籍（可能上游改版）")
        return FetchResult(items=self.make_many(channel, rows), has_more=len(rows) >= RANKLIST_PAGE_SIZE)

    async def _ranking_section(self, channel: Channel, limit: int, opts: dict[str, Any]) -> FetchResult:
        name = str(opts.get("section") or channel.name)
        sections = await self._ranking_sections()
        rows = sections.get(name) or []
        if not rows:
            raise ProviderError(f"{channel.name}: /ranking 页面未找到该板块或无书籍")
        return FetchResult(items=self.make_many(channel, rows[:limit]), has_more=False)

    async def _library(self, channel: Channel, page: int, limit: int, opts: dict[str, Any]) -> FetchResult:
        sort = int(opts.get("sort") or 0)
        category = int(opts.get("category") or 0)
        # 路径第 8 段（page）是失效字段，翻页只认查询参数 ?page=N
        path = f"/library/str/{category}_{sort}_0_0_0_0_0_1_"
        html = await self._get_page(path, page, channel.name)
        rows = parse_library(html, page, limit)
        if not rows:
            raise ProviderError(f"{channel.name}: 页面未解析到书籍（可能上游改版）")
        soup = BeautifulSoup(html, "html.parser")
        has_more = bool(soup.select_one(".pageInfo a[title='下一页']")) or len(rows) >= LIBRARY_PAGE_SIZE
        return FetchResult(items=self.make_many(channel, rows), has_more=has_more)

    # ------------------------------------------------------------------
    async def _ranking_sections(self) -> dict[str, list[dict[str, Any]]]:
        cached = Provider._ranking_cache
        if cached is not None and time.monotonic() - cached[0] < self._RANKING_TTL:
            return cached[1]
        html = await self._get_page("/ranking", 1, "完整榜单页")
        sections = parse_ranking_sections(html)
        Provider._ranking_cache = (time.monotonic(), sections)
        return sections

    async def _get_page(self, path: str, page: int, what: str) -> str:
        http = await self.client()
        await _throttle()
        params = {"page": page} if page and page > 1 else None
        try:
            html = await http.text(f"{BASE}{path}", params=params, headers=dict(_HEADERS))
        except UpstreamError as exc:
            raise ProviderError(f"{what} 请求失败: {exc}") from exc
        # 未登录/被风控时站点会返回登录页，明确报错而不是静默返回空
        if "user-login-dialog" in html or "<title>用户登录" in html:
            raise ProviderError(f"{what}: 上游返回登录页（站点风控或需要 Cookie）")
        return html


_RANKLIST_KEYS = tuple(f"rank_{key.lower()}" for key, _ in RANK_TYPES)
_RANKING_KEYS = tuple(key for _, key in RANKING_SECTIONS)


__all__ = [
    "Provider",
    "LIBRARY_CATEGORIES",
    "LIBRARY_SORTS",
    "parse_library",
    "parse_ranking_sections",
    "parse_ranklist",
]
