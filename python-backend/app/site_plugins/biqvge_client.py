from __future__ import annotations

import asyncio
import html as html_lib
import re
import threading
import time
from dataclasses import dataclass
from typing import Any, Literal
from urllib.parse import urljoin, urlparse

import httpx
from bs4 import BeautifulSoup, Tag

SiteId = Literal["txt80", "b520", "blqukan"]


class BiqvgeError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class SiteConfig:
    id: SiteId
    name: str
    origin: str
    domain: str
    encoding: str
    catalog_paths: tuple[str, ...] = ()


@dataclass(frozen=True, slots=True)
class BiqvgeResource:
    site: SiteId
    book_id: str
    chapter_id: str | None = None
    page: int | None = None


_B520_CATEGORIES = (
    "xuanhuanxiaoshuo",
    "xiuzhenxiaoshuo",
    "dushixiaoshuo",
    "chuanyuexiaoshuo",
    "wangyouxiaoshuo",
    "kehuanxiaoshuo",
    "yanqingxiaoshuo",
    "tongrenxiaoshuo",
)
_BLQUKAN_CATEGORIES = (
    "xuanhuannxiaoshuo",
    "xiuzhenxiaoshuo",
    "dushixiaoshuo",
    "chuanyuexiaoshuo",
    "wangyouxiaoshuo",
    "kehuanxiaoshuo",
    "qitaxiaoshuo",
)

SITES: dict[SiteId, SiteConfig] = {
    "txt80": SiteConfig(
        id="txt80",
        name="八零小说网",
        origin="http://www.txt80.net",
        domain="txt80.net",
        encoding="utf-8",
    ),
    "b520": SiteConfig(
        id="b520",
        name="笔趣阁 5200",
        origin="https://www.b520.cc",
        domain="b520.cc",
        encoding="utf-8",
        catalog_paths=("/", *(f"/{name}/" for name in _B520_CATEGORIES)),
    ),
    "blqukan": SiteConfig(
        id="blqukan",
        name="笔趣看",
        origin="https://www.blqukan.cc",
        domain="blqukan.cc",
        encoding="gb18030",
        catalog_paths=(
            "/",
            "/paihangbang/",
            "/wanben/",
            *(f"/{name}/" for name in _BLQUKAN_CATEGORIES),
        ),
    ),
}

CATALOG_TTL_SECONDS = 30 * 60
SEARCH_RESULT_TTL_SECONDS = 30
MAX_SEARCH_RESULT_CACHE_ENTRIES = 256
TXT80_SEARCH_ROUTE_TTL_SECONDS = 30 * 60
_TXT80_SEARCH_FALLBACK_PATHS = (
    "/searchf0.html",
    "/search.html",
    "/so.html",
    "/search/",
)
_SITE_FAILURE_COOLDOWN_SECONDS: dict[SiteId, float] = {
    "txt80": 60,
    "b520": 5 * 60,
    "blqukan": 5 * 60,
}
_SEARCH_TIMEOUT_SECONDS: dict[SiteId, float] = {
    "txt80": 15.0,
    "b520": 10.0,
    "blqukan": 5.0,
}
_CATALOG_CACHE: dict[SiteId, tuple[float, list[dict[str, Any]]]] = {}
_SEARCH_RESULT_CACHE: dict[tuple[SiteId, str], tuple[float, list[dict[str, Any]]]] = {}
_SITE_FAILURE_CACHE: dict[SiteId, tuple[float, str]] = {}
_TXT80_SEARCH_ROUTE_CACHE: tuple[float, str] | None = None
_CATALOG_CACHE_LOCK = threading.Lock()
_TXT80_BOOK_PATH = re.compile(r"^/txt/(?P<book_id>\d+)\.html/?$", re.IGNORECASE)
_TXT80_CHAPTER_PATH = re.compile(
    r"^/read/(?P<book_id>\d+)/(?P<chapter_id>\d+)(?:_(?P<page>\d+))?\.html/?$",
    re.IGNORECASE,
)
_MIRROR_BOOK_PATH = re.compile(r"^/(?P<bucket>\d+)_(?P<book_id>\d+)/?$", re.IGNORECASE)
_MIRROR_CHAPTER_PATH = re.compile(
    r"^/(?P<bucket>\d+)_(?P<book_id>\d+)/(?P<chapter_id>\d+)"
    r"(?:\.(?:html?|HTML?))?/?$",
    re.IGNORECASE,
)


