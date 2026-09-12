"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

import asyncio
import html as _html
import json
import re
import time
from typing import Any

from bs4 import BeautifulSoup

from ..config import settings
from ..httpclient import UpstreamError
from ..utils import abs_url, clean, first_num, trim
from .base import BaseProvider, Channel, FetchResult, ProviderError, channel

BASE = "https://www.shuqi.com"

# /ranklist 侧边栏「全部榜单」的 (rank key, 中文名, 分组)，名称取自站点自身文案
RANK_LIST: tuple[tuple[str, str, str], ...] = (
    ("boyClick", "男频点击榜", "男频"),
    ("girlClick", "女频点击榜", "女频"),
    ("boyStore", "男频收藏榜", "男频"),
    ("girlStore", "女频收藏榜", "女频"),
    ("boyOrder", "男频订阅榜", "男频"),
    ("girlOrder", "女频订阅榜", "女频"),
    ("boyhot", "男频人气榜", "男频"),
    ("girlhot", "女频人气榜", "女频"),
    ("boyEnd", "男频完结榜", "男频"),
    ("girlEnd", "女频完结榜", "女频"),
    ("boyUpdate", "男频更新榜", "男频"),
    ("girlUpdate", "女频更新榜", "女频"),
    ("allEnd", "完结榜", "综合"),
    ("allWords", "字数榜", "综合"),
    ("allClick", "点击榜", "综合"),
    ("allStore", "收藏榜", "综合"),
    ("allOrder", "订阅榜", "综合"),
)

RANKLIST_PAGE_SIZE = 10
HOT_PAGE_SIZE = 60


def _rank_key_to_channel_key(rank_key: str) -> str:
    """`boyClick` -> `rank_boy_click`。"""
    snake = re.sub(r"(?<!^)(?=[A-Z])", "_", rank_key).lower()
    return f"rank_{snake}"


# 首页推荐位的轨道标题（站点自身文案）
HOME_RAILS: tuple[tuple[str, str], ...] = (
    ("男频好书", "recommend_male"),
    ("女频好书", "recommend_female"),
)

_CHANNELS: list[Channel] = (
    [
        channel(
            _rank_key_to_channel_key(rank_key),
            name,
            kind="rank",
            group=group,
            description=f"{name}（/ranklist?rank={rank_key}），10 条/页，可翻页",
            params={"rank_key": rank_key},
            pageable=True,
            default_limit=RANKLIST_PAGE_SIZE,
        )
        for rank_key, name, group in RANK_LIST
    ]
    + [
        channel(
            "recommend_hot",
            "爆款推荐",
            kind="recommend",
            group="推荐位",
            description="爆款推荐（/hotRecommend），60 条/页，可翻页",
            pageable=True,
            default_limit=HOT_PAGE_SIZE,
        ),
        channel(
            "recommend_excellence",
            "版权推荐",
            kind="recommend",
            group="推荐位",
            description="版权推荐主页（/excellence 内嵌 JSON），该页不支持翻页",
            pageable=False,
        ),
    ]
    + [
        channel(
            key,
            f"首页推荐位·{title}",
            kind="recommend",
            group="首页推荐位",
            description=f"首页「{title}」推荐轨道（/ 的 PcWebChannel），不翻页",
            params={"rail": title},
            pageable=False,
            default_limit=10,
        )
        for title, key in HOME_RAILS
    ]
)

# 完整浏览器请求头：缺任何一项都可能被 403/风控（见模块 docstring）
_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
_HEADERS = {
    "Accept": (
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"
    ),
    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    "Accept-Encoding": "gzip, deflate, br",
    "Cache-Control": "max-age=0",
    "Connection": "keep-alive",
    "Upgrade-Insecure-Requests": "1",
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Sec-Fetch-User": "?1",
    "sec-ch-ua": '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"',
    "sec-ch-ua-mobile": "?0",
    "sec-ch-ua-platform": '"Windows"',
}

# ---------------------------------------------------------------------------
# 同源节流：www.shuqi.com 有 429 风控
# ---------------------------------------------------------------------------
_MIN_INTERVAL = 1.5
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


def _bid_from_book_url(href: str) -> str:
    match = re.search(r"/book/(\d+)", href or "")
    return match.group(1) if match else ""


