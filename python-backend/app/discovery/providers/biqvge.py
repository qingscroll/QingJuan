"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

import re
from typing import Any

from bs4 import BeautifulSoup

from ..httpclient import UpstreamError
from ..utils import abs_url, clean
from .base import BaseProvider, Channel, FetchResult, ProviderError, channel

BASE = "https://www.b520.cc"

# 形如 "147_147321/" 或 "../147_147321/"
_BOOK_RE = re.compile(r"(\d+)_(\d+)")

# (key, 中文名, 路径, 分类名)
_CATEGORIES: list[tuple[str, str, str, str]] = [
    ("cat_xuanhuan", "玄幻小说", "/xuanhuanxiaoshuo/", "玄幻小说"),
    ("cat_xiuzhen", "修真小说", "/xiuzhenxiaoshuo/", "修真小说"),
    ("cat_dushi", "都市小说", "/dushixiaoshuo/", "都市小说"),
    ("cat_chuanyue", "穿越小说", "/chuanyuexiaoshuo/", "穿越小说"),
    ("cat_wangyou", "网游小说", "/wangyouxiaoshuo/", "网游小说"),
    ("cat_kehuan", "科幻小说", "/kehuanxiaoshuo/", "科幻小说"),
    ("cat_yanqing", "言情小说", "/yanqingxiaoshuo/", "言情小说"),
    ("cat_tongren", "同人小说", "/tongrenxiaoshuo/", "同人小说"),
]

_CHANNELS: list[Channel] = [
    channel(
        "recommend_home",
        "首页热门",
        kind="recommend",
        group="首页",
        description="首页 / 的编辑推荐位 + 各分类榜首与分类前十（已去重）",
        pageable=False,
    ),
    *[
        channel(
            key,
            name,
            kind="rank",
            group="分类",
            description=f"分类页 {path}（页面标题即「…排行榜」，实测 4-6 本且无分页）",
            params={"path": path, "category": category},
            pageable=False,
        )
        for key, name, path, category in _CATEGORIES
    ],
]


class Provider(BaseProvider):
    site = "biqvge"
    site_name = "笔趣阁聚合"
    content = "novel"
    homepage = BASE
    description = (
        "笔趣阁5200（b520.cc）静态目录页：首页热门 + 玄幻/修真/都市/穿越/网游/科幻/言情/同人 8 个分类榜；"
        "另一镜像 blqukan.cc 本机被地域封锁（403），其排行榜/完本榜通道未注册"
    )
    requires_login = False
    channels = tuple(_CHANNELS)

    # b520.cc 是 UTF-8（GBK 的 blqukan.cc 已被剔除）
    encoding = "utf-8"
    headers = {"Referer": BASE + "/"}

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
        if page > 1:
            # 站点无分页：诚实返回空结果，不重复第 1 页数据
            return FetchResult(items=[], has_more=False)

        path = "/" if channel.key == "recommend_home" else str(opts.get("path") or "")
        if not path:
            raise ProviderError(f"{channel.name}: 缺少分类页路径参数")
        category = str(opts.get("category") or "")

        http = await self.client()
        url = abs_url(BASE, path)
        try:
            html = await http.text(url)
        except UpstreamError as exc:
            raise ProviderError(f"{channel.name} 请求失败：{exc}") from exc
        if not html.strip():
            raise ProviderError(f"{channel.name} 返回空页面：{url}")

        rows = self._parse(html, url, category)
        return FetchResult(
            items=[self._book(channel, row, rank=idx) for idx, row in enumerate(rows[:limit], start=1)],
            has_more=False,
        )

    # ------------------------------------------------------------------
    # 解析
    # ------------------------------------------------------------------
    def _parse(self, html: str, page_url: str, category: str) -> list[dict[str, Any]]:
        soup = BeautifulSoup(html, "html.parser")
        rows: list[dict[str, Any]] = []
        seen: set[str] = set()

        # 1) 标准条目块（首页 div.item / 分类页 div.ll div.item）
        for dt in soup.select("div.item dt"):
            item_div = dt.find_parent("div", class_="item") or dt.parent
            self._push(rows, seen, dt, item_div, category, page_url)

        # 2) 首页 div.novelslist：每块「分类榜首（带封面/简介）+ 分类前 12 名（书名/作者）」
        for block in soup.select("div.novelslist"):
            h2 = block.find("h2")
            block_cat = clean(h2.get_text()) if h2 is not None else ""
            top = block.select_one("div.top")
            if top is not None:
                dt = top.find("dt")
                if dt is not None:
                    self._push(rows, seen, dt, top, block_cat or category, page_url)
            for li in block.select("ul li"):
                row = self._link_row(li, block_cat or category)
                if row is None or row["book_id"] in seen:
                    continue
                seen.add(row["book_id"])
                rows.append(row)
        return rows

    def _push(
        self,
        rows: list[dict[str, Any]],
        seen: set[str],
        dt: Any,
        item_div: Any,
        category: str,
        page_url: str,
    ) -> None:
        a = dt.find("a")
        if a is None:
            return
        title = clean(a.get_text())
        full = self._full_id(a.get("href") or "")
        if not full or not title:  # href 被改写成 "/" 的反爬条目
            return
        bid = full.split("_", 1)[1]
        if bid in seen:
            return
        seen.add(bid)
        span = dt.find("span")
        dd = dt.find_next_sibling("dd")
        img = item_div.find("img") if item_div is not None else None
        rows.append(
            {
                "book_id": bid,
                "full_id": full,
                "title": title,
                "author": clean(span.get_text()) if span is not None else "",
                "intro": clean(dd.get_text(" ")) if dd is not None else "",
                "cover": abs_url(page_url, (img.get("src") or "").strip()) if img is not None else "",
                "category": category,
            }
        )

    def _link_row(self, li: Any, category: str) -> dict[str, Any] | None:
        """`ul li` 形如 `<a href="2_2157/">太古神王</a>/净无痕`。"""
        a = li.find("a")
        if a is None:
            return None
        title = clean(a.get_text())
        full = self._full_id(a.get("href") or "")
        if not full or not title:
            return None
        text = clean(li.get_text())
        author = clean(text.split("/", 1)[1]) if "/" in text else ""
        return {
            "book_id": full.split("_", 1)[1],
            "full_id": full,
            "title": title,
            "author": author,
            "intro": "",
            "cover": "",
            "category": category,
        }

    @staticmethod
    def _full_id(href: str) -> str:
        m = _BOOK_RE.search(href or "")
        return m.group(0) if m else ""

    # ------------------------------------------------------------------
    # 归一化
    # ------------------------------------------------------------------
    def _book(self, channel: Channel, raw: dict[str, Any], rank: int | None = None) -> Any:
        full = str(raw.get("full_id") or "")
        bid = str(raw.get("book_id") or "")
        return self.make(
            channel,
            rank=rank,
            book_id=bid,
            title=clean(raw.get("title")),
            author=clean(raw.get("author")),
            cover=clean(raw.get("cover")),
            intro=clean(raw.get("intro")),
            category=clean(raw.get("category")),
            status="",
            word_count="",
            score="",
            url=abs_url(BASE, f"/{full}/") if full else "",
            extra={"full_id": full},
        )
