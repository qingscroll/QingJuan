"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

import asyncio
import re
import time
from typing import Any
from urllib.parse import unquote, urlencode

from bs4 import BeautifulSoup

from ..httpclient import UpstreamError
from ..utils import abs_url, clean, first_num, pick
from .base import BaseProvider, Channel, FetchResult, ProviderError, channel

BASE = "https://yanmaga.jp"
RANKING_URL = f"{BASE}/ranking"
HOME_URL = f"{BASE}/"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)

MIN_INTERVAL = 1.0  # 同站点请求最小间隔（秒）
PAGE_TTL = 120.0  # 页面解析结果的内存 TTL（秒）

# 榜单 tab：key -> data-tab-name（顺序即页面 DOM 顺序）
RANK_TABS: list[tuple[str, str]] = [
    ("rank_all", "総合"),
    ("rank_original", "オリジナル"),
    ("rank_sexy", "セクシー"),
    ("rank_isekai", "異世界"),
    ("rank_suspense", "サスペンス"),
    ("rank_outlaw", "アウトロー"),
    ("rank_drama", "ドラマ"),
    ("rank_oneshot", "読み切り"),
    ("rank_action", "アクション"),
    ("rank_horror", "ホラー"),
    ("rank_gag", "ギャグ"),
    ("rank_sports", "スポーツ"),
    ("rank_sf_fantasy", "SF・ファンタジー"),
    ("rank_media", "メディア化"),
    ("rank_gravure", "グラビア"),
]
TAB_BY_KEY = dict(RANK_TABS)

# トップページ 曜日別ランキング：key -> (見出しの曜日, 見出しSVGのアセット名)
WEEKDAYS: list[tuple[str, str, str]] = [
    ("rank_weekday_sun", "日曜日", "sunday"),
    ("rank_weekday_mon", "月曜日", "monday"),
    ("rank_weekday_tue", "火曜日", "tuesday"),
    ("rank_weekday_wed", "水曜日", "wednesday"),
    ("rank_weekday_thu", "木曜日", "thursday"),
    ("rank_weekday_fri", "金曜日", "friday"),
    ("rank_weekday_sat", "土曜日", "saturday"),
]
WEEKDAY_BY_KEY = {key: (label, asset) for key, label, asset in WEEKDAYS}

# トップページ特集架：key -> 站点自己的 h2 文案
FEATURE_SECTIONS: list[tuple[str, str]] = [
    ("recommend_feature_ad", "広告配信中の作品はコチラ！"),
    ("recommend_feature_first_free", "オススメの初回無料！"),
    ("recommend_feature_trending", "話題沸騰中の作品はコチラ！"),
    ("recommend_feature_free_serial", "【特報】人気連載作が無料で読める！"),
    ("recommend_feature_new_oneshot", "新作読み切りはコチラ"),
    ("recommend_feature_new_series", "今なら追いつける新連載！"),
]
FEATURE_BY_KEY = dict(FEATURE_SECTIONS)

_BOOK_PATH_RE = re.compile(r"/(?:comics|gravures/books)/(.+?)/?$")
_DATE_PREFIX_RE = re.compile(r"^\d{8}_")
_BADGE_CLASSES = {
    "free-cp",
    "first-free",
    "new",
    "app-only",
    "mod-book-original-badge-lg",
    "mod-book-original-badge-md",
}