def _direct_text(node: Any) -> str:
    """只取直接子文本节点（用于剥掉 `<h2>标题<span>副标题</span></h2>` 里的副标题）。"""
    if node is None:
        return ""
    return clean(" ".join(str(t) for t in node.find_all(string=True, recursive=False)))


def _author_text(node: Any) -> str:
    """`.author-name` / `.author` 都写作「作者：XXX」，统一剥掉前缀。"""
    return re.sub(r"^作者\s*[:：]\s*", "", _direct_text(node))


def _has_next_page(soup: BeautifulSoup, page: int) -> bool:
    """分页条里是否存在指向下一页的链接（末页不会有 `page=当前+1`）。"""
    needle = f"page={int(page) + 1}"
    return any(needle in (a.get("href") or "") for a in soup.select(".comp-web-pages a[href]"))


def _book_url(book_id: str) -> str:
    return f"{BASE}/reader?bid={book_id}" if book_id else ""


# ---------------------------------------------------------------------------
# 解析器
# ---------------------------------------------------------------------------
def parse_ranklist(soup: BeautifulSoup, page: int, limit: int) -> list[dict[str, Any]]:
    """解析 `/ranklist?rank=...` 的 `ul.ranklist-ul > li`（每页 10 条）。"""
    base = (max(1, int(page or 1)) - 1) * RANKLIST_PAGE_SIZE
    rows: list[dict[str, Any]] = []
    for idx, node in enumerate(soup.select("ul.ranklist-ul > li"), start=1):
        link = node.select_one(".ranklinst-bk h3 a[href*='/book/']") or node.select_one("a[href*='/book/']")
        if link is None:
            continue
        book_id = _bid_from_book_url(link.get("href"))
        if not book_id:
            continue
        img = node.select_one("img")
        author_node = node.select_one(".ranklist-autor .bkuser-icon a")
        category_node = node.select_one(".bkcate-icon")
        desc_node = node.select_one(".ranklist-des")
        tags = [clean(a.get_text(strip=True)) for a in node.select(".ranklist-tag a")]
        rows.append(
            {
                "rank": base + idx,
                "book_id": book_id,
                "title": clean(_direct_text(link.select_one("h3")) or (img.get("alt") if img else "")),
                "author": clean(author_node.get_text(strip=True) if author_node is not None else ""),
                "cover": abs_url(BASE, (img.get("src") or "") if img is not None else ""),
                "intro": trim(desc_node.get_text(" ", strip=True) if desc_node is not None else "", 400),
                "category": clean(category_node.get_text(strip=True) if category_node is not None else ""),
                "extra": {"tags": tags},
                "url": _book_url(book_id),
            }
        )
        if len(rows) >= limit:
            break
    return rows


def parse_hot(soup: BeautifulSoup, limit: int) -> list[dict[str, Any]]:
    """解析 `/hotRecommend` 的 `a.hotRecommend-item`（每页 60 条，页面自带名次）。"""
    rows: list[dict[str, Any]] = []
    for node in soup.select("a.hotRecommend-item"):
        # href 形如 /query/{bookId}/{chapterId}
        match = re.search(r"/query/(\d+)", node.get("href") or "")
        if not match:
            continue
        book_id = match.group(1)
        h2 = node.select_one(".hotlist-bk h2")
        author_node = node.select_one(".author")
        state_node = node.select_one(".state")
        rank_node = node.select_one(".list-rank span")
        rows.append(
            {
                "rank": first_num(rank_node.get_text(strip=True) if rank_node is not None else None)
                or len(rows) + 1,
                "book_id": book_id,
                "title": _direct_text(h2),
                "author": _author_text(author_node),
                "category": clean(
                    author_node.select_one("span").get_text(strip=True)
                    if author_node is not None and author_node.select_one("span") is not None
                    else ""
                ),
                "status": clean(state_node.get_text(strip=True) if state_node is not None else ""),
                "extra": {
                    "subtitle": clean(
                        " ".join(s.get_text(strip=True) for s in h2.select("span")) if h2 else ""
                    ),
                    "query_url": abs_url(BASE, node.get("href") or ""),
                },
                "url": _book_url(book_id),
            }
        )
        if len(rows) >= limit:
            break
    return rows


