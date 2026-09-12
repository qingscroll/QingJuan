"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

import json
import re
import time
from typing import Any

from .base import BaseProvider, Channel, FetchResult, ProviderError, channel

SITE_URL = "https://18comic.vip"
PAGE_SIZE = 80

# 分类常量（与 jm_config.JmMagicConstants 一致，这里写死以免导入期依赖网络）
CATEGORY_ALL = "0"
CATEGORY_DOUJIN = "doujin"
CATEGORY_SINGLE = "single"
CATEGORY_SHORT = "short"
CATEGORY_ANOTHER = "another"
CATEGORY_HANMAN = "hanman"
CATEGORY_3D = "3D"
ORDER_BY_VIEW = "mv"
TIME_TODAY = "t"
TIME_WEEK = "w"
TIME_MONTH = "m"

CATEGORY_NAMES = {
    CATEGORY_ALL: "全部",
    CATEGORY_DOUJIN: "同人",
    CATEGORY_SINGLE: "單行本",
    CATEGORY_SHORT: "短篇",
    CATEGORY_ANOTHER: "其他",
    CATEGORY_HANMAN: "韓漫",
    CATEGORY_3D: "3D",
}

_CHANNELS: list[Channel] = [
    channel(
        "rank_day",
        "日榜",
        kind="rank",
        group="综合",
        description="近 24 小时观看数排行（/categories/filter?c=0&o=mv_t）",
        pageable=True,
    ),
    channel(
        "rank_week",
        "周榜",
        kind="rank",
        group="综合",
        description="近一周观看数排行（/categories/filter?c=0&o=mv_w）",
        pageable=True,
    ),
    channel(
        "rank_month",
        "月榜",
        kind="rank",
        group="综合",
        description="近一月观看数排行（/categories/filter?c=0&o=mv_m）",
        pageable=True,
    ),
    channel(
        "rank_day_doujin",
        "同人日榜",
        kind="rank",
        group="分类",
        description="同人分类近 24 小时观看数排行（c=doujin&o=mv_t）",
        pageable=True,
    ),
    channel(
        "rank_week_doujin",
        "同人周榜",
        kind="rank",
        group="分类",
        description="同人分类近一周观看数排行（c=doujin&o=mv_w）",
        pageable=True,
    ),
    channel(
        "rank_month_doujin",
        "同人月榜",
        kind="rank",
        group="分类",
        description="同人分类近一月观看数排行（c=doujin&o=mv_m）",
        pageable=True,
    ),
    channel(
        "rank_month_hanman",
        "韓漫月榜",
        kind="rank",
        group="分类",
        description="韓漫分类近一月观看数排行（c=hanman&o=mv_m）",
        pageable=True,
    ),
    channel(
        "rank_month_single",
        "單行本月榜",
        kind="rank",
        group="分类",
        description="單行本分类近一月观看数排行（c=single&o=mv_m）",
        pageable=True,
    ),
    channel(
        "rank_month_short",
        "短篇月榜",
        kind="rank",
        group="分类",
        description="短篇分类近一月观看数排行（c=short&o=mv_m）",
        pageable=True,
    ),
    channel(
        "rank_month_another",
        "其他月榜",
        kind="rank",
        group="分类",
        description="其他分类近一月观看数排行（c=another&o=mv_m）",
        pageable=True,
    ),
    channel(
        "rank_month_3d",
        "3D月榜",
        kind="rank",
        group="分类",
        description="3D 分类近一月观看数排行（c=3D&o=mv_m）",
        pageable=True,
    ),
]

# 通道 key -> (category, time)；time 为 None 表示「全部时间」
_RANK_PARAMS: dict[str, tuple[str, str | None]] = {
    "rank_day": (CATEGORY_ALL, TIME_TODAY),
    "rank_week": (CATEGORY_ALL, TIME_WEEK),
    "rank_month": (CATEGORY_ALL, TIME_MONTH),
    "rank_day_doujin": (CATEGORY_DOUJIN, TIME_TODAY),
    "rank_week_doujin": (CATEGORY_DOUJIN, TIME_WEEK),
    "rank_month_doujin": (CATEGORY_DOUJIN, TIME_MONTH),
    "rank_month_hanman": (CATEGORY_HANMAN, TIME_MONTH),
    "rank_month_single": (CATEGORY_SINGLE, TIME_MONTH),
    "rank_month_short": (CATEGORY_SHORT, TIME_MONTH),
    "rank_month_another": (CATEGORY_ANOTHER, TIME_MONTH),
    "rank_month_3d": (CATEGORY_3D, TIME_MONTH),
}

# 图片 CDN 兜底（取自 18comic 项目的 JM_IMAGE_FALLBACK_DOMAINS）
_FALLBACK_IMAGE_DOMAINS = [
    "cdn-msp.jmapiproxy1.cc",
    "cdn-msp2.jmapiproxy2.cc",
    "cdn-msp3.jmapiproxy2.cc",
]


def _image_domains() -> list[str]:
    try:
        from jmcomic import JmModuleConfig

        domains = [str(x).strip() for x in (JmModuleConfig.DOMAIN_IMAGE_LIST or []) if str(x).strip()]
        if domains:
            return domains
    except Exception:  # noqa: BLE001
        pass
    return _FALLBACK_IMAGE_DOMAINS