def clear_catalog_cache() -> None:
    global _TXT80_SEARCH_ROUTE_CACHE
    with _CATALOG_CACHE_LOCK:
        _CATALOG_CACHE.clear()
        _SEARCH_RESULT_CACHE.clear()
        _SITE_FAILURE_CACHE.clear()
        _TXT80_SEARCH_ROUTE_CACHE = None


def _site_config(site: str) -> SiteConfig:
    config = SITES.get(site)  # type: ignore[arg-type]
    if config is None:
        raise BiqvgeError(f"未知笔趣阁子站：{site}")
    return config


def _site_from_url(value: str) -> SiteConfig | None:
    parsed = urlparse(value.strip())
    if parsed.scheme.lower() not in {"http", "https"}:
        return None
    host = (parsed.hostname or "").lower().rstrip(".")
    return next(
        (config for config in SITES.values() if host == config.domain or host.endswith(f".{config.domain}")),
        None,
    )


def book_resource_from_url(value: str) -> BiqvgeResource | None:
    config = _site_from_url(value)
    if config is None:
        return None
    path = urlparse(value.strip()).path
    if config.id == "txt80":
        chapter_match = _TXT80_CHAPTER_PATH.match(path)
        if chapter_match:
            page = chapter_match.group("page")
            return BiqvgeResource(
                site=config.id,
                book_id=chapter_match.group("book_id"),
                chapter_id=chapter_match.group("chapter_id"),
                page=int(page) if page else None,
            )
        book_match = _TXT80_BOOK_PATH.match(path)
        if book_match:
            return BiqvgeResource(site=config.id, book_id=book_match.group("book_id"))
        return None

    chapter_match = _MIRROR_CHAPTER_PATH.match(path)
    if chapter_match and _valid_mirror_bucket(chapter_match.group("bucket"), chapter_match.group("book_id")):
        return BiqvgeResource(
            site=config.id,
            book_id=chapter_match.group("book_id"),
            chapter_id=chapter_match.group("chapter_id"),
        )
    book_match = _MIRROR_BOOK_PATH.match(path)
    if book_match and _valid_mirror_bucket(book_match.group("bucket"), book_match.group("book_id")):
        return BiqvgeResource(site=config.id, book_id=book_match.group("book_id"))
    return None


def _valid_mirror_bucket(bucket: str, book_id: str) -> bool:
    try:
        return int(book_id) > 0 and int(bucket) == int(book_id) // 1000
    except ValueError:
        return False


def _positive_id(value: str | int, label: str) -> str:
    normalized = str(value).strip()
    if not normalized.isdigit() or int(normalized) <= 0:
        raise BiqvgeError(f"{label}无效")
    return normalized


def canonical_book_url(site: str, book_id: str | int) -> str:
    config = _site_config(site)
    normalized = _positive_id(book_id, "笔趣阁作品编号")
    if config.id == "txt80":
        return f"{config.origin}/txt/{normalized}.html"
    return f"{config.origin}/{int(normalized) // 1000}_{normalized}/"


def canonical_chapter_url(site: str, book_id: str | int, chapter_id: str | int) -> str:
    config = _site_config(site)
    normalized_book_id = _positive_id(book_id, "笔趣阁作品编号")
    normalized_chapter_id = _positive_id(chapter_id, "笔趣阁章节编号")
    if config.id == "txt80":
        return f"{config.origin}/read/{normalized_book_id}/{normalized_chapter_id}.html"
    return (
        f"{config.origin}/{int(normalized_book_id) // 1000}_{normalized_book_id}/{normalized_chapter_id}.html"
    )


def canonical_book_url_from_url(value: str) -> str | None:
    resource = book_resource_from_url(value)
    return canonical_book_url(resource.site, resource.book_id) if resource else None


def _clean_text(value: Any) -> str:
    decoded = str(value or "")
    for _ in range(5):
        unescaped = html_lib.unescape(decoded)
        if unescaped == decoded:
            break
        decoded = unescaped
    return re.sub(r"\s+", " ", decoded.replace("\ufeff", "").replace("\u00a0", " ")).strip()


