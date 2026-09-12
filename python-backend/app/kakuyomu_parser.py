from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from bs4 import BeautifulSoup

KAKUYOMU_GRAPHQL_ENDPOINT = "https://kakuyomu.jp/graphql"

KAKUYOMU_WORK_QUERY = """
query GetQingJuanWork($workId: ID!) {
  work(id: $workId) {
    id
    title
    serialStatus
    catchphrase
    introduction
    adminCoverImageUrl
    ogImageUrl
    author {
      id
      name
      activityName
      screenName
    }
    tableOfContentsV2 {
      id
      episodeUnions {
        __typename
        ... on Episode {
          id
          title
          publishedAt
        }
        ... on EmptyEpisode {
          id
          title
        }
      }
      chapter {
        id
        level
        title
      }
    }
  }
}
"""


class KakuyomuParseError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class KakuyomuEpisode:
    id: str
    title: str


@dataclass(frozen=True, slots=True)
class KakuyomuWork:
    title: str
    author: str | None
    synopsis: str
    cover: str | None
    episodes: tuple[KakuyomuEpisode, ...]


@dataclass(frozen=True, slots=True)
class KakuyomuEpisodeContent:
    text: str
    image_sources: tuple[str, ...]


def parse_kakuyomu_work_response(payload: dict[str, Any], work_id: str) -> KakuyomuWork:
    errors = payload.get("errors")
    if isinstance(errors, list) and errors:
        messages = [
            str(item.get("message") or "Kakuyomu GraphQL 返回未知错误")
            for item in errors
            if isinstance(item, dict)
        ]
        raise KakuyomuParseError("Kakuyomu GraphQL 错误：" + "；".join(messages or ["未知错误"]))

    data = payload.get("data")
    work = data.get("work") if isinstance(data, dict) else None
    if not isinstance(work, dict):
        raise KakuyomuParseError(f"Kakuyomu GraphQL 未返回作品 {work_id}")

    title = str(work.get("title") or "").strip()
    if not title:
        raise KakuyomuParseError("Kakuyomu GraphQL 返回的作品缺少标题")

    author = None
    raw_author = work.get("author")
    if isinstance(raw_author, dict):
        for key in ("activityName", "name", "screenName"):
            candidate = str(raw_author.get(key) or "").strip()
            if candidate:
                author = candidate
                break

    catchphrase = str(work.get("catchphrase") or "").strip()
    introduction = str(work.get("introduction") or "").strip()
    synopsis_parts = [part for part in (catchphrase, introduction) if part]
    if len(synopsis_parts) == 2 and synopsis_parts[0] in synopsis_parts[1]:
        synopsis_parts.pop(0)

    episodes: list[KakuyomuEpisode] = []
    seen: set[str] = set()
    toc = work.get("tableOfContentsV2")
    for group in toc if isinstance(toc, list) else []:
        if not isinstance(group, dict):
            continue
        chapter = group.get("chapter")
        chapter_title = str(chapter.get("title") or "").strip() if isinstance(chapter, dict) else ""
        episode_unions = group.get("episodeUnions")
        for episode in episode_unions if isinstance(episode_unions, list) else []:
            if not isinstance(episode, dict) or episode.get("__typename") != "Episode":
                continue
            episode_id = str(episode.get("id") or "").strip()
            episode_title = str(episode.get("title") or "").strip()
            if not episode_id or not episode_title or episode_id in seen:
                continue
            seen.add(episode_id)
            display_title = (
                f"{chapter_title} - {episode_title}"
                if chapter_title and chapter_title not in episode_title
                else episode_title
            )
            episodes.append(KakuyomuEpisode(id=episode_id, title=display_title[:180]))

    return KakuyomuWork(
        title=title,
        author=author,
        synopsis="\n\n".join(synopsis_parts),
        cover=str(work.get("adminCoverImageUrl") or work.get("ogImageUrl") or "").strip() or None,
        episodes=tuple(episodes),
    )


def parse_kakuyomu_episode_page(html: str) -> KakuyomuEpisodeContent:
    soup = BeautifulSoup(html, "html.parser")
    body = soup.select_one(".widget-episodeBody.js-episode-body, .widget-episodeBody, .js-episode-body")
    if body is None:
        if "アクセスが禁止" in html:
            raise KakuyomuParseError("Kakuyomu 返回了访问限制页，请稍后重试并降低请求频率")
        raise KakuyomuParseError("Kakuyomu 阅读页缺少正文容器")

    image_sources: list[str] = []
    for image in body.select("img"):
        source = str(image.get("data-src") or image.get("src") or "").strip()
        if source and source not in image_sources:
            image_sources.append(source)

    paragraphs = body.find_all("p", recursive=True)
    lines = [_kakuyomu_paragraph_text(paragraph).rstrip("\r\n") for paragraph in paragraphs]
    text = "\n".join(lines).strip("\r\n") if lines else body.get_text("\n", strip=True)

    if not text and not image_sources:
        raise KakuyomuParseError("Kakuyomu 阅读页正文为空")
    return KakuyomuEpisodeContent(text=text, image_sources=tuple(image_sources))


def _kakuyomu_paragraph_text(paragraph: Any) -> str:
    parts: list[str] = []
    for child in paragraph.children:
        name = getattr(child, "name", None)
        if name == "ruby":
            base_node = child.find("rb")
            reading_node = child.find("rt")
            base = base_node.get_text() if base_node is not None else ""
            reading = reading_node.get_text() if reading_node is not None else ""
            if not base:
                base = "".join(
                    str(node) for node in child.children if getattr(node, "name", None) not in {"rp", "rt"}
                ).strip()
            parts.append(f"{base}（{reading}）" if reading else base)
            continue
        if name == "br":
            parts.append("\n")
            continue
        if isinstance(child, str):
            parts.append(child)
        else:
            parts.append(child.get_text())
    return "".join(parts)
