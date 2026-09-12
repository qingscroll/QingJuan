"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

import asyncio
import re
import time
from typing import Any

from bs4 import BeautifulSoup

from ..httpclient import DEFAULT_UA, UpstreamError
from ..utils import abs_url, clean, first_num
from .base import BaseProvider, Channel, FetchResult, ProviderError, channel

BASE = "https://www.ciweimao.com"

# 站点限流：同一主机两次请求的最小间隔（秒）
PAGE_DELAY = 1.8

_CAPTCHA_RE = re.compile(r"<title>\s*验证码")
_BOOK_ID_RE = re.compile(r"/book/(\d+)")

# (key, 中文名, slug)
_RANK_LIST: list[tuple[str, str, str]] = [
    ("rank_yp", "月票榜", "yp"),
    ("rank_yp_new", "新书榜", "yp_new"),
    ("rank_click", "点击榜", "no-vip-click"),
    ("rank_favor", "收藏榜", "favor"),
    ("rank_recommend", "推荐榜", "recommend"),
    ("rank_buy", "订阅榜", "buy"),
    ("rank_tsukkomi", "吐槽榜", "tsukkomi"),
    ("rank_blade", "刀片榜", "blade"),
    ("rank_update", "更新榜", "get-update-most-week"),
]

_CHANNELS: list[Channel] = [
    channel(
        "rank_index",
        "排行榜首页",
        kind="rank",
        group="综合",
        description="排行榜首页 /rank-index 的 9 个书籍榜（点击/收藏/推荐/订阅/月票/吐槽/新书/刀片/更新）当前周期前十名去重合并；土豪粉丝榜为用户榜，已跳过",
        pageable=False,
    ),
    *[
        channel(
            key,
            name,
            kind="rank",
            group="综合",
            description=f"榜单 /rank-index/{slug}（10 条 / 页，后续页 /rank-index/{{slug}}-week/{{page}}）",
            params={"slug": slug},
        )
        for key, name, slug in _RANK_LIST
    ],
]


