"""内置站点推荐与排行解析，移植自 all_book_order。"""

from __future__ import annotations

import asyncio
import time
from typing import Any

from ..httpclient import UpstreamError
from ..utils import clean, pick, trim
from .base import BaseProvider, Channel, FetchResult, ProviderError, channel

BASE = "https://kakuyomu.jp"
GRAPHQL = f"{BASE}/graphql"
WORKS = f"{BASE}/works"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
)

# 游标翻页只能逐页推进，给一个上限避免调用方传入超大页码时狂打上游
MAX_PAGE = 20
# 站点有 WAF：同站点请求最小间隔（秒）
MIN_INTERVAL = 0.4

PERIODS: list[tuple[str, str]] = [
    ("DAILY", "日間"),
    ("WEEKLY", "週間"),
    ("MONTHLY", "月間"),
    ("YEARLY", "年間"),
    ("ENTIRE", "全期間"),
]
PERIOD_NAMES = dict(PERIODS)
PERIOD_BY_NUMBER = {name: code for code, name in PERIODS}  # 允许 options 传「週間」这类日文名

GENRES: list[tuple[str, str]] = [
    ("FANTASY", "異世界ファンタジー"),
    ("ACTION", "現代ファンタジー"),
    ("LOVE_STORY", "恋愛"),
    ("ROMANCE", "ラブコメ"),
    ("SF", "SF"),
    ("MYSTERY", "ミステリー"),
    ("HORROR", "ホラー"),
    ("DRAMA", "現代ドラマ"),
    ("HISTORY", "歴史・時代・伝奇"),
    ("NONFICTION", "エッセイ・ノンフィクション"),
    ("CRITICISM", "創作論・評論"),
    ("OTHERS", "詩・童話・その他"),
]
GENRE_NAMES = dict(GENRES)
GENRE_BY_LABEL = {label: code for code, label in GENRES}

VARIATIONS = {"ALL": "すべて", "SHORT": "短編", "LONG": "長編"}

# serialStatus 实测枚举：RUNNING / COMPLETED
SERIAL_STATUS = {"RUNNING": "連載中", "COMPLETED": "完結", "SUSPENDED": "休載中", "DRAFT": "非公開"}

QUERY_RANKED = """
query RankedWorks(
  $first: Int!
  $period: WorkRankingScore_Key_Period!
  $variation: WorkRankingScore_WorkVariation!
  $genre: Work_Genre
  $after: String
) {
  rankedWorks(first: $first, after: $after, period: $period, workVariation: $variation, genre: $genre) {
    nodes {
      id
      title
      catchphrase
      introduction
      tagLabels
      genre
      serialStatus
      publicEpisodeCount
      totalCharacterCount
      totalFollowers
      totalReviewPoint
      publishedAt
      lastEpisodePublishedAt
      ogImageUrl
      adminCoverImageUrl
      author { id name activityName screenName }
    }
    pageInfo { hasNextPage hasPreviousPage endCursor }
  }
}
"""

QUERY_PICKUP = """
query RankingPickup($limit: Int!) {
  rankingPromotionSlots(limit: $limit) {
    __typename
    ... on NextRankingPromotionSlot { work { ...PickupWork } }
    ... on MediaFranchisedRankingPromotionSlot {
      work { ...PickupWork }
      mediaFranchisedWork { id title kind slug }
    }
  }
}

fragment PickupWork on Work {
  id
  title
  catchphrase
  introduction
  tagLabels
  genre
  serialStatus
  totalFollowers
  totalReviewPoint
  ogImageUrl
  adminCoverImageUrl
  author { id name activityName screenName }
}
"""

