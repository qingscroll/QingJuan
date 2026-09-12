"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

from typing import Any

from .base import BaseProvider, Channel, FetchResult, ProviderError, channel

BASE = "https://www.comicores.cc"
REST = f"{BASE}/wp-json/wp/v2"

# 站点真实分类（parent=3 二次元 之下的内容分类，非作者分类）
CATEGORIES: list[tuple[int, str, str]] = [
    (4, "cat_jp", "日本漫画"),
    (7, "cat_cn", "华语漫画"),
    (6, "cat_jp_raw", "日文漫画"),
    (81, "cat_west", "欧美漫画"),
]
# 内容分类 id 集合；其余挂在该 post 上的分类（84 日本漫画家 / 331 华语漫画家 之下）
# 即作者分类，用作 BookItem.author
CONTENT_CATEGORY_IDS = {cid for cid, _key, _name in CATEGORIES}

# 站点真实题材 tag（id -> 中文名），取自 /wp-json/wp/v2/tags?orderby=count
TAGS: list[tuple[int, str, str]] = [
    (29, "冒险", "tag_adventure"),
    (46, "奇幻", "tag_wonder"),
    (24, "搞笑", "tag_amuse"),
    (25, "恋爱", "tag_love"),
    (36, "校园", "tag_campus"),
    (307, "打斗", "tag_action"),
    (60, "少女", "tag_girl"),
    (44, "科幻", "tag_scifi"),
    (265, "社会", "tag_society"),
    (34, "日常", "tag_life"),
    (26, "竞技", "tag_sports"),
    (32, "悬疑", "tag_cliffhang"),
    (52, "后宫", "tag_harem"),
    (175, "时代剧", "tag_period"),
    (37, "职场", "tag_career"),
    (35, "励志", "tag_encourage"),
]

_CHANNELS: list[Channel] = (
    [
        channel(
            "latest",
            "最新更新",
            kind="rank",
            group="综合",
            description="按发布时间倒序（orderby=date&order=desc，WP REST 默认排序）",
            pageable=True,
        ),
        channel(
            "updated",
            "最近修改",
            kind="rank",
            group="综合",
            description="按最近修改时间倒序（orderby=modified&order=desc）",
            pageable=True,
        ),
    ]
    + [
        channel(
            key,
            f"分类·{name}",
            kind="rank",
            group="分类",
            description=f"WordPress 内容分类「{name}」（categories={cid}），按发布时间倒序；上游无该分类的独立排行榜接口",
            params={"categories": cid},
            pageable=True,
        )
        for cid, key, name in CATEGORIES
    ]
    + [
        channel(
            key,
            f"题材·{name}",
            kind="rank",
            group="题材",
            description=f"题材标签「{name}」（tags={tid}），按发布时间倒序；上游无该题材的独立排行榜接口",
            params={"tags": tid},
            pageable=True,
        )
        for tid, name, key in TAGS
    ]
)