# --------------------------------------------------------------------------
# 通道清单
# --------------------------------------------------------------------------
_CHANNELS: list[Channel] = [
    channel(
        key,
        f"{tab}ランキング",
        kind="rank",
        group="ランキング",
        description=f"yanmaga.jp/ranking 的「{tab}」榜单（data-tab-name={tab}，全部 tab 一次抓取）",
        pageable=False,
    )
    for key, tab in RANK_TABS
]
_CHANNELS += [
    channel(
        key,
        f"{label}のランキング",
        kind="rank",
        group="トップページ（曜日別）",
        description=f"トップページの「{label}のランキング」（見出しは画像アセット title_{asset}.svg）",
        pageable=False,
    )
    for key, label, asset in WEEKDAYS
]
_CHANNELS += [
    channel(
        "recommend_top_slider",
        "トップスライドショー",
        kind="recommend",
        group="トップページ推薦位",
        description="トップページ最上部の轮播（.mod-carousel-top，可能含广告位）",
        pageable=False,
    ),
    channel(
        "recommend_today_update",
        "本日の更新（マンガ）",
        kind="recommend",
        group="トップページ推薦位",
        description="トップページ「本日の更新」マンガ栏（.top-today-update-block 中 kind=マンガ 的一块）",
        pageable=False,
    ),
]
_CHANNELS += [
    channel(
        key,
        title,
        kind="recommend",
        group="トップページ推薦位",
        description=f"トップページ特集架「{title}」（section.mod-feature-banner，只保留解析到作品链接的条目）",
        pageable=False,
    )
    for key, title in FEATURE_SECTIONS
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
# HTML 工具
# --------------------------------------------------------------------------
def _text(node: Any) -> str:
    return clean(node.get_text(" ")) if node is not None else ""


def _plain(node: Any) -> str:
    """取文本，但跳过「無料CP中」这类角标 span（站点把角标混在正文里）。"""
    if node is None:
        return ""
    parts: list[str] = []
    for piece in node.find_all(string=True):
        parent = getattr(piece, "parent", None)
        classes = set(parent.get("class") or []) if parent is not None else set()
        if classes & _BADGE_CLASSES:
            continue
        parts.append(str(piece))
    return clean(" ".join(parts))


def _img(node: Any) -> str:
    if node is None:
        return ""
    return clean(pick(dict(node.attrs or {}), "data-src", "src", "data-original"))


def _num(value: Any) -> str:
    number = first_num(value)
    return "" if number is None else str(number)


def _book_id(href: str) -> str:
    """``/comics/{name}`` / ``/gravures/books/{name}/{hash}`` -> 作品 ID。"""
    match = _BOOK_PATH_RE.search((href or "").split("?")[0])
    return unquote(match.group(1)) if match else ""


def _is_book(href: str) -> bool:
    return bool(_BOOK_PATH_RE.search((href or "").split("?")[0]))


# --------------------------------------------------------------------------
# 解析器
# --------------------------------------------------------------------------
def _parse_ranking(html: str, tab: str) -> list[dict[str, Any]]:
    soup = BeautifulSoup(html, "html.parser")
    pane = None
    for candidate in soup.select("div.mod-ranking-v2-contents-item"):
        if clean(candidate.get("data-tab-name")) == tab:
            pane = candidate
            break
    if pane is None:
        return []
    rows: list[dict[str, Any]] = []
    for li in pane.select("li.mod-ranking-v2-item"):
        link = li.select_one("a.mod-ranking-v2-link")
        href = (link.get("href") if link is not None else "") or ""
        if not _is_book(href):
            continue
        image = li.select_one(".mod-ranking-v2-thumbnail-image img") or li.select_one("img")
        title = (
            _text(li.select_one("h3.mod-ranking-v2-title"))
            or clean(link.get("data-name"))
            or clean(image.get("alt") if image is not None else "")
        )
        rows.append(
            {
                "rank": first_num(link.get("data-rank")) or (len(rows) + 1),
                "book_id": _book_id(href),
                "title": title,
                "cover": _img(image),
                "intro": _plain(li.select_one("p.mod-ranking-v2-description")),
                "category": tab,
                "status": _plain(li.select_one("div.mod-ranking-v2-kind")),
                "url": abs_url(BASE, href),
                "extra": {"tab": tab, "source": RANKING_URL},
            }
        )
    return rows


def _parse_weekday(html: str, weekday: str) -> list[dict[str, Any]]:
    soup = BeautifulSoup(html, "html.parser")
    section = soup.select_one(f"div.mod-ranking-v3#ranking-v3-{weekday}")
    if section is None:
        # 退避：按見出し画像的资产名定位（title_sunday.svg 之类）
        for candidate in soup.select(".mod-ranking-v3"):
            image = candidate.select_one(".mod-ranking-v3-title-image-area img.weekday")
            if image is not None and f"title_{weekday}" in (image.get("src") or ""):
                section = candidate
                break
    if section is None:
        return []
    rows: list[dict[str, Any]] = []
    # 结构：<a class="mod-ranking-v3-item-link" data-rank data-name href><div class="mod-ranking-v3-item">…</div></a>
    for link in section.select("a.mod-ranking-v3-item-link"):
        if "ranking-banner" in (link.get("class") or []):
            continue
        href = link.get("href") or ""
        if not _is_book(href):
            continue
        item = link.select_one(".mod-ranking-v3-item")
        if item is None or "mod-ranking-v3-item-dummy" in (item.get("class") or []):
            continue
        thumb = item.select_one(".mod-ranking-v3-item-thumbnail img") or item.select_one("img")
        title = (
            _text(item.select_one(".mod-ranking-v3-item-title"))
            or clean((thumb.get("alt") if thumb is not None else "") or "")
            or clean(link.get("data-name"))
        )
        rows.append(
            {
                "rank": first_num(link.get("data-rank")) or (len(rows) + 1),
                "book_id": _book_id(href),
                "title": title,
                "cover": _img(thumb),
                "intro": _plain(item.select_one(".mod-ranking-v3-item-description")),
                "score": _num(_text(item.select_one(".mod-ranking-v3-item-like_count span"))),
                "url": abs_url(BASE, href),
                "extra": {"weekday": weekday, "source": HOME_URL},
            }
        )
    return rows


def _parse_slider(html: str) -> list[dict[str, Any]]:
    soup = BeautifulSoup(html, "html.parser")
    rows: list[dict[str, Any]] = []
    for link in soup.select(".mod-carousel-top a[href]"):
        href = link.get("href") or ""
        if not _is_book(href):
            continue
        image = link.select_one("img")
        title = (
            _text(link.select_one("h3, .mod-carousel-top-title"))
            or clean((image.get("alt") if image is not None else "") or "")
            or clean(link.get("data-name"))
        )
        rows.append(
            {
                "book_id": _book_id(href),
                # 轮播的 data-name / alt 带「20260909_」这类投放日期前缀，按站点展示名去掉
                "title": _DATE_PREFIX_RE.sub("", title),
                "cover": _img(image),
                "url": abs_url(BASE, href),
                "extra": {"section": "mod-carousel-top", "source": HOME_URL},
            }
        )
    return rows


def _parse_today(html: str, kind_name: str = "マンガ") -> list[dict[str, Any]]:
    soup = BeautifulSoup(html, "html.parser")
    for block in soup.select(".top-today-update-block"):
        if _text(block.select_one(".top-today-update-kind-title")) != kind_name:
            continue
        rows: list[dict[str, Any]] = []
        for link in block.select("a.mod-book-link"):
            href = link.get("href") or ""
            if not _is_book(href):
                continue
            image = link.select_one("img")
            rows.append(
                {
                    "book_id": _book_id(href),
                    "title": _text(link.select_one("h3.mod-book-title")) or _text(link.select_one("h3")),
                    "cover": _img(image),
                    "intro": _plain(link.select_one("p.mod-book-description")),
                    "status": _text(link.select_one(".mod-book-update, .mod-book-kind")),
                    "url": abs_url(BASE, href),
                    "extra": {"section": "top-today-update", "kind": kind_name, "source": HOME_URL},
                }
            )
        return rows
    return []


def _parse_feature(html: str, title: str) -> list[dict[str, Any]]:
    soup = BeautifulSoup(html, "html.parser")
    for section in soup.select("section.mod-feature-banner"):
        if _text(section.select_one(".mod-feature-banner-title")) != title:
            continue
        rows: list[dict[str, Any]] = []
        for li in section.select("li.mod-feature-banner-item"):
            link = li.select_one("a.mod-feature-banner-link") or li.select_one("a[href]")
            href = (link.get("href") if link is not None else "") or ""
            if not _is_book(href):
                continue
            image = li.select_one("img")
            rows.append(
                {
                    "book_id": _book_id(href),
                    "title": (
                        clean(link.get("data-name"))
                        or _text(li.select_one("h3"))
                        or clean((image.get("alt") if image is not None else "") or "")
                    ),
                    "cover": _img(image),
                    "intro": _plain(li.select_one("p, .mod-feature-banner-description")),
                    "url": abs_url(BASE, href),
                    "extra": {"section": title, "source": HOME_URL},
                }
            )
        return rows
    return []


class Provider(BaseProvider):
    site = "yanmaga"
    site_name = "ヤンマガWeb"
    content = "comic"
    homepage = BASE
    description = "ヤンマガWeb 公开页面：15 个ランキング tab（含グラビア）＋ トップページ曜日別ランキング / 本日の更新 / 特集推荐位"
    requires_login = False
    channels = tuple(_CHANNELS)
    ua = UA
    headers = {"Accept-Language": "ja,en;q=0.8", "Referer": BASE}

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

        if channel.key in TAB_BY_KEY:
            rows = _parse_ranking(
                await self._page(RANKING_URL), str(opts.get("tab") or TAB_BY_KEY[channel.key])
            )
        elif channel.key in WEEKDAY_BY_KEY:
            label, asset = WEEKDAY_BY_KEY[channel.key]
            rows = _parse_weekday(await self._page(HOME_URL), str(opts.get("weekday") or asset))
            if not rows:
                raise ProviderError(f"{channel.name}: トップページに「{label}のランキング」段落未找到")
        elif channel.key == "recommend_top_slider":
            rows = _parse_slider(await self._page(HOME_URL))
        elif channel.key == "recommend_today_update":
            rows = _parse_today(await self._page(HOME_URL))
        elif channel.key in FEATURE_BY_KEY:
            rows = _parse_feature(
                await self._page(HOME_URL), str(opts.get("section") or FEATURE_BY_KEY[channel.key])
            )
        else:
            raise ProviderError(f"未实现的通道: {channel.key}")

        if not rows:
            raise ProviderError(f"{channel.name}: 上游页面未解析到作品条目（页面结构可能已变更）")
        # 这些页面都是服务端一次性渲染的固定列表，`?page=` 不生效
        items = self.make_many(channel, rows[:limit])
        return FetchResult(items=items, has_more=False)

    # ------------------------------------------------------------------
    async def _page(self, url: str, params: dict[str, Any] | None = None) -> str:
        """抓页面（带 TTL 缓存：/ranking 的 15 个 tab 共用同一份 HTML）。"""
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
            if not html or "<html" not in html.lower():
                raise ProviderError(f"{self.site_name} 返回非 HTML 内容: {target}")
            if len(_page_cache) >= 64:
                _page_cache.pop(next(iter(_page_cache)))
            _page_cache[target] = (time.monotonic(), html)
            return html
