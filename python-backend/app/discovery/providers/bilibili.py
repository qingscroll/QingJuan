"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

from typing import Any

from ..config import settings
from ..httpclient import DEFAULT_UA
from .base import BaseProvider, Channel, FetchResult, ProviderError, channel

BASE = "https://manga.bilibili.com"
TWIRP = f"{BASE}/twirp/comic.v1.Comic"
CHROME_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


def _cookie_dict(raw: str) -> dict[str, str]:
    """把 "k=v; k2=v2" 形式的 cookie 串解析成 dict。"""
    out: dict[str, str] = {}
    for part in (raw or "").split(";"):
        if "=" in part:
            key, _, value = part.partition("=")
            if key.strip():
                out[key.strip()] = value.strip()
    return out


# 取自 ListRank 实测返回（id -> (通道 key, 中文名, 分组, 官方说明)）
_RANK_DEFS: list[tuple[int, str, str, str, str]] = [
    (0, "rank_jp", "日漫榜", "综合", "前7日人气最高的日漫作品排行，每日更新"),
    (1, "rank_cn", "国漫榜", "综合", "前7日人气最高的国漫作品排行，每日更新"),
    (2, "rank_kr", "韩漫榜", "综合", "前7日人气最高的韩漫作品排行，每日更新"),
    (5, "rank_treasure", "宝藏榜", "综合", "前7日人气最高的官方精选漫画作品排行，每日更新"),
    (7, "rank_new", "新作榜", "综合", "前7日综合指标最高的三个月内上线漫画作品排行"),
    (11, "rank_male", "男生榜", "男频", "前7日综合指标最高的男性向漫画作品排行"),
    (12, "rank_female", "女生榜", "女频", "前7日综合指标最高的女性向漫画作品排行"),
    (13, "rank_finished", "完结榜", "综合", "前365日综合指标最高的完结漫画作品排行"),
    (33, "rank_original", "原创榜", "综合", "前7日人气最高的漫画人原创作品排行"),
]

_RANK_IDS: dict[str, int] = {key: rid for rid, key, _, _, _ in _RANK_DEFS}

_CHANNELS: list[Channel] = [
    channel(
        key,
        name,
        kind="rank",
        group=group,
        description=(f'{desc}（POST /twirp/comic.v1.Comic/GetRankInfo，body {{"id": {rid}}}，固定 50 条）'),
        params={"rank_id": rid},
        pageable=False,
    )
    for rid, key, name, group, desc in _RANK_DEFS
] + [
    channel(
        "home_hot",
        "首页热门位",
        kind="recommend",
        group="首页推荐位",
        description="首页热门漫画（POST /twirp/comic.v1.Comic/HomeHot，固定 34 条）",
        pageable=False,
    ),
]

RANK_NAMES = {key: name for _, key, name, _, _ in _RANK_DEFS}