class Provider(BaseProvider):
    site = "ciweimao"
    site_name = "刺猬猫"
    content = "novel"
    homepage = BASE
    description = (
        "刺猬猫公开排行榜：月票/新书/点击/收藏/推荐/订阅/吐槽/刀片/更新榜 + 排行榜首页聚合；"
        "站点限流较严，通道间自动节流 1.8s"
    )
    requires_login = False
    channels = tuple(_CHANNELS)

    ua = DEFAULT_UA
    headers = {
        "Referer": BASE + "/",
        "X-Requested-With": "XMLHttpRequest",
    }

    # 全局节流状态（按事件循环区分）
    _gate_lock: asyncio.Lock | None = None
    _gate_loop: Any = None
    _gate_next: float = 0.0

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
        page = max(1, int(page))
        if channel.key == "rank_index":
            return await self._rank_index(channel, limit)
        return await self._rank_list(channel, page, limit, opts)

    # ------------------------------------------------------------------
    # 单榜单（可分页）
    # ------------------------------------------------------------------
    async def _rank_list(self, channel: Channel, page: int, limit: int, opts: dict[str, Any]) -> FetchResult:
        slug = clean(opts.get("slug"))
        if not slug:
            raise ProviderError(f"{channel.name}: 缺少榜单 slug 参数")
        url = (
            f"{BASE}/rank-index/{slug}" if page <= 1 else f"{BASE}/rank-index/{self._page_slug(slug)}/{page}"
        )
        soup = self._soup(await self._get(url, channel))
        rows = self._rank_rows(soup)
        if not rows:
            return FetchResult(items=[], has_more=False)
        has_more = soup.select_one(".pagination a[rel=next]") is not None
        return FetchResult(
            items=[self._book(channel, r) for r in rows[:limit]],
            has_more=has_more,
            page_size=10,
        )

    @staticmethod
    def _page_slug(slug: str) -> str:
        """第 2 页起的规范 slug：站点分页链接用的是 `{slug}-week`（实测第 1 页内容一致）。"""
        return slug if slug.endswith("-week") else f"{slug}-week"

    # ------------------------------------------------------------------
    # 排行榜首页（各榜单前十合并去重）
    # ------------------------------------------------------------------
    async def _rank_index(self, channel: Channel, limit: int) -> FetchResult:
        soup = self._soup(await self._get(f"{BASE}/rank-index", channel))
        merged: dict[str, dict[str, Any]] = {}
        for box in soup.select("div.J_RecommendBox"):
            title_node = box.select_one("h3.title")
            list_name = clean(title_node.get_text()) if title_node else ""
            if "粉丝榜" in list_name:
                continue  # 土豪粉丝榜是用户榜
            tab = box.select_one("ul.tab")
            if tab is None:
                continue
            for li in tab.find_all("li", recursive=False):
                row = self._index_row(li, list_name)
                if row is None:
                    continue
                bid = row["book_id"]
                exist = merged.get(bid)
                if exist is None:
                    merged[bid] = row
                elif list_name and list_name not in exist["lists"]:
                    exist["lists"].append(list_name)
        items = [self._book(channel, r) for r in list(merged.values())[:limit]]
        return FetchResult(items=items, has_more=False)

    def _index_row(self, li: Any, list_name: str) -> dict[str, Any] | None:
        a = li.select_one("div.info h3 a") or li.select_one("a.img") or li.find("a", href=True)
        if a is None:
            return None
        href = a.get("href") or ""
        m = _BOOK_ID_RE.search(href)
        if not m:
            return None  # 非书籍链接（用户 / 脚本占位）
        author_node = li.select_one("p.author a") or li.select_one("a[href*='/reader/']")
        img = li.select_one("a.img img") or li.select_one("img")
        num_node = li.select_one("p.num") or li.select_one("span.num")
        rank_node = li.select_one("i.icon-top")
        cat_node = li.find("b")
        row: dict[str, Any] = {
            "book_id": m.group(1),
            "title": clean((a.get("title") or "") or a.get_text()),
            "author": clean(author_node.get_text()) if author_node else "",
            "cover": self._cover(img),
            "intro": "",
            "category": clean(cat_node.get_text()).strip("[]【】") if cat_node else "",
            "rank_num": first_num(rank_node.get_text(), None) if rank_node else None,
            "value": clean(num_node.get_text()) if num_node else "",
            "lists": [list_name] if list_name else [],
        }
        return row

    # ------------------------------------------------------------------
    # 单榜单页面解析
    # ------------------------------------------------------------------
    def _rank_rows(self, soup: Any) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        for li in soup.select("li[data-book-id]"):
            row = self._rank_row(li)
            if row is not None:
                rows.append(row)
        return rows

    def _rank_row(self, li: Any) -> dict[str, Any] | None:
        bid = clean(li.get("data-book-id"))
        a = li.select_one("h3.tit a") or li.select_one("a.cover")
        href = (a.get("href") or "") if a is not None else ""
        m = _BOOK_ID_RE.search(href)
        if m:
            bid = bid or m.group(1)
        if not bid:
            return None
        rank_node = li.find("i")  # <i> 里是名次（前三名带 rank-top 样式类）
        author_node = li.select_one("a[href*='/reader/']")
        desc_node = li.select_one("p.desc")
        update_info = ""
        for p in li.select("div.cnt p"):
            text = clean(p.get_text())
            if text.startswith("最近更新"):
                update_info = text
                break
        update_time, latest_chapter = "", ""
        if update_info:
            body = update_info.split("：", 1)[-1]
            head, _, tail = body.partition("/")
            update_time = clean(head)
            latest_chapter = clean(tail)
        return {
            "book_id": bid,
            "title": clean((a.get("title") or "") or a.get_text()) if a is not None else "",
            "author": clean(author_node.get_text()) if author_node else "",
            "cover": self._cover(li.select_one("img")),
            "intro": clean(desc_node.get_text()) if desc_node else "",
            "rank_num": first_num(rank_node.get_text(), None) if rank_node is not None else None,
            "update_info": update_info,
            "update_time": update_time,
            "latest_chapter": latest_chapter,
        }

    @staticmethod
    def _cover(img: Any) -> str:
        if img is None:
            return ""
        src = (img.get("data-original") or img.get("src") or "").strip()
        if not src or src.endswith("transparent.png"):
            return ""
        return abs_url(BASE, src)

    # ------------------------------------------------------------------
    # 请求 / 解析辅助
    # ------------------------------------------------------------------
    async def _get(self, url: str, channel: Channel) -> str:
        await self._throttle()
        http = await self.client()
        try:
            html = await http.text(url)
        except UpstreamError as exc:
            raise ProviderError(f"{channel.name} 请求失败：{exc}") from exc
        if not html.strip():
            raise ProviderError(f"{channel.name} 返回空页面：{url}")
        if _CAPTCHA_RE.search(html):
            raise ProviderError(f"刺猬猫触发频率限制（返回验证码页），请降低请求频率后重试：{url}")
        return html

    @staticmethod
    def _soup(html: str) -> Any:
        return BeautifulSoup(html, "html.parser")

    @classmethod
    async def _throttle(cls) -> None:
        """同一主机全局节流：串行 + 请求间隔 ≥ PAGE_DELAY 秒。"""
        loop = asyncio.get_running_loop()
        if cls._gate_lock is None or cls._gate_loop is not loop:
            cls._gate_lock = asyncio.Lock()
            cls._gate_loop = loop
            cls._gate_next = 0.0
        async with cls._gate_lock:
            wait = cls._gate_next - time.monotonic()
            if wait > 0:
                await asyncio.sleep(wait)
            cls._gate_next = time.monotonic() + PAGE_DELAY

    # ------------------------------------------------------------------
    # 归一化
    # ------------------------------------------------------------------
    def _book(self, channel: Channel, raw: dict[str, Any]) -> Any:
        bid = str(raw.get("book_id") or "")
        extra = {k: v for k, v in raw.items() if k not in ("book_id",)}
        return self.make(
            channel,
            rank=raw.get("rank_num"),
            book_id=bid,
            title=clean(raw.get("title")),
            author=clean(raw.get("author")),
            cover=clean(raw.get("cover")),
            intro=clean(raw.get("intro")),
            category=clean(raw.get("category")),
            status="",
            word_count="",
            score=clean(raw.get("value")),
            url=abs_url(BASE, f"/book/{bid}") if bid else "",
            extra=extra,
        )