def parse_home_rail(soup: BeautifulSoup, rail: str, limit: int) -> list[dict[str, Any]]:
    """解析首页 `.PcWebChannel` 轨道（如「男频好书」）。

    每个轨道 10 本：首本在 `.book-first-card`，其余在 `.book-card`，
    两处的字段类名一致（`img` / `.author-name` / `.book-class` / `.book-desc`）。
    """
    for section in soup.select(".PcWebChannel"):
        title_node = section.select_one(".channel-title")
        if title_node is None or clean(title_node.get_text(strip=True)) != rail:
            continue
        rows: list[dict[str, Any]] = []
        for link in section.select("a.book-name[href*='/book/']"):
            book_id = _bid_from_book_url(link.get("href"))
            if not book_id:
                continue
            card = link.find_parent(class_=re.compile(r"book-first-card|book-card"))
            img = card.find("img") if card is not None else None
            author_node = card.select_one(".author-name") if card is not None else None
            class_node = card.select_one(".book-class") if card is not None else None
            desc_node = card.select_one(".book-desc") if card is not None else None
            rows.append(
                {
                    "rank": len(rows) + 1,
                    "book_id": book_id,
                    "title": clean(link.get_text(strip=True)),
                    "author": _author_text(author_node),
                    "cover": abs_url(BASE, (img.get("src") or "") if img is not None else ""),
                    "intro": trim(desc_node.get_text(" ", strip=True) if desc_node is not None else "", 400),
                    "category": clean(class_node.get_text(strip=True) if class_node is not None else ""),
                    "url": _book_url(book_id),
                }
            )
            if len(rows) >= limit:
                break
        return rows
    return []


def parse_excellence(soup: BeautifulSoup, limit: int) -> list[dict[str, Any]]:
    """解析 `/excellence` 页内 `<i class="page-data js-datas2">` 的 JSON（版权推荐）。"""
    node = soup.select_one(".js-datas2")
    if node is None:
        raise ProviderError("版权推荐: 页面缺少 js-datas2 数据块")
    try:
        data = json.loads(_html.unescape(node.get_text() or ""))
    except ValueError as exc:
        raise ProviderError(f"版权推荐: js-datas2 解析失败: {exc}") from exc
    if not isinstance(data, list):
        raise ProviderError("版权推荐: js-datas2 非数组")
    rows: list[dict[str, Any]] = []
    for idx, raw in enumerate(data, start=1):
        if not isinstance(raw, dict):
            continue
        book_id = str(raw.get("shuqiBid") or "")
        if not book_id:
            continue
        tags = [
            clean(t.get("name"))
            for t in (raw.get("copyrightTags") or [])
            if isinstance(t, dict) and t.get("name")
        ]
        rows.append(
            {
                "rank": idx,
                "book_id": book_id,
                "title": clean(raw.get("bookName") or ""),
                "author": clean(raw.get("authorName") or ""),
                "cover": abs_url(BASE, clean(raw.get("cover") or "")),
                "intro": trim(raw.get("introduction") or "", 400),
                "word_count": clean(raw.get("wordNum") or ""),
                "score": clean(raw.get("hotScore") or ""),
                # `state` 是上游未公开语义的枚举，不猜成「连载/完结」，原样放进 extra
                "extra": {"state": raw.get("state"), "copyright_tags": tags, "derives": raw.get("derives")},
                "url": _book_url(book_id),
            }
        )
        if len(rows) >= limit:
            break
    return rows