# --------------------------------------------------------------------------
# 通道清单
# --------------------------------------------------------------------------
_CHANNELS: list[Channel] = [
    channel(
        f"rank_overall_{period.lower()}",
        f"【総合】{label}の長編ランキング",
        kind="rank",
        group="総合",
        description=f"rankedWorks(period={period}, workVariation=LONG)；网页入口 /rankings/all/{period.lower()}",
        params={"period": period, "variation": "LONG"},
    )
    for period, label in PERIODS
]
_CHANNELS.append(
    channel(
        "rank_overall_weekly_short",
        "【総合】週間の短編ランキング",
        kind="rank",
        group="総合",
        description="短編（workVariation=SHORT）；网页入口 /rankings/all/weekly?work_variation=short",
        params={"period": "WEEKLY", "variation": "SHORT"},
    )
)
for _genre, _label in GENRES:
    _CHANNELS.append(
        channel(
            f"rank_genre_{_genre.lower()}",
            f"【{_label}】週間の長編ランキング",
            kind="rank",
            group="ジャンル別",
            description=f"rankedWorks(genre={_genre}, period=WEEKLY, workVariation=LONG)；"
            f"网页入口 /rankings/{_genre.lower()}/weekly",
            params={"genre": _genre, "period": "WEEKLY", "variation": "LONG"},
        )
    )
_CHANNELS.append(
    channel(
        "recommend_pickup",
        "ランキングページ ピックアップ枠",
        kind="recommend",
        group="推薦枠",
        description="rankingPromotionSlots(limit=N)：カクヨム在ランキング页投放的推荐位"
        "（NextRankingPromotionSlot / MediaFranchisedRankingPromotionSlot），每次请求内容随机",
        pageable=False,
    )
)

GENRE_KEYS = {f"rank_genre_{code.lower()}": code for code, _ in GENRES}


# --------------------------------------------------------------------------
# 限速
# --------------------------------------------------------------------------
_rate_lock = asyncio.Lock()
_last_call = 0.0


async def _throttle() -> None:
    """同站点请求间隔 ≥ MIN_INTERVAL（カクヨム 有 WAF，间隔过短会 403）。"""
    global _last_call
    async with _rate_lock:
        gap = MIN_INTERVAL - (time.monotonic() - _last_call)
        if gap > 0:
            await asyncio.sleep(gap)
        _last_call = time.monotonic()