def _meta_content(soup: BeautifulSoup, key: str) -> str:
    node = soup.find("meta", attrs={"property": key}) or soup.find("meta", attrs={"name": key})
    return _clean_text(node.get("content")) if isinstance(node, Tag) else ""


def _absolute_site_url(config: SiteConfig, value: str) -> str:
    normalized = value.strip()
    if not normalized:
        return ""
    if normalized.startswith("//"):
        absolute = f"{urlparse(config.origin).scheme}:{normalized}"
    elif normalized.startswith(("http://", "https://")):
        absolute = normalized
    else:
        absolute = urljoin(f"{config.origin}/", normalized.lstrip("/"))
    resolved_site = _site_from_url(absolute)
    return absolute if resolved_site is not None and resolved_site.id == config.id else ""


def _category_parts(value: str) -> tuple[str, str]:
    parts = [_clean_text(item) for item in value.split("/") if _clean_text(item)]
    return (parts[0] if parts else "", parts[1] if len(parts) > 1 else "")


def parse_search_page(html: str, site: str) -> list[dict[str, Any]]:
    config = _site_config(site)
    if config.id != "txt80":
        return parse_catalog_page(html, site)

    soup = BeautifulSoup(html, "html.parser")
    results: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in soup.select("li.searchresult"):
        link = item.select_one("a[href*='/txt/']")
        match = (
            _TXT80_BOOK_PATH.match(urlparse(urljoin(config.origin, str(link.get("href") or ""))).path)
            if link
            else None
        )
        if match is None or match.group("book_id") in seen:
            continue
        book_id = match.group("book_id")
        title_node = item.select_one("h3")
        title = _clean_text(
            title_node.get_text("", strip=True) if title_node else link.get_text("", strip=True)
        )
        if not title:
            continue
        seen.add(book_id)

        author = ""
        author_icon = item.select_one("i.fa-user-circle-o")
        if author_icon is not None and author_icon.parent is not None:
            author_line = author_icon.parent
            muted = author_line.select_one(".s_gray")
            muted_text = muted.get_text(" ", strip=True) if muted else ""
            author = _clean_text(author_line.get_text(" ", strip=True).replace(muted_text, ""))
        category_node = item.select_one(".img_span span") or next(
            (
                node
                for node in item.select("span")
                if "/" in _clean_text(node.get_text(" ", strip=True))
            ),
            None,
        )
        category, status = _category_parts(category_node.get_text(" ", strip=True) if category_node else "")
        intro_node = item.select_one(".searchresult_p")
        image = item.select_one("img")
        cover = ""
        if image is not None:
            cover = str(image.get("data-original") or image.get("data-src") or image.get("src") or "")
        latest_chapter = ""
        latest_chapter_id = ""
        latest_chapter_url = ""
        for chapter_link in item.select(f"a[href*='/read/{book_id}/']"):
            absolute_chapter_url = urljoin(config.origin, str(chapter_link.get("href") or ""))
            chapter = book_resource_from_url(absolute_chapter_url)
            if chapter is None or chapter.book_id != book_id or chapter.chapter_id is None:
                continue
            latest_chapter = _clean_text(chapter_link.get_text(" ", strip=True))
            latest_chapter_id = chapter.chapter_id
            latest_chapter_url = canonical_chapter_url(config.id, book_id, chapter.chapter_id)
        results.append(
            {
                "site": config.id,
                "site_name": config.name,
                "book_id": book_id,
                "title": title,
                "author": author,
                "category": category,
                "status": status,
                "synopsis": _clean_text(intro_node.get_text(" ", strip=True) if intro_node else ""),
                "cover": _absolute_site_url(config, cover),
                "latest_chapter": latest_chapter,
                "latest_chapter_id": latest_chapter_id,
                "latest_chapter_url": latest_chapter_url,
                "url": canonical_book_url(config.id, book_id),
            }
        )

    if results:
        return results

    for link in soup.select("a[href*='/txt/']"):
        absolute = urljoin(config.origin, str(link.get("href") or ""))
        resource = book_resource_from_url(absolute)
        title = _clean_text(link.get_text(" ", strip=True))
        if resource is None or resource.chapter_id is not None or not title or resource.book_id in seen:
            continue
        seen.add(resource.book_id)
        results.append(
            {
                "site": config.id,
                "site_name": config.name,
                "book_id": resource.book_id,
                "title": title,
                "author": "",
                "category": "",
                "status": "",
                "synopsis": "",
                "cover": "",
                "latest_chapter": "",
                "latest_chapter_id": "",
                "latest_chapter_url": "",
                "url": canonical_book_url(config.id, resource.book_id),
            }
        )
    return results