class Provider(BaseProvider):
    site = "ores"
    site_name = "COMICORES 漫核"
    content = "comic"
    homepage = BASE
    description = (
        "COMICORES（WordPress）公开 REST：最新更新 / 最近修改，以及 4 个内容分类与 16 个"
        "题材标签的分类榜；orderby=comment_count 与 meta_value_num 均被上游 400 拒绝，"
        "故无热评榜 / 浏览榜"
    )
    requires_login = False
    headers = {
        "Accept": "application/json, text/plain, */*",
        "Referer": f"{BASE}/",
    }
    channels = tuple(_CHANNELS)

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

        params: dict[str, Any] = {
            "per_page": limit,
            "page": page,
            "_embed": 1,
        }
        if channel.key == "updated":
            params.update({"orderby": "modified", "order": "desc"})
        elif channel.key == "latest":
            params.update({"orderby": "date", "order": "desc"})
        else:
            params.update({"orderby": "date", "order": "desc"})
            if opts.get("categories"):
                params["categories"] = int(opts["categories"])
            if opts.get("tags"):
                params["tags"] = int(opts["tags"])

        http = await self.client()
        try:
            resp = await http.get(f"{REST}/posts", params=params)
        except Exception as exc:  # noqa: BLE001 - 网络异常
            raise ProviderError(f"{channel.name}: 请求失败（{type(exc).__name__}: {exc}）") from exc
        if resp.status_code >= 400:
            raise ProviderError(
                f"{channel.name}: HTTP {resp.status_code} @ /wp-json/wp/v2/posts {resp.text[:160]}"
            )
        try:
            rows = resp.json()
        except ValueError as exc:
            raise ProviderError(f"{channel.name}: 非 JSON 响应（{resp.text[:120]!r}）") from exc
        if not isinstance(rows, list):
            raise ProviderError(f"{channel.name}: 返回体非列表")
        if not rows:
            raise ProviderError(f"{channel.name}: 上游返回空列表")

        total_pages = _int_or_none(resp.headers.get("X-WP-TotalPages"))
        base_rank = (page - 1) * limit
        items = [
            self._book(channel, row, base_rank + index) for index, row in enumerate(rows[:limit], start=1)
        ]
        has_more = page < total_pages if total_pages else len(rows) >= limit
        return FetchResult(items=items, has_more=has_more)

    # ------------------------------------------------------------------
    def _book(self, channel: Channel, raw: Any, rank: int) -> Any:
        raw = raw if isinstance(raw, dict) else {}
        fields = _normalise_post(raw)
        return self.make(
            channel,
            rank=rank,
            book_id=fields["book_id"],
            title=fields["title"],
            author=fields["author"],
            cover=fields["cover"],
            intro=fields["intro"],
            category=fields["category"],
            status=fields["status"],
            word_count="",
            score="",
            url=fields["url"],
            extra={
                "post_id": fields["book_id"],
                "slug": raw.get("slug"),
                "date": raw.get("date"),
                "modified": raw.get("modified"),
                "categories": raw.get("categories") or [],
                "tags": raw.get("tags") or [],
                "category_names": fields["category_names"],
                "author_names": fields["author_names"],
                "tag_names": fields["tag_names"],
                "featured_media": raw.get("featured_media"),
            },
        )


# ----------------------------------------------------------------------
def _normalise_post(raw: dict[str, Any]) -> dict[str, Any]:
    """把 WP REST 的 post 对象拍平成 BookItem 需要的字段。"""
    import re

    from ..utils import clean, trim

    embedded = raw.get("_embedded") or {}

    title = clean(
        ((raw.get("title") or {}) if isinstance(raw.get("title"), dict) else {}).get("rendered") or ""
    )

    cover = ""
    for media in embedded.get("wp:featuredmedia") or []:
        if isinstance(media, dict) and media.get("source_url"):
            cover = str(media["source_url"]).strip()
            break

    category_names: list[str] = []
    author_names: list[str] = []
    tag_names: list[str] = []
    # _embedded['wp:term'] 是 [ [分类…], [标签…] ] 的形式
    for group in embedded.get("wp:term") or []:
        for term in group or []:
            if not isinstance(term, dict):
                continue
            name = clean(term.get("name") or "")
            if not name:
                continue
            if term.get("taxonomy") == "post_tag":
                if name not in tag_names:
                    tag_names.append(name)
            elif term.get("id") in CONTENT_CATEGORY_IDS:
                if name not in category_names:
                    category_names.append(name)
            elif name not in author_names:
                # 84 日本漫画家 / 331 华语漫画家 之下的分类即作者
                author_names.append(name)

    # _embed 不可用时退回 categories id（用本模块已实测的分类表映射）
    if not category_names:
        cat_map = {cid: name for cid, _key, name in CATEGORIES}
        category_names = [cat_map[c] for c in (raw.get("categories") or []) if c in cat_map]

    intro = clean(
        ((raw.get("excerpt") or {}) if isinstance(raw.get("excerpt"), dict) else {}).get("rendered") or ""
    )
    if not intro:
        content = ((raw.get("content") or {}) if isinstance(raw.get("content"), dict) else {}).get(
            "rendered"
        ) or ""
        intro = trim(re.sub(r"<[^>]+>", " ", content), 180)

    link = str(raw.get("link") or "").strip()
    return {
        "book_id": str(raw.get("id") or ""),
        "title": title,
        "author": "、".join(author_names),
        "cover": cover,
        "intro": intro,
        "category": "、".join(category_names),
        "status": "",
        "url": link,
        "category_names": category_names,
        "author_names": author_names,
        "tag_names": tag_names,
    }


def _int_or_none(value: Any) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None