class Provider(BaseProvider):
    site = "kakuyomu"
    site_name = "カクヨム"
    content = "novel"
    homepage = BASE
    description = "カクヨム公開 GraphQL：総合 / ジャンル別ランキング（日間・週間・月間・年間・全期間、長編・短編）＋ランキング推荐枠"
    requires_login = False
    channels = tuple(_CHANNELS)
    ua = UA
    headers = {
        "Accept-Language": "ja,en;q=0.8",
        "apollographql-client-name": "kakuyomu-web",
        "apollographql-client-version": "1.0.0",
        "Origin": BASE,
        "Referer": f"{BASE}/rankings/all/weekly",
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
        if channel.key.startswith("rank_"):
            return await self._ranked(channel, page, limit, opts)
        if channel.key == "recommend_pickup":
            return await self._pickup(channel, limit)
        raise ProviderError(f"未实现的通道: {channel.key}")

    # ------------------------------------------------------------------
    async def _ranked(self, channel: Channel, page: int, limit: int, opts: dict[str, Any]) -> FetchResult:
        period = self._period(opts.get("period"))
        variation = str(opts.get("variation") or "LONG").upper()
        if variation not in VARIATIONS:
            raise ProviderError(f"{channel.name}: 未知的 workVariation={variation}")
        genre = opts.get("genre") or None
        if genre is not None:
            genre = str(genre).upper()
            if genre not in GENRE_NAMES:
                raise ProviderError(f"{channel.name}: 未知的 genre={genre}")

        target = max(1, int(page))
        if target > MAX_PAGE:
            raise ProviderError(
                f"{channel.name}: 上游为游标分页，本 Provider 逐页推进，最大支持第 {MAX_PAGE} 页"
            )

        nodes: list[dict[str, Any]] = []
        has_more = False
        reached = 1
        after: str | None = None
        for index in range(1, target + 1):
            variables: dict[str, Any] = {
                "first": limit,
                "period": period,
                "variation": variation,
                "genre": genre,
            }
            if after:
                variables["after"] = after
            connection = await self._ranked_connection(variables, channel.name)
            nodes = connection.get("nodes") or []
            info = connection.get("pageInfo") or {}
            has_more = bool(info.get("hasNextPage"))
            after = info.get("endCursor") or None
            reached = index
            if not has_more:
                break

        base = (reached - 1) * limit + 1
        items = [self._book(channel, node, rank=base + offset) for offset, node in enumerate(nodes)]
        return FetchResult(items=items, has_more=has_more)

    async def _pickup(self, channel: Channel, limit: int) -> FetchResult:
        data = await self._graphql(QUERY_PICKUP, {"limit": min(limit, 30)}, channel.name)
        slots = (data.get("data") or {}).get("rankingPromotionSlots") or []
        rows: list[dict[str, Any]] = []
        for slot in slots[:limit]:
            work = slot.get("work") or {}
            if not work.get("id"):
                continue
            rows.append(
                {
                    "slot": slot.get("__typename") or "",
                    "media_franchised_work": slot.get("mediaFranchisedWork") or None,
                    "work": work,
                }
            )
        if not rows:
            raise ProviderError(f"{channel.name}: 上游未返回推荐位")
        items = [
            self._book(
                channel,
                row["work"],
                rank=index,
                extra={
                    "slot": row["slot"],
                    "media_franchised_work": row["media_franchised_work"],
                    "work": row["work"],
                },
            )
            for index, row in enumerate(rows, start=1)
        ]
        return FetchResult(items=items, has_more=False)

    # ------------------------------------------------------------------
    async def _ranked_connection(self, variables: dict[str, Any], what: str) -> dict[str, Any]:
        data = await self._graphql(QUERY_RANKED, variables, what)
        connection = (data.get("data") or {}).get("rankedWorks")
        if not isinstance(connection, dict):
            raise ProviderError(f"{what}: 返回体缺少 rankedWorks")
        return connection

    async def _graphql(self, query: str, variables: dict[str, Any], what: str) -> dict[str, Any]:
        http = await self.client()
        await _throttle()
        try:
            data = await http.json(GRAPHQL, method="POST", json={"query": query, "variables": variables})
        except UpstreamError as exc:
            raise ProviderError(f"{what}: カクヨム GraphQL 请求失败（{exc}）") from exc
        if not isinstance(data, dict):
            raise ProviderError(f"{what}: 返回体非对象")
        errors = data.get("errors")
        if errors:
            first = errors[0] if isinstance(errors, list) and errors else {}
            message = first.get("message") if isinstance(first, dict) else str(first)
            raise ProviderError(f"{what}: カクヨム GraphQL 报错：{message}")
        if data.get("data") is None:
            raise ProviderError(f"{what}: カクヨム GraphQL 返回空 data")
        return data

    # ------------------------------------------------------------------
    @staticmethod
    def _period(value: Any) -> str:
        text = str(value or "WEEKLY").strip()
        upper = text.upper()
        if upper in PERIOD_NAMES:
            return upper
        if text in PERIOD_BY_NUMBER:
            return PERIOD_BY_NUMBER[text]
        raise ProviderError(f"未知的期间 period={value}（可用：{', '.join(PERIOD_NAMES)}）")

    def _book(self, channel: Channel, node: dict[str, Any], **overrides: Any) -> Any:
        work_id = str(node.get("id") or "")
        author = node.get("author") if isinstance(node.get("author"), dict) else {}
        genre = str(node.get("genre") or "")
        fields: dict[str, Any] = {
            "book_id": work_id,
            "title": clean(node.get("title")),
            "author": clean(pick(author, "activityName", "name", "screenName")),
            "cover": clean(pick(node, "ogImageUrl", "adminCoverImageUrl")),
            "intro": trim(pick(node, "catchphrase", "introduction"), 200),
            "category": GENRE_NAMES.get(genre, genre),
            "status": SERIAL_STATUS.get(str(node.get("serialStatus") or ""), clean(node.get("serialStatus"))),
            "word_count": str(node.get("totalCharacterCount") or ""),
            "score": str(node.get("totalFollowers") or ""),
            "url": f"{WORKS}/{work_id}" if work_id else "",
            "extra": node,
        }
        fields.update(overrides)
        return self.make(channel, **fields)