def parse_catalog_page(html: str, site: str, category: str = "") -> list[dict[str, Any]]:
    config = _site_config(site)
    if config.id == "txt80":
        return parse_search_page(html, site)

    soup = BeautifulSoup(html, "html.parser")
    results: list[dict[str, Any]] = []
    seen: set[str] = set()
    for term in soup.select("div.item dt"):
        link = term.find("a", href=True)
        if link is None:
            continue
        absolute = urljoin(f"{config.origin}/", str(link.get("href") or ""))
        resource = book_resource_from_url(absolute)
        if resource is None or resource.chapter_id is not None or resource.book_id in seen:
            continue
        title = _clean_text(link.get_text(" ", strip=True))
        if not title:
            continue
        seen.add(resource.book_id)
        author_node = term.find("span")
        description_node = term.find_next_sibling("dd")
        card = term.find_parent("div", class_="item")
        image = card.find("img") if card else None
        cover = (
            str(image.get("data-original") or image.get("data-src") or image.get("src") or "")
            if image
            else ""
        )
        results.append(
            {
                "site": config.id,
                "site_name": config.name,
                "book_id": resource.book_id,
                "title": title,
                "author": _clean_text(author_node.get_text(" ", strip=True) if author_node else ""),
                "category": category,
                "status": "",
                "synopsis": _clean_text(
                    description_node.get_text(" ", strip=True) if description_node else ""
                ),
                "cover": _absolute_site_url(config, cover),
                "url": canonical_book_url(config.id, resource.book_id),
            }
        )
    return results


def _fallback_author(soup: BeautifulSoup) -> str:
    for node in soup.select("#info p, .book-info p, .bookinfo p"):
        text = _clean_text(node.get_text(" ", strip=True))
        match = re.search(r"作\s*者\s*[:：]?\s*(.+)", text)
        if match:
            return _clean_text(match.group(1))
    return ""


