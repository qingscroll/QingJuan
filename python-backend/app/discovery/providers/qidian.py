"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

import asyncio
import json
import re
from typing import Any

from ..httpclient import MOBILE_UA, UpstreamError, decode
from ..utils import abs_url, clean, first_num, pick
from .base import BaseProvider, Channel, FetchResult, ProviderError, channel

BASE = "https://m.qidian.com"
COVER = "https://bookcover.yuewen.com/qdbimg/349573/{bid}/180"

# 榜单页 -> 接口 cgi 的映射（摘自 rankDetail 页面 JS）
_CGI_ALIAS = {"readindex": "readIndex"}

_SSR_RE = re.compile(r'<script id="vite-plugin-ssr_pageContext"[^>]*>(.*?)</script>', re.S)

# (key, 中文名, 接口 pageType, 分组, 性别)
_RANKS: list[tuple[str, str, str, str, str]] = [
    ("rank_yuepiao", "月票榜", "yuepiao", "男频", "male"),
    ("rank_hotsales", "热销榜", "hotsales", "男频", "male"),
    ("rank_rec", "推荐榜", "rec", "男频", "male"),
    ("rank_update", "更新榜", "update", "男频", "male"),
    ("rank_newbook", "新书榜", "newbook", "男频", "male"),
    ("rank_sign", "签约榜", "sign", "男频", "male"),
    ("rank_readindex", "阅读指数榜", "readindex", "男频", "male"),
    ("rank_newfans", "新增粉丝榜", "newfans", "男频", "male"),
    ("rank_newauthor", "新人作者榜", "newauthor", "男频", "male"),
    ("rank_yuepiao_female", "女频月票榜", "yuepiao", "女频", "female"),
    ("rank_collect_female", "女频收藏榜", "collect", "女频", "female"),
    ("rank_free_female", "女频免费榜", "free", "女频", "female"),
]

_CHANNELS: list[Channel] = [
    channel(
        key,
        name,
        kind="rank",
        group=group,
        description=f"m.qidian.com 榜单页 /rank/{page_type}/ + 接口 /webcommon/rank/{_CGI_ALIAS.get(page_type, page_type)}list"
        "（每页 20 条；可用 options 传 catId / yearmonth / rankPeriod 过滤）",
        params={"page_type": page_type, "gender": gender},
    )
    for key, name, page_type, group, gender in _RANKS
]