async def _api_domains(http) -> list[str]:
    from jmcomic import JmCryptoTool, JmMagicConstants, JmModuleConfig

    from ..cache import cache

    async def load() -> list[str]:
        for url in JmModuleConfig.API_URL_DOMAIN_SERVER_LIST:
            try:
                text = await http.text(url)
                text = text.lstrip("\ufeff\ufffe")
                body = json.loads(
                    JmCryptoTool.decode_resp_data(
                        text,
                        "",
                        JmMagicConstants.API_DOMAIN_SERVER_SECRET,
                    )
                )
                domains = [
                    domain
                    for domain in body.get("Server", [])
                    if isinstance(domain, str) and re.fullmatch(r"[A-Za-z0-9.-]+", domain)
                ][:8]
                if domains:
                    return domains
            except Exception:
                continue
        return list(JmModuleConfig.DOMAIN_API_LIST)

    domains, _ = await cache.get_or_load("jm18:api_domains", load)
    return domains


class Provider(BaseProvider):
    site = "jm18"
    site_name = "禁漫天堂"
    content = "comic"
    homepage = SITE_URL
    description = (
        "18comic（禁漫）移动端 API：日榜 / 周榜 / 月榜，以及同人、韓漫、單行本、短篇、"
        "其他、3D 分类榜；每页 80 条"
    )
    requires_login = False
    channels = tuple(_CHANNELS)

    @classmethod
    def client_kwargs(cls) -> dict[str, Any]:
        # 请求使用青卷公网 HTTP；jmcomic 仅用于本地签名与响应解密。
        return super().client_kwargs()

    # ------------------------------------------------------------------
    async def fetch(
        self,
        channel: Channel,
        page: int = 1,
        limit: int | None = None,
        options: dict | None = None,
    ) -> FetchResult:
        limit = self.resolve_limit(channel, limit)
        rank = _RANK_PARAMS.get(channel.key)
        if rank is None:
            raise ProviderError(f"未实现的通道: {channel.key}")
        category, time_range = rank
        opts = self.opts(channel, options)
        category = str(opts.get("category") or category)
        time_range = str(opts.get("time") or time_range)

        from jmcomic import JmCryptoTool, JmModuleConfig

        http = await self.client()
        rows = []
        total = 0
        for domain in await _api_domains(http):
            timestamp = str(int(time.time()))
            token, tokenparam = JmCryptoTool.token_and_tokenparam(timestamp)
            headers = {
                **JmModuleConfig.APP_HEADERS_TEMPLATE,
                "token": token,
                "tokenparam": tokenparam,
            }
            try:
                # 匿名 /setting 会下发必要的会话 Cookie，后续排行请求由同一 HTTP 会话发送。
                setting = await http.json(f"https://{domain}/setting", headers=headers)
                if setting.get("code") != 200 or not isinstance(setting.get("data"), str):
                    raise ProviderError("禁漫匿名会话初始化失败")
                setting_body = json.loads(JmCryptoTool.decode_resp_data(setting["data"], timestamp))
                version = str(setting_body.get("jm3_version") or "")
                if re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){1,3}", version):
                    token, tokenparam = JmCryptoTool.token_and_tokenparam(timestamp, ver=version)
                    headers.update(token=token, tokenparam=tokenparam)
                payload = await http.json(
                    f"https://{domain}/categories/filter",
                    params={"page": page, "order": "", "c": category, "o": f"{ORDER_BY_VIEW}_{time_range}"},
                    headers=headers,
                )
                if payload.get("code") != 200 or not isinstance(payload.get("data"), str):
                    raise ProviderError("禁漫排行数据暂时不可用")
                body = json.loads(JmCryptoTool.decode_resp_data(payload["data"], timestamp))
                rows = [(row.get("id"), row) for row in body.get("content", []) if isinstance(row, dict)]
                total = int(body.get("total") or 0)
                break
            except Exception as error:
                last_error = error
        else:
            raise ProviderError("禁漫排行暂时无法连接，请稍后重试") from last_error
        page_count = (total + PAGE_SIZE - 1) // PAGE_SIZE
        if page > max(page_count, 1):
            # 站点对超出总页数的请求会重复返回首页，不能给重复内容编造后续名次。
            return FetchResult(items=[], has_more=False)
        base_rank = (page - 1) * PAGE_SIZE
        items = [
            self._book(channel, index, album_id, meta)
            for index, (album_id, meta) in enumerate(rows[:limit], start=base_rank + 1)
        ]
        return FetchResult(items=items, has_more=bool(page_count and page < page_count))

    # ------------------------------------------------------------------
    def _book(self, channel: Channel, rank: int, album_id: Any, meta: Any) -> Any:
        meta = meta if isinstance(meta, dict) else {}
        aid = str(album_id or meta.get("id") or "").strip()
        cover = str(meta.get("image") or "").strip()
        if not cover and aid:
            cover = f"https://{_image_domains()[0]}/media/albums/{aid}_3x4.jpg"
        category = self._title_of(meta.get("category")) or self._title_of(meta.get("category_sub"))
        sub = self._title_of(meta.get("category_sub"))
        tags = meta.get("tags") or []
        if isinstance(tags, list) and tags and isinstance(tags[0], dict):
            tags = [t.get("name") or t.get("title") or "" for t in tags]
        return self.make(
            channel,
            rank=rank,
            book_id=aid,
            title=str(meta.get("name") or ""),
            author=str(meta.get("author") or ""),
            cover=cover,
            intro=str(meta.get("description") or ""),
            category=category,
            status="",
            word_count="",
            score="",
            url=f"{SITE_URL}/album/{aid}/" if aid else "",
            extra={
                "album_id": aid,
                "category_sub": sub,
                "tags": tags,
                "adddate": meta.get("adddate"),
                "update_at": meta.get("update_at"),
                "raw": meta,
            },
        )

    @staticmethod
    def _title_of(value: Any) -> str:
        if isinstance(value, dict):
            return str(value.get("title") or "")
        return str(value or "")