def parse_book_page(html: str, source_url: str) -> dict[str, Any]:
    resource = book_resource_from_url(source_url)
    if resource is None:
        raise BiqvgeError("无法识别笔趣阁作品链接")
    config = _site_config(resource.site)
    book_url = canonical_book_url(resource.site, resource.book_id)
    soup = BeautifulSoup(html, "html.parser")
    title = _meta_content(soup, "og:novel:book_name") or _meta_content(soup, "og:title")
    if not title:
        title_node = soup.select_one("#info h1, .book-info h1, h1")
        title = _clean_text(title_node.get_text(" ", strip=True) if title_node else "")
    author = _meta_content(soup, "og:novel:author") or _fallback_author(soup)
    category = _meta_content(soup, "og:novel:category")
    status = _meta_content(soup, "og:novel:status")
    synopsis = _meta_content(soup, "og:description")
    if not synopsis:
        synopsis_node = soup.select_one("#intro, .intro, .book-intro, .bookintro")
        synopsis = _clean_text(synopsis_node.get_text(" ", strip=True) if synopsis_node else "")
    cover = _meta_content(soup, "og:image")
    if not cover:
        image = soup.select_one("#fmimg img, .book-cover img, .book-info img")
        if image is not None:
            cover = str(image.get("data-original") or image.get("data-src") or image.get("src") or "")
    latest_chapter = _meta_content(soup, "og:novel:latest_chapter_name") or _meta_content(
        soup, "og:novel:lastest_chapter_name"
    )
    latest_chapter_url = _meta_content(soup, "og:novel:latest_chapter_url") or _meta_content(
        soup, "og:novel:lastest_chapter_url"
    )
    latest_resource = book_resource_from_url(urljoin(book_url, latest_chapter_url)) if latest_chapter_url else None
    latest_chapter_id = (
        latest_resource.chapter_id
        if latest_resource is not None and latest_resource.book_id == resource.book_id
        else ""
    )

    chapters: list[dict[str, Any]] = []
    seen: set[str] = set()
    # Both templates repeat a handful of "latest" links above the complete
    # catalogue. Restricting the scan keeps chapter order stable for imports.
    catalog = (
        soup.select_one("#ul_all_chapters") if resource.site == "txt80" else soup.select_one("#list")
    ) or soup
    catalog_links = catalog.find_all("a", href=True)
    if resource.site != "txt80" and isinstance(catalog, Tag):
        body_marker = next(
            (
                marker
                for marker in catalog.find_all("dt")
                if any(label in _clean_text(marker.get_text(" ", strip=True)) for label in ("正文", "目录"))
            ),
            None,
        )
        if body_marker is not None:
            catalog_links = [
                link for link in body_marker.find_all_next("a", href=True) if catalog in link.parents
            ]
    for link in catalog_links:
        absolute = urljoin(book_url, str(link.get("href") or ""))
        chapter = book_resource_from_url(absolute)
        if (
            chapter is None
            or chapter.site != resource.site
            or chapter.book_id != resource.book_id
            or chapter.chapter_id is None
            or chapter.chapter_id in seen
        ):
            continue
        chapter_title = _clean_text(link.get_text(" ", strip=True))
        if not chapter_title or chapter_title in {"开始阅读", "TXT下载"}:
            continue
        seen.add(chapter.chapter_id)
        chapters.append(
            {
                "id": chapter.chapter_id,
                "title": chapter_title,
                "url": canonical_chapter_url(resource.site, resource.book_id, chapter.chapter_id),
                "access_restricted": False,
            }
        )

    return {
        "site": config.id,
        "site_name": config.name,
        "book_id": resource.book_id,
        "title": title,
        "author": author,
        "category": category,
        "status": status,
        "synopsis": synopsis,
        "cover": _absolute_site_url(config, cover),
        "latest_chapter": latest_chapter,
        "latest_chapter_id": latest_chapter_id,
        "update_time": _meta_content(soup, "og:novel:update_time"),
        "url": book_url,
        "count": len(chapters),
        "chapters": chapters,
    }


def _chapter_text(node: Tag | None) -> str:
    if node is None:
        return ""
    for unwanted in node.select(
        "script, style, noscript, iframe, .readad, .content-ad, .ad, [id*='ad_'], [class*='advert']"
    ):
        unwanted.decompose()
    lines = [_clean_text(line) for line in node.get_text("\n", strip=True).splitlines()]
    return "\n\n".join(line for line in lines if line)


def parse_chapter_page(html: str, source_url: str) -> dict[str, Any]:
    resource = book_resource_from_url(source_url)
    if resource is None or resource.chapter_id is None:
        raise BiqvgeError("无法识别笔趣阁章节链接")
    soup = BeautifulSoup(html, "html.parser")
    title_node = soup.select_one("p.style_h1, h1")
    content_node = (
        soup.select_one("article#article") if resource.site == "txt80" else soup.select_one("#content")
    )
    book_title = _meta_content(soup, "og:novel:book_name") or _meta_content(soup, "og:title")
    if not book_title:
        book_url = canonical_book_url(resource.site, resource.book_id)
        for link in soup.select(".con_top a[href], .breadcrumb a[href]"):
            absolute = urljoin(source_url, str(link.get("href") or ""))
            if canonical_book_url_from_url(absolute) == book_url:
                book_title = _clean_text(link.get_text(" ", strip=True))
                if book_title:
                    break

    def navigation_url(selector: str) -> str:
        link = soup.select_one(selector)
        if link is None:
            return ""
        absolute = urljoin(source_url, str(link.get("href") or ""))
        navigation = book_resource_from_url(absolute)
        if (
            navigation is None
            or navigation.site != resource.site
            or navigation.book_id != resource.book_id
            or navigation.chapter_id is None
        ):
            return ""
        return absolute

    return {
        "site": resource.site,
        "book_id": resource.book_id,
        "chapter_id": resource.chapter_id,
        "book_title": book_title,
        "title": _clean_text(title_node.get_text(" ", strip=True) if title_node else ""),
        "text": _chapter_text(content_node),
        "prev_url": navigation_url("#prev_url[href]"),
        "next_url": navigation_url("#next_url[href]"),
        "pages": 1,
    }