class Provider(BaseProvider):
    site = "bilibili"
    site_name = "哔哩哔哩漫画"
    content = "comic"
    homepage = f"{BASE}/ranking"
    description = (
        "bilibili 漫画 twirp 公开接口：9 个官方排行榜（日漫/国漫/韩漫/宝藏/新作/男生/"
        "女生/完结/原创，各 50 条）+ 首页热门位；均匿名可取"
    )
    requires_login = False
    headers = {
        "Referer": f"{BASE}/",
        "Origin": BASE,
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Connection": "keep-alive",
    }
    ua = CHROME_UA

    channels = tuple(_CHANNELS)

    @classmethod
    def client_kwargs(cls) -> dict[str, Any]:
        kwargs = super().client_kwargs()
        kwargs["ua"] = cls.ua or DEFAULT_UA
        sessdata = (settings.bilibili_sessdata or "").strip()
        if sessdata:
            cookies = dict(kwargs.get("cookies") or {})
            cookies.update(_cookie_dict(sessdata) or {"SESSDATA": sessdata})
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
        if channel.key == "home_hot":
            return await self._home_hot(channel, limit)
        rank_id = opts.get("rank_id", _RANK_IDS.get(channel.key))
        if rank_id is None:
            raise ProviderError(f"未实现的通道: {channel.key}")
        return await self._rank_info(channel, int(rank_id), limit)

    # ------------------------------------------------------------------
    async def _rank_info(self, channel: Channel, rank_id: int, limit: int) -> FetchResult:
        http = await self.client()
        data = await self._post(http, "GetRankInfo", {"id": rank_id}, channel.name)
        if not isinstance(data, dict):
            raise ProviderError(f"{channel.name}: GetRankInfo 返回体非对象")
        rows = data.get("list") or []
        if not rows:
            raise ProviderError(f"{channel.name}: GetRankInfo 返回空榜单（rank_id={rank_id}）")
        rank_title = str(data.get("title") or channel.name)
        rank_desc = str(data.get("description") or "")
        items = [
            self._book(
                channel,
                row,
                rank=index,
                extra={"rank_title": rank_title, "rank_description": rank_desc, "rank_id": rank_id},
            )
            for index, row in enumerate(rows[:limit], start=1)
        ]
        # 榜单固定 50 条，上游忽略分页参数
        return FetchResult(items=items, has_more=False)

    async def _home_hot(self, channel: Channel, limit: int) -> FetchResult:
        http = await self.client()
        data = await self._post(http, "HomeHot", {}, channel.name)
        rows = data if isinstance(data, list) else (data or {}).get("list") or []
        if not rows:
            raise ProviderError(f"{channel.name}: HomeHot 返回空列表")
        items = [self._book(channel, row) for row in rows[:limit]]
        return FetchResult(items=items, has_more=False)

    # ------------------------------------------------------------------
    async def _post(self, http: Any, method: str, body: dict[str, Any], what: str) -> Any:
        try:
            payload = await http.json_post(f"{TWIRP}/{method}", json_body=dict(body))
        except Exception as exc:  # noqa: BLE001 - 上游网络 / 非 JSON
            raise ProviderError(f"{what}: 请求 {method} 失败（{type(exc).__name__}: {exc}）") from exc
        if not isinstance(payload, dict):
            raise ProviderError(f"{what}: {method} 返回体非对象")
        code = payload.get("code")
        if code not in (0, None):
            raise ProviderError(
                f"{what}: {method} 失败 code={code} msg={payload.get('msg') or payload.get('message')}"
            )
        return payload.get("data")

    # ------------------------------------------------------------------
    def _book(self, channel: Channel, raw: Any, **overrides: Any) -> Any:
        raw = raw if isinstance(raw, dict) else {}
        cid = str(raw.get("comic_id") or raw.get("id") or "").strip()
        authors = raw.get("author")
        if isinstance(authors, list):
            author = "、".join(str(a).strip() for a in authors if str(a).strip())
        else:
            author = str(authors or "")
        styles = raw.get("styles") or []
        style_names = [str(s.get("name") or "").strip() for s in styles if isinstance(s, dict)]
        tags = raw.get("tags") or []
        if not isinstance(tags, list):
            tags = []
        fans = raw.get("fans")
        total = raw.get("total")

        raw_extra: dict[str, Any] = {
            "comic_id": cid,
            "tags": tags,
            "styles": style_names,
            "total": total,
            "last_ord": raw.get("last_ord"),
            "last_short_title": raw.get("last_short_title"),
            "last_rank": raw.get("last_rank"),
            "is_finish": raw.get("is_finish"),
            "raw": raw,
        }
        fields: dict[str, Any] = {
            "book_id": cid,
            "title": str(raw.get("title") or ""),
            "author": author,
            "cover": str(raw.get("vertical_cover") or ""),
            "intro": str(raw.get("comic_introduction") or raw.get("text") or ""),
            "category": "、".join(n for n in style_names if n),
            "status": "已完结" if raw.get("is_finish") else "连载中",
            "word_count": f"全{total}话" if total else "",
            "score": str(fans) if fans not in (None, "") else "",
            "url": f"{BASE}/detail/mc{cid}" if cid else "",
            "extra": raw_extra,
        }
        fields.update(overrides)
        extra = dict(raw_extra)
        extra.update(overrides.pop("extra", None) or {})
        fields["extra"] = extra
        return self.make(channel, **fields)
