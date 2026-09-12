"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

import asyncio
import re
import time
from typing import Any

from ..config import settings
from .base import BaseProvider, Channel, FetchResult, ProviderError, SiteAccessLimited, channel

BASE = "https://e-hentai.org"
SITE_URL = BASE
PAGE_SIZE = 50
# 站点对匿名抓取极其敏感（实测 1s 间隔连发 50 余次即被封 IP 24 小时），
# 这里取比「至少 1s」更保守的 2s 间隔。
MIN_INTERVAL = 2.0
GID_PAT = re.compile(r"/g/(\d+)/([0-9a-f]{10})")
BAN_MARK = "temporarily banned"

# 权威 tl 映射（取自 toplist.php 根页面的选择器）
TOPLISTS: dict[str, tuple[int, str, str]] = {
    "toplist_alltime": (11, "全时段榜", "Galleries All-Time"),
    "toplist_year": (12, "年度榜", "Galleries Past Year"),
    "toplist_month": (13, "月度榜", "Galleries Past Month"),
    "toplist_yesterday": (15, "昨日榜", "Galleries Yesterday"),
}

POLL_NAMES = {tl: name for tl, name, _ in TOPLISTS.values()}

_CHANNELS: list[Channel] = [
    channel(
        key,
        name,
        kind="rank",
        group="总榜",
        description=f"E-Hentai 画廊榜：{en}（GET /toplist.php?tl={tl}，每页 50 本）",
        params={"tl": tl},
        pageable=True,
    )
    for key, (tl, name, en) in TOPLISTS.items()
]

_rate_lock = asyncio.Lock()
_last_request_at = 0.0


def _cookie_dict(raw: str) -> dict[str, str]:
    """把 "k=v; k2=v2" 形式的 cookie 串解析成 dict。"""
    out: dict[str, str] = {}
    for part in (raw or "").split(";"):
        if "=" in part:
            key, _, value = part.partition("=")
            if key.strip():
                out[key.strip()] = value.strip()
    return out


class Provider(BaseProvider):
    site = "ehentai"
    site_name = "E-Hentai"
    content = "comic"
    homepage = BASE
    description = (
        "E-Hentai 画廊 Toplists：全时段榜 / 年度榜 / 月度榜 / 昨日榜（tl=11/12/13/15，"
        "每页 50 本）；面板的 f_sort 排序榜在匿名访问下不可用，未注册"
    )
    requires_login = False
    headers = {"Accept-Language": "en-US,en;q=0.9"}
    channels = tuple(_CHANNELS)

    @classmethod
    def client_kwargs(cls) -> dict[str, Any]:
        kwargs = super().client_kwargs()
        raw = (settings.ehentai_cookies or "").strip()
        if raw:
            cookies = dict(kwargs.get("cookies") or {})
            cookies.update(_cookie_dict(raw))
            kwargs["cookies"] = cookies
        return kwargs

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
        tl = opts.get("tl")
        if tl is None:
            raise ProviderError(f"未实现的通道: {channel.key}")
        tl = int(tl)
        page = max(1, int(page))

        html = await self._get_page(tl, page, channel.name)
        rows = _parse_toplists(html)
        if not rows:
            raise ProviderError(f"{channel.name}: toplist tl={tl} 解析不到画廊（页面结构可能已变更）")
        total_pages = _parse_total_pages(html, tl)
        base_rank = (page - 1) * PAGE_SIZE
        items = [
            self._book(channel, row, base_rank + index) for index, row in enumerate(rows[:limit], start=1)
        ]
        # 分页条可用时以其为准，否则退化为「本页是否满 50 条」
        has_more = page < total_pages if total_pages else len(rows) >= PAGE_SIZE
        return FetchResult(items=items, has_more=has_more)

    # ------------------------------------------------------------------
    async def _get_page(self, tl: int, page: int, what: str) -> str:
        """限速抓取一页榜单；429 退避重试一次，再失败抛 ProviderError。"""
        http = await self.client()
        # p 从 0 开始：第 1 页 = p=0
        url = f"{BASE}/toplist.php?tl={tl}&p={page - 1}"
        last_error = ""
        for attempt in range(2):
            await _throttle()
            try:
                resp = await http.get(url)
            except Exception as exc:  # noqa: BLE001 - 网络异常
                last_error = f"{type(exc).__name__}: {exc}"
                if attempt == 0:
                    await asyncio.sleep(1.5)
                    continue
                raise ProviderError(f"{what}: 请求失败（{last_error}）") from exc
            if resp.status_code == 429:
                last_error = "HTTP 429 触发站点限流"
                if attempt == 0:
                    await asyncio.sleep(3.0)
                    continue
                raise ProviderError(f"{what}: {last_error}（已退避重试一次仍失败）")
            if resp.status_code >= 400:
                raise ProviderError(f"{what}: HTTP {resp.status_code} @ {url}")
            text = resp.text
            if BAN_MARK in text:
                # 站点以 HTTP 200 + 241 字节的封禁页响应，必须显式识别，否则会误判为「空榜」
                raise SiteAccessLimited("站点暂时限制当前出口网络访问")
            if len(text) < 1000:
                raise ProviderError(f"{what}: 榜单页异常（仅 {len(text)} 字节，可能是空榜或错误页）")
            return text
        raise ProviderError(f"{what}: 请求失败（{last_error}）")

    # ------------------------------------------------------------------
    def _book(self, channel: Channel, row: dict[str, Any], rank: int) -> Any:
        gid = str(row.get("gid") or "")
        token = str(row.get("token") or "")
        pages = row.get("pages")
        return self.make(
            channel,
            rank=rank,
            book_id=gid,
            title=row.get("title") or "",
            author=row.get("uploader") or "",
            cover=row.get("thumb") or "",
            intro="",
            category=row.get("category") or "",
            status="",
            word_count=f"{pages} 页" if pages else "",
            score=row.get("score") or "",
            url=f"{BASE}/g/{gid}/{token}/" if gid and token else "",
            extra={
                "gid": gid,
                "token": token,
                "pages": pages,
                "posted": row.get("posted"),
                "uploader": row.get("uploader"),
                "tags": row.get("tags") or [],
                "toplist_score": row.get("score"),
            },
        )