def _response_text(response: httpx.Response, config: SiteConfig) -> str:
    content_type = response.headers.get("content-type", "")
    match = re.search(r"charset=([^;\s]+)", content_type, re.IGNORECASE)
    encoding = match.group(1).strip("\"'") if match else config.encoding
    try:
        return response.content.decode(encoding, errors="replace")
    except LookupError:
        return response.content.decode(config.encoding, errors="replace")


async def _fetch_text(
    client: httpx.AsyncClient,
    config: SiteConfig,
    url: str,
    *,
    method: str = "GET",
    data: dict[str, str] | None = None,
) -> str:
    current_url = url
    current_method = method
    current_data = data
    for _ in range(6):
        try:
            response = await client.request(
                current_method,
                current_url,
                data=current_data,
                follow_redirects=False,
            )
        except httpx.HTTPError as exc:
            raise BiqvgeError(f"{config.name}请求失败：{exc}") from exc

        if response.is_redirect:
            location = str(response.headers.get("location") or "").strip()
            redirected_url = urljoin(str(response.url), location)
            redirected_site = _site_from_url(redirected_url)
            if not location or redirected_site is None or redirected_site.id != config.id:
                raise BiqvgeError(f"{config.name}返回了非本站重定向")
            if response.status_code == 303 or (
                response.status_code in {301, 302} and current_method.upper() != "GET"
            ):
                current_method = "GET"
                current_data = None
            current_url = redirected_url
            continue

        try:
            response.raise_for_status()
        except httpx.HTTPError as exc:
            raise BiqvgeError(f"{config.name}请求失败：{exc}") from exc
        resolved_site = _site_from_url(str(response.url))
        if resolved_site is None or resolved_site.id != config.id:
            raise BiqvgeError(f"{config.name}返回了非本站响应")
        return _response_text(response, config)
    raise BiqvgeError(f"{config.name}重定向次数过多")


async def _discover_txt80_search_url(client: httpx.AsyncClient) -> str:
    global _TXT80_SEARCH_ROUTE_CACHE

    config = SITES["txt80"]
    now = time.monotonic()
    with _CATALOG_CACHE_LOCK:
        cached = _TXT80_SEARCH_ROUTE_CACHE
    if cached is not None and cached[0] > now:
        return cached[1]

    search_url = ""
    try:
        homepage = await _fetch_text(client, config, f"{config.origin}/")
    except BiqvgeError:
        homepage = ""
    if homepage:
        soup = BeautifulSoup(homepage, "html.parser")
        for form in soup.select("form[action]"):
            action = str(form.get("action") or "").strip()
            if "search" not in action.casefold():
                continue
            candidate = urljoin(f"{config.origin}/", action)
            resolved_site = _site_from_url(candidate)
            if resolved_site is not None and resolved_site.id == config.id:
                search_url = candidate
                break

    if not search_url:
        for path in _TXT80_SEARCH_FALLBACK_PATHS:
            candidate = urljoin(f"{config.origin}/", path.lstrip("/"))
            try:
                await _fetch_text(
                    client,
                    config,
                    candidate,
                    method="POST",
                    data={"searchkey": "测试", "searchtype": "all"},
                )
            except BiqvgeError:
                continue
            search_url = candidate
            break

    if not search_url:
        raise BiqvgeError("八零小说网搜索入口不可用")
    with _CATALOG_CACHE_LOCK:
        _TXT80_SEARCH_ROUTE_CACHE = (
            time.monotonic() + TXT80_SEARCH_ROUTE_TTL_SECONDS,
            search_url,
        )
    return search_url


async def _search_txt80(client: httpx.AsyncClient, keyword: str) -> list[dict[str, Any]]:
    config = SITES["txt80"]
    search_url = await _discover_txt80_search_url(client)
    html = await _fetch_text(
        client,
        config,
        search_url,
        method="POST",
        data={"searchkey": keyword, "searchtype": "all"},
    )
    if "搜索间隔" in html and "window.history.go" in html:
        raise BiqvgeError("八零小说网限制连续搜索，请稍后重试")
    return parse_search_page(html, config.id)