class Provider(BaseProvider):
    site = "qidian"
    site_name = "起点中文网"
    content = "novel"
    homepage = BASE
    description = (
        "起点移动站（m.qidian.com）公开榜单：月票/热销/推荐/更新/新书/签约/阅读指数/新增粉丝/新人作者榜 "
        "+ 女频月票/收藏/免费榜；支持分页与分类、月份过滤"
    )
    requires_login = False
    channels = tuple(_CHANNELS)

    ua = MOBILE_UA
    headers = {"Referer": "https://m.qidian.com/"}

    # 匿名 CSRF 令牌与当前 HTTP 会话绑定，不跨栏目请求共享。
    _token_lock: asyncio.Lock | None = None
    _token_loop: Any = None

    def __init__(self, http=None):
        super().__init__(http=http)
        self._token = ""

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
        gender = str(opts.get("gender") or "male")
        filtered = any(
            opts.get(key) not in (None, "", 0, "0") for key in ("catId", "yearmonth", "rankPeriod")
        )

        try:
            rows, is_last = await self._rank_api(channel, page, opts, gender)
        except (UpstreamError, ProviderError, ValueError) as exc:
            if page > 1 or gender != "male" or filtered:
                # 第 2 页起 / 女频 / 带过滤条件只能走接口：接口不可用时不返回任何数据
                raise ProviderError(f"{channel.name} 抓取失败：{exc}") from exc
            # 第 1 页回退到榜单页 SSR（接口被 CSRF 风控挡住时仍可用；
            # 注意 SSR 页面只渲染未过滤的第 1 页，故仅在上面的条件都不成立时使用）
            try:
                rows, is_last = await self._rank_ssr(channel, opts)
            except (UpstreamError, ProviderError, ValueError) as exc2:
                raise ProviderError(f"{channel.name} 抓取失败：接口 {exc}；SSR 回退 {exc2}") from exc2

        items = [self._book(channel, row) for row in rows[:limit]]
        return FetchResult(items=items, has_more=bool(rows) and not is_last, page_size=20)

    # ------------------------------------------------------------------
    # 接口（分页主路径）
    # ------------------------------------------------------------------
    async def _rank_api(
        self, channel: Channel, page: int, opts: dict[str, Any], gender: str
    ) -> tuple[list[dict[str, Any]], bool]:
        http = await self.client()
        page_type = str(opts.get("page_type") or "yuepiao")
        cgi = _CGI_ALIAS.get(page_type, page_type)
        params: dict[str, Any] = {
            "gender": gender,
            "pageNum": page,
            "_csrfToken": await self._csrf(),
        }
        for key in ("catId", "yearmonth", "rankPeriod"):
            value = opts.get(key)
            if value not in (None, "", 0, "0"):
                params[key] = value

        url = f"{BASE}/webcommon/rank/{cgi}list"
        data = await http.json(url, params=params)
        if isinstance(data, dict) and data.get("code") == 1403:
            # token 过期或被轮换：刷新一次再试
            params["_csrfToken"] = await self._csrf(refresh=True)
            data = await http.json(url, params=params)
        return self._parse_api(data, channel)

    def _parse_api(self, data: Any, channel: Channel) -> tuple[list[dict[str, Any]], bool]:
        if not isinstance(data, dict):
            raise ProviderError(f"{channel.name}: 接口返回体非对象")
        code = data.get("code")
        if code not in (0, None):
            raise ProviderError(f"{channel.name} 接口失败: code={code} msg={data.get('msg') or ''}")
        body = data.get("data") or {}
        rows = body.get("records") or []
        if not isinstance(rows, list):
            rows = []
        return rows, bool(body.get("isLast"))

    # ------------------------------------------------------------------
    # SSR 回退（仅第 1 页，且只有男频站点）
    # ------------------------------------------------------------------
    async def _rank_ssr(self, channel: Channel, opts: dict[str, Any]) -> tuple[list[dict[str, Any]], bool]:
        if str(opts.get("gender") or "male") != "male":
            raise ProviderError("女频榜单没有 SSR 页面（m.qdmm.com 被风控）")
        http = await self.client()
        page_type = str(opts.get("page_type") or "yuepiao")
        url = f"{BASE}/rank/{page_type}/"
        resp = await http.get(url)
        if resp.status_code >= 400:
            raise UpstreamError(f"HTTP {resp.status_code} @ {url}")
        self._remember_token(resp.cookies.get("_csrfToken", ""))
        ctx = _page_context(decode(resp))
        if ctx is None:
            raise ProviderError("榜单页未找到 vite-plugin-ssr_pageContext 数据")
        data = ((ctx.get("pageProps") or {}).get("pageData")) or {}
        rows = data.get("records") or []
        return (rows if isinstance(rows, list) else []), bool(data.get("isLast"))

    # ------------------------------------------------------------------
    # _csrfToken
    # ------------------------------------------------------------------
    async def _csrf(self, *, refresh: bool = False) -> str:
        """取 _csrfToken（GET 榜单页时由服务端下发，接口要求以 query 参数回传）。"""
        cls = type(self)
        lock = cls._lock()
        async with lock:
            if self._token and not refresh:
                return self._token
            http = await self.client()
            resp = await http.get(f"{BASE}/rank/")
            if resp.status_code >= 400:
                raise UpstreamError(f"HTTP {resp.status_code} @ {BASE}/rank/")
            self._remember_token(resp.cookies.get("_csrfToken", ""))
            return self._token

    def _remember_token(self, token: str) -> None:
        if token:
            # HTTP 会话由每次栏目请求创建，CSRF 必须与同一会话的 Cookie 配套。
            self._token = token

    @classmethod
    def _lock(cls) -> asyncio.Lock:
        """按事件循环复用同一把锁（异步客户端可能在多个 loop 中复用）。"""
        loop = asyncio.get_running_loop()
        if cls._token_lock is None or cls._token_loop is not loop:
            cls._token_lock = asyncio.Lock()
            cls._token_loop = loop
        return cls._token_lock

    # ------------------------------------------------------------------
    # 归一化
    # ------------------------------------------------------------------
    def _book(self, channel: Channel, raw: dict[str, Any]) -> Any:
        bid = str(pick(raw, "bid", "bookId", "book_id", default=""))
        cat = clean(raw.get("cat"))
        sub = clean(raw.get("subCat"))
        rank = first_num(raw.get("rankNum"), None)
        return self.make(
            channel,
            rank=rank,
            book_id=bid,
            title=clean(raw.get("bName") or raw.get("bookName")),
            author=clean(raw.get("bAuth") or raw.get("author")),
            cover=COVER.format(bid=bid) if bid else "",
            intro=clean(raw.get("desc")),
            category="·".join(part for part in (cat, sub) if part),
            status="",
            word_count=clean(raw.get("cnt")),
            score=clean(raw.get("rankCnt")),
            url=abs_url(BASE, f"/book/{bid}/") if bid else "",
            extra=dict(raw),
        )


def _page_context(html: str) -> dict[str, Any] | None:
    """解析 vite-plugin-ssr_pageContext 内嵌 JSON。"""
    m = _SSR_RE.search(html or "")
    if not m:
        return None
    try:
        data = json.loads(m.group(1))
    except ValueError:
        return None
    if not isinstance(data, dict):
        return None
    ctx = data.get("pageContext")
    return ctx if isinstance(ctx, dict) else data