# ----------------------------------------------------------------------
async def _throttle() -> None:
    """全局最小请求间隔（≥1s），避免触发站点限流。"""
    global _last_request_at
    async with _rate_lock:
        now = time.monotonic()
        wait = MIN_INTERVAL - (now - _last_request_at)
        if wait > 0:
            await asyncio.sleep(wait)
        _last_request_at = time.monotonic()


def _text_of(node: Any) -> str:
    return re.sub(r"\s+", " ", node.get_text(" ", strip=True)).strip() if node is not None else ""


def _parse_toplists(html: str) -> list[dict[str, Any]]:
    """解析 toplist 页面表格；与搜索页共用 `table.itg.gltc tr` 选择器。"""
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(html, "html.parser")
    rows: list[dict[str, Any]] = []
    for tr in soup.select("table.itg.gltc tr"):
        link = tr.select_one("td.gl3c a[href]") or tr.select_one("a[href]")
        match = GID_PAT.search(link.get("href", "")) if link is not None else None
        if not match:
            continue
        gid, token = match.group(1), match.group(2)

        title_node = tr.select_one("div.glink")
        title = _text_of(title_node) or _text_of(link)

        cat_node = tr.select_one("td.gl1c .cn") or tr.select_one("div.cn")
        thumb_node = tr.select_one("td.gl2c img[src]")
        uploader_node = tr.select_one("td.gl4c a[href*='/uploader/']")

        pages = None
        for node in tr.select("td.gl4c div"):
            m = re.search(r"(\d+)\s+pages?", node.get_text(" ", strip=True), re.I)
            if m:
                pages = int(m.group(1))
                break
        if pages is None:
            m = re.search(r"(\d+)\s+pages?", tr.get_text(" ", strip=True), re.I)
            pages = int(m.group(1)) if m else None

        # 名次与榜单指标值：<td><p>#1</p><p>4,836,643</p></td>
        score = ""
        first_td = tr.find("td")
        if first_td is not None:
            ps = first_td.find_all("p")
            if len(ps) >= 2:
                score = ps[1].get_text(" ", strip=True)

        posted_node = tr.select_one(f"#posted_{gid}") or tr.select_one("td.gl2c div[id^='posted_']")

        rows.append(
            {
                "gid": gid,
                "token": token,
                "title": title,
                "category": _text_of(cat_node),
                "thumb": (thumb_node.get("src") or "").strip() if thumb_node is not None else "",
                "uploader": _text_of(uploader_node),
                "pages": pages,
                "score": score,
                "posted": _text_of(posted_node),
                "tags": [str(t.get("title") or _text_of(t)) for t in tr.select("td.gl3c .gt")],
            }
        )
    return rows


def _parse_total_pages(html: str, tl: int) -> int | None:
    """从分页条里取最大页码：`toplist.php?tl=..&p=199` 表示共 200 页。"""
    nums = [int(n) for n in re.findall(rf"toplist\.php\?tl={tl}&(?:amp;)?p=(\d+)", html)]
    return max(nums) + 1 if nums else None