def _category_from_path(path: str) -> str:
    names = {
        "xuanhuanxiaoshuo": "玄幻小说",
        "xuanhuannxiaoshuo": "玄幻小说",
        "xiuzhenxiaoshuo": "修真小说",
        "dushixiaoshuo": "都市小说",
        "chuanyuexiaoshuo": "穿越小说",
        "wangyouxiaoshuo": "网游小说",
        "kehuanxiaoshuo": "科幻小说",
        "yanqingxiaoshuo": "言情小说",
        "tongrenxiaoshuo": "同人小说",
        "qitaxiaoshuo": "其他小说",
    }
    return names.get(path.strip("/"), "")


async def _mirror_catalog(client: httpx.AsyncClient, site: SiteId) -> list[dict[str, Any]]:
    config = _site_config(site)
    now = time.monotonic()
    with _CATALOG_CACHE_LOCK:
        cached = _CATALOG_CACHE.get(site)
        if cached is not None and cached[0] > now:
            return [dict(item) for item in cached[1]]

    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    errors: list[str] = []
    successful_pages = 0
    consecutive_network_errors = 0
    consecutive_http_errors = 0
    for path in config.catalog_paths:
        url = urljoin(f"{config.origin}/", path.lstrip("/"))
        try:
            html = await _fetch_text(client, config, url)
        except BiqvgeError as exc:
            errors.append(str(exc))
            root_cause = exc.__cause__
            if isinstance(root_cause, httpx.RequestError):
                consecutive_network_errors += 1
                consecutive_http_errors = 0
                if consecutive_network_errors >= 2:
                    break
            else:
                consecutive_http_errors += 1
                consecutive_network_errors = 0
                if consecutive_http_errors >= 3:
                    break
            continue
        successful_pages += 1
        consecutive_network_errors = 0
        consecutive_http_errors = 0
        values = parse_catalog_page(html, config.id, _category_from_path(path))
        for item in values:
            book_id = str(item.get("book_id") or "")
            if not book_id or book_id in seen:
                continue
            seen.add(book_id)
            items.append(item)
    if successful_pages == 0 or (not items and errors):
        raise BiqvgeError(errors[0] if errors else f"{config.name}目录不可用")
    with _CATALOG_CACHE_LOCK:
        _CATALOG_CACHE[site] = (time.monotonic() + CATALOG_TTL_SECONDS, items)
    return [dict(item) for item in items]


async def _search_mirror(
    client: httpx.AsyncClient,
    site: SiteId,
    keyword: str,
) -> list[dict[str, Any]]:
    query = keyword.casefold()
    values = await _mirror_catalog(client, site)
    return [
        item
        for item in values
        if query in str(item.get("title") or "").casefold()
        or query in str(item.get("author") or "").casefold()
    ]


def _search_rank(item: dict[str, Any], keyword: str) -> tuple[int, int, str]:
    query = keyword.casefold()
    title = str(item.get("title") or "").casefold()
    author = str(item.get("author") or "").casefold()
    if title == query:
        relevance = 0
    elif title.startswith(query):
        relevance = 1
    elif query in title:
        relevance = 2
    elif author == query:
        relevance = 3
    else:
        relevance = 4
    site_order = {"txt80": 0, "b520": 1, "blqukan": 2}
    return relevance, site_order.get(str(item.get("site")), 9), title