class Provider(BaseProvider):
    site = "quark"
    site_name = "夸克小说"
    content = "novel"
    homepage = BASE
    description = "夸克小说（书旗内核）：17 个官方榜单、爆款推荐、版权推荐、首页男频/女频好书推荐位"
    requires_login = False
    channels = tuple(_CHANNELS)

    headers = _HEADERS
    ua = _UA
    encoding = "utf-8"

    # 首页 300KB 且被 2 个推荐位通道共用，做 60 秒短缓存
    _HOME_TTL = 60.0
    _home_cache: tuple[float, BeautifulSoup] | None = None

    @classmethod
    def client_kwargs(cls) -> dict[str, Any]:
        return {
            "headers": dict(_HEADERS),
            "cookies": _cookie_dict(settings.shuqi_cookies),
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
        if channel.key in _RANKLIST_CHANNEL_KEYS:
            return await self._ranklist(channel, page, limit, opts)
        if channel.key == "recommend_hot":
            return await self._hot(channel, page, limit)
        if channel.key == "recommend_excellence":
            return await self._excellence(channel, limit)
        if channel.key in _RAIL_CHANNEL_KEYS:
            return await self._home_rail(channel, limit, opts)
        raise ProviderError(f"未实现的通道: {channel.key}")

    # ------------------------------------------------------------------
    async def _ranklist(self, channel: Channel, page: int, limit: int, opts: dict[str, Any]) -> FetchResult:
        rank_key = str(opts.get("rank_key") or "")
        page = max(1, int(page or 1))
        soup = await self._get_soup("/ranklist", {"rank": rank_key, "page": page}, channel.name)
        rows = parse_ranklist(soup, page, limit)
        if not rows:
            raise ProviderError(f"{channel.name}: 榜单页未解析到书籍（上游可能改版或该榜单为空）")
        return FetchResult(items=self.make_many(channel, rows), has_more=_has_next_page(soup, page))

    async def _hot(self, channel: Channel, page: int, limit: int) -> FetchResult:
        page = max(1, int(page or 1))
        soup = await self._get_soup("/hotRecommend", {"page": page}, channel.name)
        rows = parse_hot(soup, limit)
        if not rows:
            raise ProviderError(f"{channel.name}: 页面未解析到书籍（上游可能改版）")
        return FetchResult(items=self.make_many(channel, rows), has_more=_has_next_page(soup, page))

    async def _excellence(self, channel: Channel, limit: int) -> FetchResult:
        soup = await self._get_soup("/excellence", None, channel.name)
        rows = parse_excellence(soup, limit)
        if not rows:
            raise ProviderError(f"{channel.name}: 页内数据块为空")
        return FetchResult(items=self.make_many(channel, rows), has_more=False)

    async def _home_rail(self, channel: Channel, limit: int, opts: dict[str, Any]) -> FetchResult:
        rail = str(opts.get("rail") or "")
        soup = await self._home_soup()
        rows = parse_home_rail(soup, rail, limit)
        if not rows:
            raise ProviderError(f"{channel.name}: 首页未找到「{rail}」推荐轨道")
        return FetchResult(items=self.make_many(channel, rows), has_more=False)

    # ------------------------------------------------------------------
    async def _home_soup(self) -> BeautifulSoup:
        cached = Provider._home_cache
        if cached is not None and time.monotonic() - cached[0] < self._HOME_TTL:
            return cached[1]
        soup = await self._get_soup("/", None, "首页")
        Provider._home_cache = (time.monotonic(), soup)
        return soup

    async def _get_soup(self, path: str, params: dict[str, Any] | None, what: str) -> BeautifulSoup:
        http = await self.client()
        await _throttle()
        try:
            html = await http.text(f"{BASE}{path}", params=params, headers=dict(_HEADERS))
        except UpstreamError as exc:
            raise ProviderError(f"{what} 请求失败: {exc}") from exc
        soup = BeautifulSoup(html, "html.parser")
        # 缺浏览器头或触发风控时上游会返回 403 页面；此处明确报错而不是静默返回空
        title = soup.title.get_text(strip=True) if soup.title is not None else ""
        if "访问被拒绝" in title or "403" in title:
            raise ProviderError(f"{what}: 被上游拒绝（403，可能触发风控，请降低频率）")
        if soup.select_one(".hotRecommend-item, ul.ranklist-ul, .PcWebChannel, .js-datas2") is None:
            # 没有识别到任何预期结构：可能是「系统超时」JSON 或页面改版
            head = re.sub(r"\s+", " ", (soup.get_text(" ", strip=True) or "")[:120])
            raise ProviderError(f"{what}: 页面结构未识别（上游返回: {head or '空内容'}）")
        return soup


_RANKLIST_CHANNEL_KEYS = tuple(_rank_key_to_channel_key(key) for key, _, _ in RANK_LIST)
_RAIL_CHANNEL_KEYS = tuple(key for _, key in HOME_RAILS)


__all__ = [
    "Provider",
    "HOME_RAILS",
    "RANK_LIST",
    "parse_excellence",
    "parse_home_rail",
    "parse_hot",
    "parse_ranklist",
]