async def search_books(
    client: httpx.AsyncClient,
    keyword: str,
    limit: int = 20,
) -> list[dict[str, Any]]:
    query = keyword.strip()
    if not query:
        return []

    async def run_site(site: SiteId) -> list[dict[str, Any]]:
        now = time.monotonic()
        cache_key = (site, query.casefold())
        with _CATALOG_CACHE_LOCK:
            cached_result = _SEARCH_RESULT_CACHE.get(cache_key)
            failure = _SITE_FAILURE_CACHE.get(site)
        if cached_result is not None and cached_result[0] > now:
            return [dict(item) for item in cached_result[1]]
        if failure is not None and failure[0] > now:
            raise BiqvgeError(failure[1])
        try:
            operation = (
                _search_txt80(client, query) if site == "txt80" else _search_mirror(client, site, query)
            )
            result = await asyncio.wait_for(operation, timeout=_SEARCH_TIMEOUT_SECONDS[site])
        except Exception as exc:
            message = str(exc).strip() or f"{SITES[site].name}搜索超时"
            with _CATALOG_CACHE_LOCK:
                _SITE_FAILURE_CACHE[site] = (
                    time.monotonic() + _SITE_FAILURE_COOLDOWN_SECONDS[site],
                    message,
                )
            raise BiqvgeError(message) from exc
        with _CATALOG_CACHE_LOCK:
            _SITE_FAILURE_CACHE.pop(site, None)
            _SEARCH_RESULT_CACHE[cache_key] = (
                time.monotonic() + SEARCH_RESULT_TTL_SECONDS,
                result,
            )
            while len(_SEARCH_RESULT_CACHE) > MAX_SEARCH_RESULT_CACHE_ENTRIES:
                _SEARCH_RESULT_CACHE.pop(next(iter(_SEARCH_RESULT_CACHE)))
        return result

    operations = tuple(run_site(site) for site in ("txt80", "b520", "blqukan"))
    responses = await asyncio.gather(*operations, return_exceptions=True)
    successful = [value for value in responses if isinstance(value, list)]
    if not successful:
        errors = [str(value) for value in responses if isinstance(value, Exception)]
        raise BiqvgeError(errors[0] if errors else "笔趣阁聚合搜索失败")

    results: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for values in successful:
        for item in values:
            identity = (str(item.get("site") or ""), str(item.get("book_id") or ""))
            if not all(identity) or identity in seen:
                continue
            seen.add(identity)
            results.append(item)
    results.sort(key=lambda item: _search_rank(item, query))
    return results[: max(1, int(limit))]


async def get_book(client: httpx.AsyncClient, source_url: str) -> dict[str, Any]:
    resource = book_resource_from_url(source_url)
    if resource is None:
        raise BiqvgeError("无法识别笔趣阁作品链接")
    config = _site_config(resource.site)
    book_url = canonical_book_url(resource.site, resource.book_id)
    html = await _fetch_text(client, config, book_url)
    result = parse_book_page(html, book_url)
    if not str(result.get("title") or "").strip():
        raise BiqvgeError(f"{config.name}作品页缺少书名")
    if not result.get("chapters"):
        raise BiqvgeError(f"{config.name}作品目录为空")
    return result


async def get_chapter(client: httpx.AsyncClient, chapter_url: str) -> dict[str, Any]:
    resource = book_resource_from_url(chapter_url)
    if resource is None or resource.chapter_id is None:
        raise BiqvgeError("无法识别笔趣阁章节链接")
    config = _site_config(resource.site)
    canonical_url = canonical_chapter_url(resource.site, resource.book_id, resource.chapter_id)

    if resource.site != "txt80":
        last_error: Exception | None = None
        stem = canonical_url.removesuffix(".html")
        for candidate in (canonical_url, f"{stem}.htm", f"{stem}/"):
            try:
                html = await _fetch_text(client, config, candidate)
                result = parse_chapter_page(html, candidate)
                if result["text"]:
                    return result
            except Exception as exc:  # noqa: BLE001 - mirrors use several equivalent suffixes
                last_error = exc
        if last_error is not None:
            raise BiqvgeError(f"{config.name}章节不可用：{last_error}") from last_error
        raise BiqvgeError(f"{config.name}章节正文为空")

    parts: list[str] = []
    visited: set[str] = set()
    current_url = canonical_url
    title = ""
    while current_url not in visited and len(visited) < 20:
        visited.add(current_url)
        html = await _fetch_text(client, config, current_url)
        page = parse_chapter_page(html, current_url)
        if page["text"] and page["text"] not in parts:
            parts.append(str(page["text"]))
        title = title or str(page.get("title") or "")
        soup = BeautifulSoup(html, "html.parser")
        next_link = soup.select_one("#next_url[href]")
        if next_link is None:
            break
        next_url = urljoin(current_url, str(next_link.get("href") or ""))
        next_resource = book_resource_from_url(next_url)
        if (
            next_resource is None
            or next_resource.site != resource.site
            or next_resource.book_id != resource.book_id
            or next_resource.chapter_id != resource.chapter_id
        ):
            break
        current_url = next_url

    text = "\n\n".join(parts).strip()
    if not text:
        raise BiqvgeError(f"{config.name}章节正文为空")
    return {
        "site": resource.site,
        "book_id": resource.book_id,
        "chapter_id": resource.chapter_id,
        "title": title,
        "text": text,
    }
