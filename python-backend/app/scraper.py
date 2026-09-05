from __future__ import annotations

import ast
import asyncio
import base64
import hmac
import html
import importlib
import json
import math
import mimetypes
import os
import re
import secrets
import shutil
import socket
import ssl
import string
import subprocess
import tempfile
import threading
import time
import unicodedata
import urllib.request
import weakref
from collections import deque
from collections.abc import Awaitable, Callable
from contextlib import suppress
from dataclasses import dataclass
from datetime import datetime
from email.utils import parsedate_to_datetime
from hashlib import md5, sha256
from io import BytesIO
from itertools import count
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, quote, unquote, urljoin, urlparse

import httpx
from bs4 import BeautifulSoup
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont, UnidentifiedImageError

try:
    import cv2
    import numpy as np
except Exception:  # pragma: no cover - RapidOCR environments normally provide both
    cv2 = None
    np = None

try:
    from .db import DATA_DIR, is_site_plugin_enabled
    from .manga_download import (
        MANGA_RETRYABLE_STATUS_CODES,
        fetch_image_with_retry,
        is_valid_image_file,
        write_image_atomic,
    )
    from .model_endpoint_security import create_model_http_client
    from .models import (
        AddBookPayload,
        BookSourceRecord,
        BuiltinSiteSearchResult,
        ChapterPreview,
        MangaOcrPagePayload,
        MangaOcrRegion,
        MangaTranslatedPagePayload,
        MangaTranslatedRegion,
        PreviewResponse,
        TranslationSettings,
    )
    from .multi_user import multi_user_enabled
    from .site_plugins import (
        is_manga_site_url,
        resolve_site_plugin,
        site_plugin_matches,
    )
    from .translation_model_health import (
        normalize_openai_compatible_base_url,
        resolve_openai_compatible_model_config,
    )
except ImportError:
    from app.db import DATA_DIR, is_site_plugin_enabled
    from app.manga_download import (
        MANGA_RETRYABLE_STATUS_CODES,
        fetch_image_with_retry,
        is_valid_image_file,
        write_image_atomic,
    )
    from app.model_endpoint_security import create_model_http_client
    from app.models import (
        AddBookPayload,
        BookSourceRecord,
        BuiltinSiteSearchResult,
        ChapterPreview,
        MangaOcrPagePayload,
        MangaOcrRegion,
        MangaTranslatedPagePayload,
        MangaTranslatedRegion,
        PreviewResponse,
        TranslationSettings,
    )
    from app.multi_user import multi_user_enabled
    from app.site_plugins import (
        is_manga_site_url,
        resolve_site_plugin,
        site_plugin_matches,
    )
    from app.translation_model_health import (
        normalize_openai_compatible_base_url,
        resolve_openai_compatible_model_config,
    )

try:
    from .fanqie_parser import (
        canonical_fanqie_book_url,
        fanqie_book_id_from_url,
        fanqie_item_id_from_url,
        is_fanqie_url,
        parse_fanqie_book_page,
        parse_fanqie_reader_page,
    )
except ImportError:
    from app.fanqie_parser import (
        canonical_fanqie_book_url,
        fanqie_book_id_from_url,
        fanqie_item_id_from_url,
        is_fanqie_url,
        parse_fanqie_book_page,
        parse_fanqie_reader_page,
    )

try:
    from .kakuyomu_parser import (
        KAKUYOMU_GRAPHQL_ENDPOINT,
        KAKUYOMU_WORK_QUERY,
        parse_kakuyomu_episode_page,
        parse_kakuyomu_work_response,
    )
except ImportError:
    from app.kakuyomu_parser import (
        KAKUYOMU_GRAPHQL_ENDPOINT,
        KAKUYOMU_WORK_QUERY,
        parse_kakuyomu_episode_page,
        parse_kakuyomu_work_response,
    )

try:
    from .yanmaga_parser import (
        YANMAGA_CONTENT_HOSTS,
        YANMAGA_ORIGIN,
        YANMAGA_VIEWER_ORIGIN,
        canonical_yanmaga_url,
        decode_speedbinb_table,
        descramble_yanmaga_image,
        parse_yanmaga_book_page,
        parse_yanmaga_episode_fragment,
        speedbinb_page_keys,
        speedbinb_request_key,
        yanmaga_resource_from_url,
    )
except ImportError:
    from app.yanmaga_parser import (
        YANMAGA_CONTENT_HOSTS,
        YANMAGA_ORIGIN,
        YANMAGA_VIEWER_ORIGIN,
        canonical_yanmaga_url,
        decode_speedbinb_table,
        descramble_yanmaga_image,
        parse_yanmaga_book_page,
        parse_yanmaga_episode_fragment,
        speedbinb_page_keys,
        speedbinb_request_key,
        yanmaga_resource_from_url,
    )

try:
    from .site_plugins.qidian_client import (
        canonical_book_url as canonical_qidian_book_url,
    )
    from .site_plugins.qidian_client import (
        canonical_chapter_url as canonical_qidian_chapter_url,
    )
    from .site_plugins.qidian_client import (
        get_book_info as get_qidian_book_info,
    )
    from .site_plugins.qidian_client import (
        get_catalog as get_qidian_catalog,
    )
    from .site_plugins.qidian_client import (
        get_chapter as get_qidian_chapter,
    )
    from .site_plugins.qidian_client import (
        qidian_book_id_from_url,
        qidian_chapter_ids_from_url,
    )
    from .site_plugins.qidian_client import search_books as search_qidian_books
except ImportError:
    from app.site_plugins.qidian_client import (
        canonical_book_url as canonical_qidian_book_url,
    )
    from app.site_plugins.qidian_client import (
        canonical_chapter_url as canonical_qidian_chapter_url,
    )
    from app.site_plugins.qidian_client import (
        get_book_info as get_qidian_book_info,
    )
    from app.site_plugins.qidian_client import (
        get_catalog as get_qidian_catalog,
    )
    from app.site_plugins.qidian_client import (
        get_chapter as get_qidian_chapter,
    )
    from app.site_plugins.qidian_client import (
        qidian_book_id_from_url,
        qidian_chapter_ids_from_url,
    )
    from app.site_plugins.qidian_client import search_books as search_qidian_books

try:
    from .site_plugins.fanqie_client import search_books as search_fanqie_books
except ImportError:
    from app.site_plugins.fanqie_client import search_books as search_fanqie_books

try:
    from .site_plugins.quark_client import (
        canonical_quark_book_url,
        canonical_quark_chapter_url,
        get_quark_book_info,
        get_quark_catalog,
        get_quark_chapter_content,
        quark_book_id_from_url,
        quark_chapter_ids_from_url,
        quark_chapter_is_public,
        search_quark_books,
    )
except ImportError:
    from app.site_plugins.quark_client import (
        canonical_quark_book_url,
        canonical_quark_chapter_url,
        get_quark_book_info,
        get_quark_catalog,
        get_quark_chapter_content,
        quark_book_id_from_url,
        quark_chapter_ids_from_url,
        quark_chapter_is_public,
        search_quark_books,
    )

try:
    from .site_plugins.biqvge_client import (
        canonical_book_url_from_url as canonical_biqvge_book_url_from_url,
    )
    from .site_plugins.biqvge_client import get_book as get_biqvge_book
    from .site_plugins.biqvge_client import get_chapter as get_biqvge_chapter
    from .site_plugins.biqvge_client import search_books as search_biqvge_books
except ImportError:
    from app.site_plugins.biqvge_client import (
        canonical_book_url_from_url as canonical_biqvge_book_url_from_url,
    )
    from app.site_plugins.biqvge_client import get_book as get_biqvge_book
    from app.site_plugins.biqvge_client import get_chapter as get_biqvge_chapter
    from app.site_plugins.biqvge_client import search_books as search_biqvge_books

try:
    from .site_plugins.comicores_client import (
        canonical_comicores_book_url,
        comicores_authors,
        comicores_book_key_from_url,
        comicores_cover,
        comicores_synopsis,
        comicores_title,
        get_comicores_book,
        search_comicores,
    )
    from .site_plugins.copymanga_client import (
        canonical_mangacopy_book_url,
        canonical_mangacopy_chapter_url,
        get_mangacopy_chapter,
        get_mangacopy_chapters,
        get_mangacopy_detail,
        is_allowed_mangacopy_image_url,
        mangacopy_chapter_ids_from_url,
        mangacopy_path_word_from_url,
        search_mangacopy,
    )
except ImportError:
    from app.site_plugins.comicores_client import (
        canonical_comicores_book_url,
        comicores_authors,
        comicores_book_key_from_url,
        comicores_cover,
        comicores_synopsis,
        comicores_title,
        get_comicores_book,
        search_comicores,
    )
    from app.site_plugins.copymanga_client import (
        canonical_mangacopy_book_url,
        canonical_mangacopy_chapter_url,
        get_mangacopy_chapter,
        get_mangacopy_chapters,
        get_mangacopy_detail,
        is_allowed_mangacopy_image_url,
        mangacopy_chapter_ids_from_url,
        mangacopy_path_word_from_url,
        search_mangacopy,
    )

try:
    from .site_plugins.ciweimao_client import (
        book_id_from_url as ciweimao_book_id_from_url,
    )
    from .site_plugins.ciweimao_client import (
        chapter_id_from_url as ciweimao_chapter_id_from_url,
    )
    from .site_plugins.ciweimao_client import (
        get_book as get_ciweimao_book,
    )
    from .site_plugins.ciweimao_client import (
        get_catalogue as get_ciweimao_catalogue,
    )
    from .site_plugins.ciweimao_client import (
        get_chapter as get_ciweimao_chapter,
    )
    from .site_plugins.ciweimao_client import (
        search_books as search_ciweimao_books,
    )
    from .site_plugins.ehentai_client import (
        gallery_ids_from_url as ehentai_gallery_ids_from_url,
    )
    from .site_plugins.ehentai_client import (
        get_gallery_image_entries as get_ehentai_gallery_image_entries,
    )
    from .site_plugins.ehentai_client import (
        get_gallery_metadata as get_ehentai_gallery_metadata,
    )
    from .site_plugins.ehentai_client import (
        get_gallery_page as get_ehentai_gallery_page,
    )
    from .site_plugins.ehentai_client import (
        search_galleries as search_ehentai_galleries,
    )
    from .site_plugins.sfacg_client import (
        book_id_from_url as sfacg_book_id_from_url,
    )
    from .site_plugins.sfacg_client import (
        chapter_ids_from_url as sfacg_chapter_ids_from_url,
    )
    from .site_plugins.sfacg_client import (
        get_book as get_sfacg_book,
    )
    from .site_plugins.sfacg_client import (
        get_catalogue as get_sfacg_catalogue,
    )
    from .site_plugins.sfacg_client import (
        get_chapter as get_sfacg_chapter,
    )
    from .site_plugins.sfacg_client import (
        normalize_book as normalize_sfacg_book,
    )
    from .site_plugins.sfacg_client import (
        search_books as search_sfacg_books,
    )
    from .site_plugins.shaoniandream_client import (
        book_id_from_url as shaoniandream_book_id_from_url,
    )
    from .site_plugins.shaoniandream_client import (
        chapter_id_from_url as shaoniandream_chapter_id_from_url,
    )
    from .site_plugins.shaoniandream_client import (
        get_book as get_shaoniandream_book,
    )
    from .site_plugins.shaoniandream_client import (
        get_catalogue as get_shaoniandream_catalogue,
    )
    from .site_plugins.shaoniandream_client import (
        get_chapter as get_shaoniandream_chapter,
    )
    from .site_plugins.shaoniandream_client import (
        search_books as search_shaoniandream_books,
    )
except ImportError:
    from app.site_plugins.ciweimao_client import (
        book_id_from_url as ciweimao_book_id_from_url,
    )
    from app.site_plugins.ciweimao_client import (
        chapter_id_from_url as ciweimao_chapter_id_from_url,
    )
    from app.site_plugins.ciweimao_client import (
        get_book as get_ciweimao_book,
    )
    from app.site_plugins.ciweimao_client import (
        get_catalogue as get_ciweimao_catalogue,
    )
    from app.site_plugins.ciweimao_client import (
        get_chapter as get_ciweimao_chapter,
    )
    from app.site_plugins.ciweimao_client import (
        search_books as search_ciweimao_books,
    )
    from app.site_plugins.ehentai_client import (
        gallery_ids_from_url as ehentai_gallery_ids_from_url,
    )
    from app.site_plugins.ehentai_client import (
        get_gallery_image_entries as get_ehentai_gallery_image_entries,
    )
    from app.site_plugins.ehentai_client import (
        get_gallery_metadata as get_ehentai_gallery_metadata,
    )
    from app.site_plugins.ehentai_client import (
        get_gallery_page as get_ehentai_gallery_page,
    )
    from app.site_plugins.ehentai_client import (
        search_galleries as search_ehentai_galleries,
    )
    from app.site_plugins.sfacg_client import (
        book_id_from_url as sfacg_book_id_from_url,
    )
    from app.site_plugins.sfacg_client import (
        chapter_ids_from_url as sfacg_chapter_ids_from_url,
    )
    from app.site_plugins.sfacg_client import (
        get_book as get_sfacg_book,
    )
    from app.site_plugins.sfacg_client import (
        get_catalogue as get_sfacg_catalogue,
    )
    from app.site_plugins.sfacg_client import (
        get_chapter as get_sfacg_chapter,
    )
    from app.site_plugins.sfacg_client import (
        normalize_book as normalize_sfacg_book,
    )
    from app.site_plugins.sfacg_client import (
        search_books as search_sfacg_books,
    )
    from app.site_plugins.shaoniandream_client import (
        book_id_from_url as shaoniandream_book_id_from_url,
    )
    from app.site_plugins.shaoniandream_client import (
        chapter_id_from_url as shaoniandream_chapter_id_from_url,
    )
    from app.site_plugins.shaoniandream_client import (
        get_book as get_shaoniandream_book,
    )
    from app.site_plugins.shaoniandream_client import (
        get_catalogue as get_shaoniandream_catalogue,
    )
    from app.site_plugins.shaoniandream_client import (
        get_chapter as get_shaoniandream_chapter,
    )
    from app.site_plugins.shaoniandream_client import (
        search_books as search_shaoniandream_books,
    )

try:
    from .fanqie_app import FanqieAppClient
except ImportError:
    from app.fanqie_app import FanqieAppClient

try:
    from curl_cffi import requests as curl_requests
except Exception:  # pragma: no cover - 环境可选依赖
    curl_requests = None

try:
    import requests
except Exception:  # pragma: no cover - 环境可选依赖
    requests = None

try:
    import websockets
except Exception:  # pragma: no cover - 环境可选依赖
    websockets = None

_RAPID_OCR_ENGINE: Any | None = None
_RAPID_OCR_LOCK = threading.RLock()
RAPID_OCR_DETECTION_SIDE = 512

CHAPTER_PATTERN = re.compile(r"(chapter|episode|第.{0,6}[章节话卷篇])", re.IGNORECASE)
GENERIC_CHAPTER_CONTAINER_SELECTORS = (
    ".chapter-list a[href]",
    ".chapters a[href]",
    ".episode-list a[href]",
    ".episodes a[href]",
    ".toc a[href]",
    ".table-of-contents a[href]",
    "[id*='chapter'] a[href]",
    "[class*='chapter'] a[href]",
    "[id*='episode'] a[href]",
    "[class*='episode'] a[href]",
)
BUILTIN_MANGA_IMAGE_TIMEOUT_SECONDS = 1800
CHAT_COMPLETION_IMAGE_MODEL_HINTS = (
    "gpt-",
    "grok-",
    "claude-",
    "gemini",
    "qwen",
    "glm",
    "internvl",
    "llava",
    "minicpm",
)
LINOVELIB_PREFERRED_HOSTS = ("tw.linovelib.com", "www.bilinovel.com", "www.linovelib.com")
LINOVELIB_BOOK_PATH_PATTERN = re.compile(
    r"/novel/(?P<book_id>\d+)(?:\.html|/catalog|/\d+(?:_\d+)?\.html)?/?$"
)
LINOVELIB_CHAPTER_PATH_PATTERN = re.compile(
    r"/novel/(?P<book_id>\d+)/(?P<chapter_id>\d+)(?:_(?P<page>\d+))?\.html$"
)
KAKUYOMU_WORK_PATH_PATTERN = re.compile(r"^/works/(?P<work_id>\d+)(?:/episodes/(?P<episode_id>\d+))?/?$")
SYOSETU_BOOK_PATH_PATTERN = re.compile(
    r"^/(?P<book_code>[a-z0-9]+)(?:/(?P<chapter_no>\d+)/?)?$", re.IGNORECASE
)
HAMELN_BOOK_PATH_PATTERN = re.compile(r"^/novel/(?P<book_id>\d+)(?:/(?P<chapter_no>\d+)\.html)?/?$")
PIXIV_SERIES_PATH_PATTERN = re.compile(r"^/novel/series/(?P<series_id>\d+)/?$")
PIXIV_ARTWORK_PATH_PATTERN = re.compile(r"^/(?:[a-z]{2}/)?artworks/(?P<artwork_id>\d+)/?$")
PIXIV_COMIC_WORK_PATH_PATTERN = re.compile(r"^/works/(?P<work_id>\d+)/?$")
PIXIV_COMIC_STORY_PATH_PATTERN = re.compile(r"^/viewer/stories/(?P<story_id>\d+)/?$")
NOVELUP_STORY_PATH_PATTERN = re.compile(r"^/story/(?P<story_id>\d+)(?:/.*)?$")
ALPHAPOLIS_WORK_PATH_PATTERN = re.compile(
    r"^/novel/(?P<author_id>\d+)/(?P<content_id>\d+)(?:/episode/(?P<episode_id>\d+))?/?$"
)
COMIC_18_PATH_PATTERN = re.compile(r"^/(?P<kind>album|photo)/(?P<album_id>\d+)(?:/[^/?#]*)?/?$")
BIKA_COMIC_PATH_PATTERN = re.compile(r"^/comic/(?P<comic_id>[0-9a-fA-F]+)(?:/.*)?$", re.IGNORECASE)
BIKA_READER_PATH_PATTERN = re.compile(
    r"^/comic/reader/(?P<comic_id>[0-9a-fA-F]+)/(?P<order>\d+)(?:/[^/?#]*)?/?$",
    re.IGNORECASE,
)
LINOVELIB_BLOCK_MARKERS = (
    "Attention Required! | Cloudflare",
    "Sorry, you have been blocked",
)
NOISE_LINE_MARKERS = (
    "内容加载失败",
    "內容加載失敗",
    "請重載或更換瀏覽器",
    "请重载或更换浏览器",
    "翻页模式",
    "翻上页",
    "翻下页",
    "上一页",
    "下一页",
    "上一頁",
    "下一頁",
    "目录",
    "目錄",
    "书页",
    "書頁",
    "建议使用上下翻页",
    "建議使用上下翻頁",
    "章评",
)
LINOVELIB_MIN_REQUEST_INTERVAL = 1.2
LINOVELIB_MAX_RETRIES = 5
LINOVELIB_RETRYABLE_STATUS_CODES = {403, 429, 500, 502, 503, 504}
FANQIE_MIN_REQUEST_INTERVAL = 0.6
FANQIE_MAX_RETRIES = 3
FANQIE_MAX_REDIRECTS = 3
FANQIE_RETRYABLE_STATUS_CODES = {429, 500, 502, 503, 504}
_HOST_LAST_REQUEST_AT: dict[str, float] = {}
_FANQIE_APP_CLIENTS: weakref.WeakKeyDictionary[httpx.AsyncClient, FanqieAppClient] = (
    weakref.WeakKeyDictionary()
)
BROWSER_EXECUTABLE_PATHS = tuple(
    path
    for path in (
        Path(os.environ["QINGJUAN_BROWSER_EXECUTABLE"]).expanduser()
        if os.environ.get("QINGJUAN_BROWSER_EXECUTABLE")
        else None,
        Path(os.environ.get("PROGRAMFILES(X86)", "")) / "Microsoft/Edge/Application/msedge.exe"
        if os.environ.get("PROGRAMFILES(X86)")
        else None,
        Path(os.environ.get("PROGRAMFILES", "")) / "Microsoft/Edge/Application/msedge.exe"
        if os.environ.get("PROGRAMFILES")
        else None,
        Path("C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"),
        Path("C:/Program Files/Microsoft/Edge/Application/msedge.exe"),
        Path("/usr/bin/chromium"),
        Path("/usr/bin/chromium-browser"),
        Path("/usr/bin/google-chrome"),
    )
    if path is not None
)
EDGE_CDP_BOOT_TIMEOUT_SECONDS = 15.0
EDGE_CDP_PAGE_TIMEOUT_SECONDS = 45.0
EDGE_CDP_POLL_INTERVAL_SECONDS = 1.0
_CDP_COMMAND_IDS = count(1)
DEFAULT_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/132.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    "Cache-Control": "no-cache",
    "Pragma": "no-cache",
    "Upgrade-Insecure-Requests": "1",
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
}
BIKA_API_BASE_URL = "https://picaapi.go2778.com"
BIKA_API_ACCEPT = "application/vnd.picacomic.com.v1+json"
BIKA_APP_CHANNEL = "1"
BIKA_APP_UUID = "webUUIDv2"
BIKA_APP_VERSION = "20251017"
BIKA_APP_PLATFORM = "android"
BIKA_IMAGE_QUALITY = "medium"
BIKA_WEB_ORIGIN = "https://bikawebapp.com"
BIKA_WEB_REFERER = f"{BIKA_WEB_ORIGIN}/"
BIKA_RANDOM_ALPHABET = string.ascii_lowercase + string.digits
BIKA_SIGNATURE_SUFFIX = "C69BAF41DA5ABD1FFEDC6D2FEA56B"
BIKA_SIGNATURE_KEY = "~d}$Q7$eIni=V)9\\RK/P.RM4;9[7|@/CA}b~OW!3?EV`:<>M7pddUBL5n|0/*Cn"
_BIKA_TOKEN_CACHE: dict[str, str] = {}
_COMIC_18_SCRAMBLE_ID_CACHE: dict[str, int] = {}
_PIXIV_COMIC_PAGE_KEYS: dict[str, tuple[str, int]] = {}
_YANMAGA_PAGE_KEYS: dict[str, tuple[str, str, str]] = {}
_EHENTAI_IMAGE_REFERERS: dict[str, str] = {}
MANGA_RENDERER_VERSION = 11


@dataclass
class DownloadResult:
    title: str
    synopsis: str
    cover: str | None
    chapters: list[ChapterPreview]
    local_path: Path


@dataclass
class ChapterFetchResult:
    text: str
    image_urls: list[str]
    illustration: bool = False
    image_files: list[str] | None = None
    content_source: str | None = None
    authorization_method: str | None = None
    access_restricted: bool = False


@dataclass
class SyncFetchResult:
    text: str
    resolved_url: str
    status_code: int


@dataclass
class EdgeSnapshot:
    html: str
    resolved_url: str


def _is_kakuyomu_url(url: str) -> bool:
    return site_plugin_matches("kakuyomu", url)


def _is_yanmaga_url(url: str) -> bool:
    return site_plugin_matches("yanmaga", url)


def _is_fanqie_url(url: str) -> bool:
    return site_plugin_matches("fanqie", url)


def _is_qidian_url(url: str) -> bool:
    return site_plugin_matches("qidian", url)


def _is_quark_url(url: str) -> bool:
    return site_plugin_matches("quark", url)


def _is_biqvge_url(url: str) -> bool:
    return site_plugin_matches("biqvge", url)


def _is_syosetu_url(url: str) -> bool:
    return site_plugin_matches("syosetu", url)


def _is_novel18_url(url: str) -> bool:
    return site_plugin_matches("novel18", url)


def _is_pixiv_url(url: str) -> bool:
    return site_plugin_matches("pixiv", url)


def _is_novelup_url(url: str) -> bool:
    return site_plugin_matches("novelup", url)


def _is_alphapolis_url(url: str) -> bool:
    return site_plugin_matches("alphapolis", url)


def _is_hameln_url(url: str) -> bool:
    return site_plugin_matches("hameln", url)


def _is_18comic_url(url: str) -> bool:
    return site_plugin_matches("18comic", url)


def _is_bikawebapp_url(url: str) -> bool:
    return site_plugin_matches("bika", url)


def _is_copymanga_url(url: str) -> bool:
    return site_plugin_matches("copymanga", url)


def _is_comicores_url(url: str) -> bool:
    return site_plugin_matches("comicores", url)


def _is_pixiv_manga_url(url: str) -> bool:
    return _is_pixiv_url(url) and PIXIV_ARTWORK_PATH_PATTERN.match(urlparse(url).path) is not None


def _is_pixiv_comic_url(url: str) -> bool:
    return site_plugin_matches("pixiv-comic", url)


def _is_pixiv_comic_work_url(url: str) -> bool:
    return _is_pixiv_comic_url(url) and PIXIV_COMIC_WORK_PATH_PATTERN.match(urlparse(url).path) is not None


def _is_pixiv_comic_story_url(url: str) -> bool:
    return _is_pixiv_comic_url(url) and PIXIV_COMIC_STORY_PATH_PATTERN.match(urlparse(url).path) is not None


def _is_generic_manga_url(url: str) -> bool:
    plugin = resolve_site_plugin(url)
    return plugin is not None and plugin.chapter_handler == "generic_manga"


def _is_manga_source_url(url: str) -> bool:
    return is_manga_site_url(url) or _is_pixiv_manga_url(url)


def _require_enabled_site_plugin(url: str) -> Any:
    plugin = resolve_site_plugin(url)
    if plugin is None:
        raise ValueError("没有可处理该链接的站点插件")
    if not is_site_plugin_enabled(plugin.id):
        raise ValueError(f"站点插件“{plugin.name}”已停用，请在左侧“插件配置”中启用后重试")
    return plugin


def _clean_title_suffix(title: str, suffixes: tuple[str, ...]) -> str:
    value = title.strip()
    for suffix in suffixes:
        if value.endswith(suffix):
            value = value[: -len(suffix)].strip()
    return value.strip() or title.strip()


def _build_origin(url: str) -> str:
    parsed = urlparse(url)
    return f"{parsed.scheme}://{parsed.netloc}"


def _append_prefixed_text(prefix: str | None, body: str | None) -> str:
    prefix_value = (prefix or "").strip()
    body_value = (body or "").strip()
    if prefix_value and body_value and prefix_value not in body_value:
        return f"{prefix_value}\n\n{body_value}"
    return body_value or prefix_value


def _normalize_search_text(value: Any, limit: int = 220) -> str:
    normalized = re.sub(r"\s+", " ", str(value or "")).strip()
    if len(normalized) <= limit:
        return normalized
    return f"{normalized[: max(0, limit - 1)].rstrip()}…"


def _result_cover_from_card(card: BeautifulSoup | Any, base_url: str) -> str | None:
    if card is None:
        return None
    image = card.select_one("img")
    if image is None:
        return None
    for key in ("data-original", "data-src", "src"):
        value = str(image.get(key) or "").strip()
        if value and "blank.jpg" not in value:
            return urljoin(base_url, value)
    return None


def _is_linovelib_url(url: str) -> bool:
    return site_plugin_matches("linovelib", url)


def _normalize_source_url(url: str) -> str:
    parsed = urlparse(url)
    if _is_fanqie_url(url):
        book_id = fanqie_book_id_from_url(url)
        return canonical_fanqie_book_url(book_id) if book_id else url

    if _is_quark_url(url):
        book_id = quark_book_id_from_url(url)
        return canonical_quark_book_url(book_id) if book_id else url

    if _is_biqvge_url(url):
        return canonical_biqvge_book_url_from_url(url) or url

    if _is_linovelib_url(url):
        match = LINOVELIB_BOOK_PATH_PATTERN.match(parsed.path)
        if not match:
            return url
        book_id = match.group("book_id")
        return f"{parsed.scheme}://{parsed.netloc}/novel/{book_id}/catalog"

    if _is_kakuyomu_url(url):
        match = KAKUYOMU_WORK_PATH_PATTERN.match(parsed.path)
        if match:
            return f"{parsed.scheme}://{parsed.netloc}/works/{match.group('work_id')}"
        return url

    if _is_syosetu_url(url) or _is_novel18_url(url):
        match = SYOSETU_BOOK_PATH_PATTERN.match(parsed.path)
        if match:
            return f"{parsed.scheme}://{parsed.netloc}/{match.group('book_code').lower()}/"
        return url

    if _is_hameln_url(url):
        match = HAMELN_BOOK_PATH_PATTERN.match(parsed.path)
        if match:
            return f"{parsed.scheme}://{parsed.netloc}/novel/{match.group('book_id')}/"
        return url

    if _is_pixiv_url(url):
        series_match = PIXIV_SERIES_PATH_PATTERN.match(parsed.path)
        if series_match:
            return f"{parsed.scheme}://{parsed.netloc}/novel/series/{series_match.group('series_id')}"
        novel_id = parse_qs(parsed.query).get("id", [""])[0].strip()
        if parsed.path == "/novel/show.php" and novel_id:
            return f"{parsed.scheme}://{parsed.netloc}/novel/show.php?id={novel_id}"

    if _is_novelup_url(url):
        match = NOVELUP_STORY_PATH_PATTERN.match(parsed.path)
        if match:
            return f"{parsed.scheme}://{parsed.netloc}/story/{match.group('story_id')}"
        return url

    if _is_alphapolis_url(url):
        match = ALPHAPOLIS_WORK_PATH_PATTERN.match(parsed.path)
        if match:
            return f"{parsed.scheme}://{parsed.netloc}/novel/{match.group('author_id')}/{match.group('content_id')}"
        return url

    if _is_18comic_url(url):
        match = COMIC_18_PATH_PATTERN.match(parsed.path)
        if match:
            return f"{parsed.scheme}://{parsed.netloc}/album/{match.group('album_id')}"
        return url

    if _is_bikawebapp_url(url):
        reader_match = BIKA_READER_PATH_PATTERN.match(parsed.path)
        if reader_match:
            return f"{parsed.scheme}://{parsed.netloc}/comic/{reader_match.group('comic_id')}"
        comic_match = BIKA_COMIC_PATH_PATTERN.match(parsed.path)
        if comic_match:
            return f"{parsed.scheme}://{parsed.netloc}/comic/{comic_match.group('comic_id')}"
        return url

    if _is_copymanga_url(url):
        path_word = mangacopy_path_word_from_url(url)
        return canonical_mangacopy_book_url(path_word) if path_word else url

    if _is_comicores_url(url):
        book_key = comicores_book_key_from_url(url)
        return canonical_comicores_book_url(book_key) if book_key else url

    return url


def _resolved_preview_book_kind(url: str, payload: AddBookPayload) -> str:
    return "漫画" if _is_manga_source_url(url) else payload.bookKind


async def _search_fanqie_works(
    source: BookSourceRecord,
    keyword: str,
    limit: int,
) -> list[BuiltinSiteSearchResult]:
    values = await asyncio.to_thread(
        search_fanqie_books,
        keyword,
        limit,
    )
    results: list[BuiltinSiteSearchResult] = []
    seen: set[str] = set()
    for item in values:
        book_id = str(item.get("book_id") or item.get("bookId") or "").strip()
        title = str(
            item.get("title")
            or item.get("book_name")
            or item.get("original_book_name")
            or item.get("bookName")
            or ""
        ).strip()
        if not book_id.isdigit() or not title:
            continue
        source_url = canonical_fanqie_book_url(book_id)
        if source_url in seen:
            continue
        seen.add(source_url)
        results.append(
            BuiltinSiteSearchResult(
                title=title,
                author=str(item.get("author") or item.get("author_name") or "").strip() or None,
                synopsis=_normalize_search_text(
                    item.get("summary") or item.get("abstract") or item.get("description") or ""
                ),
                cover=str(
                    item.get("cover_url")
                    or item.get("thumb_url")
                    or item.get("thumbUri")
                    or item.get("audio_thumb_url_hd")
                    or ""
                ).strip()
                or None,
                sourceUrl=source_url,
                bookKind=source.bookKind,
            )
        )
        if len(results) >= limit:
            break
    return results


async def _search_qidian_works(
    source: BookSourceRecord,
    keyword: str,
    limit: int,
) -> list[BuiltinSiteSearchResult]:
    payload = await asyncio.to_thread(
        search_qidian_books,
        keyword,
        page_size=min(20, max(1, limit)),
    )
    data = payload.get("data") if isinstance(payload, dict) else None
    values = data.get("books") if isinstance(data, dict) else None
    if not isinstance(values, list):
        raise ValueError("起点搜索响应缺少作品列表")

    results: list[BuiltinSiteSearchResult] = []
    seen: set[str] = set()
    for item in values:
        if not isinstance(item, dict):
            continue
        book_id = str(item.get("bookId") or item.get("bid") or "").strip()
        title = str(item.get("bookName") or item.get("bName") or "").strip()
        if not book_id.isdigit() or not title:
            continue
        source_url = canonical_qidian_book_url(book_id)
        if source_url in seen:
            continue
        seen.add(source_url)
        results.append(
            BuiltinSiteSearchResult(
                title=title,
                author=str(item.get("authorName") or item.get("bAuth") or "").strip() or None,
                synopsis=_normalize_search_text(item.get("desc") or item.get("description") or ""),
                cover=str(item.get("coverUrl") or item.get("imgUrl") or "").strip() or None,
                sourceUrl=source_url,
                bookKind=source.bookKind,
            )
        )
        if len(results) >= limit:
            break
    return results


async def _search_quark_works(
    source: BookSourceRecord,
    keyword: str,
    limit: int,
) -> list[BuiltinSiteSearchResult]:
    async with _build_http_client() as client:
        values = await search_quark_books(client, keyword, limit)
    return [
        BuiltinSiteSearchResult(
            title=str(item.get("title") or "未命名作品"),
            author=str(item.get("author") or "").strip() or None,
            synopsis=_normalize_search_text(item.get("synopsis")),
            cover=str(item.get("cover") or "").strip() or None,
            sourceUrl=str(item["sourceUrl"]),
            bookKind=source.bookKind,
        )
        for item in values
        if str(item.get("sourceUrl") or "").strip()
    ]


async def _search_biqvge_works(
    source: BookSourceRecord,
    keyword: str,
    limit: int,
) -> list[BuiltinSiteSearchResult]:
    async with _build_http_client() as client:
        items = await search_biqvge_books(client, keyword, limit)
    return _builtin_results_from_items(items, limit, book_kind=source.bookKind)


async def _search_kakuyomu_works(
    source: BookSourceRecord,
    keyword: str,
    limit: int,
) -> list[BuiltinSiteSearchResult]:
    search_url = f"{_build_origin(source.baseUrl)}/search?q={quote(keyword)}"
    html, resolved_url = await _fetch_site_html(search_url)
    state = _kakuyomu_state_from_html(html)
    root_query = state.get("ROOT_QUERY")
    if not isinstance(root_query, dict):
        raise ValueError("Kakuyomu 搜索结果缺少 ROOT_QUERY")

    search_key = next((key for key in root_query if key.startswith("searchWorks(")), "")
    payload = root_query.get(search_key)
    if not isinstance(payload, dict):
        return []

    nodes = payload.get("nodes")
    if not isinstance(nodes, list):
        return []

    origin = _build_origin(resolved_url)
    results: list[BuiltinSiteSearchResult] = []
    seen: set[str] = set()
    for node in nodes:
        ref_key = node.get("__ref") if isinstance(node, dict) else None
        work = state.get(str(ref_key or ""))
        if not isinstance(work, dict):
            continue

        work_id = str(work.get("id") or "").strip()
        title = str(work.get("title") or "").strip()
        if not work_id or not title:
            continue

        source_url = _normalize_source_url(f"{origin}/works/{work_id}")
        if source_url in seen:
            continue
        seen.add(source_url)

        results.append(
            BuiltinSiteSearchResult(
                title=title,
                author=_kakuyomu_author_from_state(state, work),
                synopsis=_normalize_search_text(_kakuyomu_synopsis_from_work(work)),
                cover=str(work.get("adminCoverImageUrl") or work.get("ogImageUrl") or "").strip() or None,
                sourceUrl=source_url,
                bookKind=source.bookKind,
            )
        )
        if len(results) >= limit:
            break

    return results


async def _search_18comic_works(
    source: BookSourceRecord,
    keyword: str,
    limit: int,
) -> list[BuiltinSiteSearchResult]:
    def _run_jm_search() -> list[BuiltinSiteSearchResult]:
        page = _jm_client().search_site(search_query=keyword, page=1)
        collected: list[BuiltinSiteSearchResult] = []
        # search_site 结果可迭代，每项形如 (album_id, title)。
        for entry in page:
            try:
                album_id = str(entry[0]).strip()
                name = str(entry[1]).strip()
            except (IndexError, TypeError):
                continue
            if not album_id or not name:
                continue
            collected.append(
                BuiltinSiteSearchResult(
                    title=name,
                    author=None,
                    synopsis="",
                    cover=_jm_cover_url(album_id),
                    sourceUrl=f"https://18comic.vip/album/{album_id}/",
                    bookKind="漫画",
                )
            )
            if len(collected) >= limit:
                break
        return collected

    try:
        api_results = await asyncio.to_thread(_run_jm_search)
        if api_results:
            return api_results
    except Exception as exc:  # noqa: BLE001 - API 不可用时回退网页解析
        import logging

        logging.getLogger("qingjuan.scraper").warning("18Comic 移动 API 搜索失败，回退网页解析：%s", exc)

    origin = _build_origin(source.baseUrl)
    search_url = f"{origin}/search/photos?main_tag=0&search_query={quote(keyword)}"
    response = await asyncio.to_thread(_sync_fetch_18comic_html, search_url, origin)
    soup = BeautifulSoup(response.text, "html.parser")
    results: list[BuiltinSiteSearchResult] = []
    seen: set[str] = set()

    for anchor in soup.select("a[href*='/album/'], a[href*='/photo/']"):
        href = str(anchor.get("href") or "").strip()
        if not href:
            continue

        source_url = _normalize_source_url(urljoin(response.resolved_url, href))
        if "/album/" not in urlparse(source_url).path or source_url in seen:
            continue

        title = str(anchor.get("title") or "").strip() or anchor.get_text(" ", strip=True)
        if not title:
            continue

        card = anchor.find_parent(["li", "article", "div"])
        synopsis = _normalize_search_text(card.get_text(" ", strip=True) if card is not None else "")
        results.append(
            BuiltinSiteSearchResult(
                title=title,
                author=None,
                synopsis=synopsis if synopsis != title else "",
                cover=_result_cover_from_card(card, response.resolved_url),
                sourceUrl=source_url,
                bookKind="漫画",
            )
        )
        seen.add(source_url)
        if len(results) >= limit:
            break

    return results


async def _search_bika_works(
    source: BookSourceRecord,
    keyword: str,
    limit: int,
) -> list[BuiltinSiteSearchResult]:
    runtime_settings = _load_runtime_settings()
    async with _create_async_http_client(timeout=40.0) as client:
        payload = await _bika_authed_request(
            client,
            "comics/advanced-search?page=1",
            "POST",
            settings=runtime_settings,
            json_payload={
                "keyword": keyword,
                "categories": [],
                "sort": "ua",
            },
        )

    data = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(data, dict):
        raise ValueError("Bika 搜索返回格式异常")

    comics = data.get("comics")
    docs = comics.get("docs") if isinstance(comics, dict) else data.get("docs")
    if not isinstance(docs, list):
        return []

    origin = _build_origin(source.baseUrl)
    results: list[BuiltinSiteSearchResult] = []
    seen: set[str] = set()
    for item in docs:
        if not isinstance(item, dict):
            continue

        comic_id = str(item.get("_id") or item.get("id") or "").strip()
        title = str(item.get("title") or "").strip()
        if not comic_id or not title:
            continue

        source_url = _normalize_source_url(f"{origin}/comic/{comic_id}")
        if source_url in seen:
            continue
        seen.add(source_url)

        results.append(
            BuiltinSiteSearchResult(
                title=title,
                author=str(item.get("author") or item.get("chineseTeam") or "").strip() or None,
                synopsis=_normalize_search_text(item.get("description") or ""),
                cover=_bika_image_url(item.get("thumb")) or None,
                sourceUrl=source_url,
                bookKind="漫画",
            )
        )
        if len(results) >= limit:
            break

    return results


async def _search_copymanga_works(
    source: BookSourceRecord,
    keyword: str,
    limit: int,
) -> list[BuiltinSiteSearchResult]:
    async with _build_http_client() as client:
        items = await search_mangacopy(client, keyword, limit)

    results: list[BuiltinSiteSearchResult] = []
    seen: set[str] = set()
    for item in items:
        path_word = str(item.get("path_word") or "").strip()
        title = str(item.get("name") or "").strip()
        if not path_word or not title:
            continue
        source_url = canonical_mangacopy_book_url(path_word)
        if source_url in seen:
            continue
        seen.add(source_url)
        raw_authors = item.get("author")
        authors = (
            [
                str(author.get("name") or "").strip()
                for author in raw_authors
                if isinstance(author, dict) and str(author.get("name") or "").strip()
            ]
            if isinstance(raw_authors, list)
            else []
        )
        results.append(
            BuiltinSiteSearchResult(
                title=title,
                author="、".join(authors) or None,
                synopsis=_normalize_search_text(item.get("alias") or ""),
                cover=str(item.get("cover") or "").strip() or None,
                sourceUrl=source_url,
                bookKind="漫画",
            )
        )
        if len(results) >= limit:
            break
    return results


async def _search_comicores_works(
    source: BookSourceRecord,
    keyword: str,
    limit: int,
) -> list[BuiltinSiteSearchResult]:
    async with _build_http_client() as client:
        items = await search_comicores(client, keyword, limit)

    results: list[BuiltinSiteSearchResult] = []
    seen: set[str] = set()
    for item in items:
        slug = str(item.get("slug") or "").strip()
        title = comicores_title(item)
        if not slug or not title:
            continue
        source_url = canonical_comicores_book_url(slug)
        if source_url in seen:
            continue
        seen.add(source_url)
        results.append(
            BuiltinSiteSearchResult(
                title=title,
                author="、".join(comicores_authors(item)) or None,
                synopsis=_normalize_search_text(comicores_synopsis(item)),
                cover=comicores_cover(item),
                sourceUrl=source_url,
                bookKind="漫画",
            )
        )
        if len(results) >= limit:
            break
    return results


def _builtin_results_from_items(
    items: list[dict[str, Any]],
    limit: int,
    *,
    book_kind: str,
) -> list[BuiltinSiteSearchResult]:
    results: list[BuiltinSiteSearchResult] = []
    seen: set[str] = set()
    for item in items:
        title = str(item.get("title") or "").strip()
        source_url = str(item.get("url") or "").strip()
        if not title or not source_url or source_url in seen:
            continue
        seen.add(source_url)
        results.append(
            BuiltinSiteSearchResult(
                title=title,
                author=str(item.get("author") or "").strip() or None,
                synopsis=_normalize_search_text(item.get("synopsis") or ""),
                cover=str(item.get("cover") or "").strip() or None,
                sourceUrl=source_url,
                bookKind=book_kind,
                providerName=str(item.get("site_name") or "").strip() or None,
            )
        )
        if len(results) >= limit:
            break
    return results


async def _search_ciweimao_works(
    source: BookSourceRecord,
    keyword: str,
    limit: int,
) -> list[BuiltinSiteSearchResult]:
    async with _build_http_client() as client:
        items = await search_ciweimao_books(client, keyword)
    return _builtin_results_from_items(items, limit, book_kind="轻小说")


async def _search_shaoniandream_works(
    source: BookSourceRecord,
    keyword: str,
    limit: int,
) -> list[BuiltinSiteSearchResult]:
    async with _build_http_client() as client:
        items = await search_shaoniandream_books(client, keyword)
    return _builtin_results_from_items(items, limit, book_kind="长小说")


async def _search_sfacg_works(
    source: BookSourceRecord,
    keyword: str,
    limit: int,
) -> list[BuiltinSiteSearchResult]:
    async with _build_http_client() as client:
        items = await search_sfacg_books(client, keyword)
    return _builtin_results_from_items(items, limit, book_kind="轻小说")


async def _search_ehentai_works(
    source: BookSourceRecord,
    keyword: str,
    limit: int,
) -> list[BuiltinSiteSearchResult]:
    async with _build_http_client() as client:
        items = await search_ehentai_galleries(client, keyword, origin=source.baseUrl)
    return _builtin_results_from_items(items, limit, book_kind="漫画")


async def search_builtin_site_books(
    source: BookSourceRecord,
    keyword: str,
    limit: int = 8,
) -> list[BuiltinSiteSearchResult]:
    normalized_keyword = keyword.strip()
    if not normalized_keyword:
        return []

    plugin = _require_enabled_site_plugin(source.baseUrl)
    if plugin.search_handler == "qidian":
        return await _search_qidian_works(source, normalized_keyword, limit)
    if plugin.search_handler == "fanqie":
        return await _search_fanqie_works(source, normalized_keyword, limit)
    if plugin.search_handler == "quark":
        return await _search_quark_works(source, normalized_keyword, limit)
    if plugin.search_handler == "biqvge":
        return await _search_biqvge_works(source, normalized_keyword, limit)
    if plugin.search_handler == "kakuyomu":
        return await _search_kakuyomu_works(source, normalized_keyword, limit)
    if plugin.search_handler == "18comic":
        return await _search_18comic_works(source, normalized_keyword, limit)
    if plugin.search_handler == "bika":
        return await _search_bika_works(source, normalized_keyword, limit)
    if plugin.search_handler == "copymanga":
        return await _search_copymanga_works(source, normalized_keyword, limit)
    if plugin.search_handler == "comicores":
        return await _search_comicores_works(source, normalized_keyword, limit)
    if plugin.search_handler == "ciweimao":
        return await _search_ciweimao_works(source, normalized_keyword, limit)
    if plugin.search_handler == "shaoniandream":
        return await _search_shaoniandream_works(source, normalized_keyword, limit)
    if plugin.search_handler == "sfacg":
        return await _search_sfacg_works(source, normalized_keyword, limit)
    if plugin.search_handler == "ehentai":
        return await _search_ehentai_works(source, normalized_keyword, limit)

    raise ValueError("当前内置站点暂未实现作品搜索，请在书架页粘贴作品链接")


def _18comic_album_id_from_url(url: str) -> str | None:
    match = COMIC_18_PATH_PATTERN.match(urlparse(url).path)
    return match.group("album_id") if match else None


def _18comic_album_url(url: str) -> str:
    parsed = urlparse(_normalize_source_url(url))
    album_id = _18comic_album_id_from_url(url)
    if not album_id:
        raise ValueError("无法识别 18Comic 漫画编号")
    return f"{parsed.scheme}://{parsed.netloc}/album/{album_id}"


def _18comic_photo_url(url: str) -> str:
    parsed = urlparse(url)
    album_id = _18comic_album_id_from_url(url)
    if not album_id:
        raise ValueError("无法识别 18Comic 漫画编号")
    return f"{parsed.scheme}://{parsed.netloc}/photo/{album_id}"


def _18comic_scramble_id_from_html(html: str) -> int | None:
    match = re.search(r"var\s+scramble_id\s*=\s*(\d+)", html)
    return int(match.group(1)) if match else None


def _18comic_cache_scramble_id(url: str, html: str) -> int | None:
    album_id = _18comic_album_id_from_url(url)
    scramble_id = _18comic_scramble_id_from_html(html)
    if album_id and scramble_id is not None:
        _COMIC_18_SCRAMBLE_ID_CACHE[album_id] = scramble_id
    return scramble_id


def _18comic_cached_scramble_id(url: str) -> int | None:
    album_id = _18comic_album_id_from_url(url)
    if not album_id:
        return None
    return _COMIC_18_SCRAMBLE_ID_CACHE.get(album_id)


def _18comic_ensure_scramble_id(url: str) -> int | None:
    cached = _18comic_cached_scramble_id(url)
    if cached is not None:
        return cached
    photo_url = url if "/photo/" in urlparse(url).path else _18comic_photo_url(url)
    album_url = _18comic_album_url(url)
    result = _sync_fetch_18comic_html(photo_url, album_url)
    return _18comic_cache_scramble_id(url, result.text)


def _18comic_image_token_from_url(url: str) -> str:
    return Path(urlparse(url).path).stem.split(".", 1)[0]


def _18comic_segment_count(album_id: str, image_token: str) -> int:
    default_segments = 10
    try:
        album_id_int = int(album_id)
    except ValueError:
        return default_segments
    digest_suffix = md5(f"{album_id}{image_token}".encode()).hexdigest()[-1]
    value = ord(digest_suffix)
    if 268850 <= album_id_int <= 421925:
        value %= 10
    elif album_id_int >= 421926:
        value %= 8
    return {
        0: 2,
        1: 4,
        2: 6,
        3: 8,
        4: 10,
        5: 12,
        6: 14,
        7: 16,
        8: 18,
        9: 20,
    }.get(value, default_segments)


def _18comic_descramble_bytes(
    image_bytes: bytes, image_url: str, referer: str, scramble_id: int | None = None
) -> bytes:
    if image_url.lower().endswith(".gif"):
        return image_bytes
    if "/media/photos/" not in urlparse(image_url).path:
        return image_bytes
    album_id = _18comic_album_id_from_url(referer)
    if not album_id:
        return image_bytes
    resolved_scramble_id = scramble_id if scramble_id is not None else _18comic_ensure_scramble_id(referer)
    if resolved_scramble_id is None:
        return image_bytes
    if int(album_id) < int(resolved_scramble_id):
        return image_bytes

    segment_count = _18comic_segment_count(album_id, _18comic_image_token_from_url(image_url))
    if segment_count <= 1:
        return image_bytes

    try:
        with Image.open(BytesIO(image_bytes)) as image:
            source_format = (image.format or "PNG").upper()
            working = image.copy()
    except UnidentifiedImageError:
        return image_bytes

    width, height = working.size
    block_height = height // segment_count
    remainder = height % segment_count
    if width <= 0 or height <= 0 or block_height <= 0:
        return image_bytes

    rebuilt = Image.new(working.mode, working.size)
    for index in range(segment_count):
        segment_height = block_height
        destination_y = block_height * index
        source_y = height - block_height * (index + 1) - remainder
        if index == 0:
            segment_height += remainder
        else:
            destination_y += remainder
        segment = working.crop((0, source_y, width, source_y + segment_height))
        rebuilt.paste(segment, (0, destination_y))

    output = BytesIO()
    save_kwargs: dict[str, Any] = {"format": source_format}
    if source_format == "WEBP":
        save_kwargs.update({"lossless": True, "quality": 100, "method": 6})
    elif source_format in {"JPEG", "JPG"}:
        if rebuilt.mode not in {"RGB", "L"}:
            rebuilt = rebuilt.convert("RGB")
        save_kwargs.update({"quality": 95})
    rebuilt.save(output, **save_kwargs)
    return output.getvalue()


def repair_18comic_chapter_images(book_dir: Path, manifest: dict, chapter_index: int) -> bool:
    chapter = _chapter_lookup(manifest).get(chapter_index)
    if not chapter:
        return False

    chapter_url = str(chapter.get("url") or "").strip()
    if not _is_18comic_url(chapter_url):
        return False
    if chapter.get("images_repaired") is True:
        return False

    image_files = [item for item in chapter.get("image_files", []) if isinstance(item, str)]
    image_urls = [item for item in chapter.get("image_urls", []) if isinstance(item, str)]
    if not image_files or not image_urls:
        chapter["images_repaired"] = True
        save_manifest(book_dir, manifest)
        return True

    scramble_id = _18comic_ensure_scramble_id(chapter_url)
    if scramble_id is None:
        return False

    repaired = False
    for asset_path, image_url in zip(image_files, image_urls, strict=False):
        target_path = (book_dir / asset_path).resolve()
        if not target_path.exists() or not target_path.is_file():
            continue
        original_bytes = target_path.read_bytes()
        descrambled_bytes = _18comic_descramble_bytes(original_bytes, image_url, chapter_url, scramble_id)
        if descrambled_bytes != original_bytes:
            target_path.write_bytes(descrambled_bytes)
            repaired = True

    chapter["images_repaired"] = True
    save_manifest(book_dir, manifest)
    return repaired


def _bika_comic_id_from_url(url: str) -> str | None:
    parsed = urlparse(url)
    reader_match = BIKA_READER_PATH_PATTERN.match(parsed.path)
    if reader_match:
        return reader_match.group("comic_id")
    comic_match = BIKA_COMIC_PATH_PATTERN.match(parsed.path)
    return comic_match.group("comic_id") if comic_match else None


def _bika_order_from_url(url: str) -> str | None:
    match = BIKA_READER_PATH_PATTERN.match(urlparse(url).path)
    return match.group("order") if match else None


def _manga_placeholder_text(chapter_title: str, page_count: int) -> str:
    readable_count = max(page_count, 0)
    return f"{chapter_title}\n\n漫画章节，共 {readable_count} 页。"


MANGA_READER_IMAGE_SELECTORS = (
    "#_imageList img",
    "#viewer img",
    ".comic-contain img",
    ".comic-container img",
    ".reader-main img",
    ".manga-reader img",
    ".chapter-content img",
    "[data-page] img",
)
MANGA_SCRIPT_IMAGE_ARRAY_PATTERN = re.compile(
    r"\b(?:chapterImages|pageImages|imageUrls|images)\s*=\s*(\[[\s\S]*?\])\s*;?",
    re.IGNORECASE,
)
MANGA_SCRIPT_PATH_PATTERN = re.compile(
    r"\b(?:chapterPath|imagePath|imgPath)\s*=\s*(['\"])(.*?)\1\s*;?",
    re.IGNORECASE,
)
MANGA_IMAGE_NOISE_PATTERN = re.compile(
    r"(?:logo|icon|avatar|banner|advert|/ads?/|loading|spinner|spacer|placeholder|cover)",
    re.IGNORECASE,
)


def _is_probable_manga_image_url(url: str) -> bool:
    parsed = urlparse(url)
    suffix = Path(parsed.path).suffix.lower()
    return (
        parsed.scheme in {"http", "https"}
        and suffix in {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"}
        and MANGA_IMAGE_NOISE_PATTERN.search(url) is None
    )


def _decode_script_image_array(value: str) -> list[str]:
    normalized = value.replace(r"\/", "/")
    for parser in (json.loads, ast.literal_eval):
        try:
            payload = parser(normalized)
        except (ValueError, SyntaxError, json.JSONDecodeError):
            continue
        if isinstance(payload, (list, tuple)):
            return [str(item).strip() for item in payload if isinstance(item, str) and item.strip()]
    return []


def _extract_generic_manga_image_urls(html: str, base_url: str) -> list[str]:
    soup = BeautifulSoup(html, "html.parser")
    candidates: list[str] = []
    selector = ", ".join(MANGA_READER_IMAGE_SELECTORS)
    for image in soup.select(selector):
        for key in ("data-url", "data-src", "data-original", "src"):
            value = str(image.get(key) or "").strip()
            if value and not value.startswith("data:"):
                candidates.append(urljoin(base_url, value))
                break

    for script in soup.select("script"):
        script_text = script.string or script.get_text(" ", strip=False)
        if not script_text:
            continue
        path_match = MANGA_SCRIPT_PATH_PATTERN.search(script_text)
        image_path = path_match.group(2).replace(r"\/", "/").strip() if path_match else ""
        for array_match in MANGA_SCRIPT_IMAGE_ARRAY_PATTERN.finditer(script_text):
            for item in _decode_script_image_array(array_match.group(1)):
                candidate = item
                if image_path and not urlparse(item).scheme and not item.startswith(("/", "//")):
                    candidate = f"{image_path.rstrip('/')}/{item.lstrip('/')}"
                candidates.append(urljoin(base_url, candidate))

    seen: set[str] = set()
    image_urls: list[str] = []
    for candidate in candidates:
        if candidate in seen or not _is_probable_manga_image_url(candidate):
            continue
        seen.add(candidate)
        image_urls.append(candidate)
    return image_urls


def _linovelib_candidate_urls(url: str) -> list[str]:
    normalized = _normalize_source_url(url)
    parsed = urlparse(normalized)
    match = LINOVELIB_BOOK_PATH_PATTERN.match(parsed.path)
    if not match:
        return [normalized]

    book_id = match.group("book_id")
    path = f"/novel/{book_id}/catalog"
    candidates = [f"{parsed.scheme}://{host}{path}" for host in LINOVELIB_PREFERRED_HOSTS]
    candidates.append(f"{parsed.scheme}://{parsed.netloc}{path}")

    deduped: list[str] = []
    seen: set[str] = set()
    for item in candidates:
        if item in seen:
            continue
        seen.add(item)
        deduped.append(item)
    return deduped


def _extract_title(soup: BeautifulSoup, fallback: str) -> str:
    if _is_probable_linovelib_page(soup):
        h1 = soup.select_one("h1")
        if h1 and h1.get_text(" ", strip=True):
            return h1.get_text(" ", strip=True)

        og_title = soup.select_one("[property='og:novel:book_name'], [property='og:title']")
        if og_title and og_title.get("content"):
            return str(og_title.get("content")).strip()

    title_node = soup.title.string.strip() if soup.title and soup.title.string else None
    if title_node:
        return title_node

    og_title = soup.select_one("meta[property='og:title']")
    if og_title and og_title.get("content"):
        return og_title.get("content").strip()

    h1 = soup.select_one("h1")
    if h1 and h1.get_text(" ", strip=True):
        return h1.get_text(" ", strip=True)

    return fallback


def _extract_synopsis(soup: BeautifulSoup) -> str:
    for selector in [
        "meta[name='description']",
        "meta[property='og:description']",
        ".intro",
        ".summary",
        "#intro",
    ]:
        item = soup.select_one(selector)
        if item is None:
            continue
        if item.get("content"):
            return item.get("content").strip()
        text = item.get_text(" ", strip=True)
        if text:
            return text[:300]

    paragraphs = [
        p.get_text(" ", strip=True) for p in soup.select("p") if len(p.get_text(" ", strip=True)) > 30
    ]
    return paragraphs[0][:300] if paragraphs else "未抓取到简介，建议后续针对目标站点补充规则。"


def _extract_author(soup: BeautifulSoup) -> str | None:
    for selector in (
        "[property='og:novel:author']",
        "[property='og:author']",
        "meta[name='author']",
        ".author",
    ):
        item = soup.select_one(selector)
        if item is None:
            continue
        value = str(item.get("content")).strip() if item.get("content") else item.get_text(" ", strip=True)
        if value:
            return value

    body_text = soup.get_text(" ", strip=True)
    match = re.search(r"作者\s*[:：]\s*([^\s]+)", body_text)
    if match:
        return match.group(1).strip()
    return None


def _extract_cover(soup: BeautifulSoup, base_url: str) -> str | None:
    selectors = (
        "[property='og:image']",
        "[property='og:image:url']",
        "meta[name='twitter:image']",
        "img[data-original*='/cover/']",
        "img[data-src*='/cover/']",
        "img[src*='/cover/']",
        ".book-img img",
        ".book-cover img",
        ".cover img",
        ".book-rand-a img",
        "img[alt*='封面']",
    )
    for selector in selectors:
        node = soup.select_one(selector)
        if node is None:
            continue
        value = ""
        for key in ("content", "data-src", "data-original", "src"):
            candidate = node.get(key)
            if isinstance(candidate, str) and candidate.strip():
                value = candidate.strip()
                break
        if value:
            return urljoin(base_url, value)
    return None


def _extract_chapters(soup: BeautifulSoup, base_url: str) -> list[ChapterPreview]:
    if _is_probable_linovelib_page(soup):
        chapters = _extract_linovelib_chapters(soup, base_url)
        if chapters:
            return chapters

    items = _collect_generic_chapter_links(
        soup.select(", ".join(GENERIC_CHAPTER_CONTAINER_SELECTORS)), base_url
    )
    if len(items) >= 2:
        return items

    items: list[ChapterPreview] = []
    seen: set[str] = set()

    for anchor in soup.select("a[href]"):
        text = anchor.get_text(" ", strip=True)
        href = anchor.get("href", "").strip()
        if not href or len(text) < 2 or not CHAPTER_PATTERN.search(text):
            continue

        absolute_url = urljoin(base_url, href)
        if absolute_url in seen:
            continue

        seen.add(absolute_url)
        items.append(ChapterPreview(title=text[:120], url=absolute_url))

    return items[:500]


def _clean_payload_metadata(value: object) -> str:
    return str(value or "").strip()


def _is_generic_synopsis(value: str) -> bool:
    normalized = value.strip()
    return not normalized or normalized == "未抓取到简介，建议后续针对目标站点补充规则。"


def _apply_payload_metadata_to_preview(preview: PreviewResponse, payload: AddBookPayload) -> PreviewResponse:
    updates: dict[str, object] = {}
    payload_title = _clean_payload_metadata(payload.title)
    payload_synopsis = _clean_payload_metadata(getattr(payload, "synopsis", ""))
    payload_cover = _clean_payload_metadata(getattr(payload, "cover", ""))

    if payload_title and (not preview.title.strip() or preview.title == "未命名小说"):
        updates["title"] = payload_title
    if payload_synopsis and _is_generic_synopsis(preview.synopsis):
        updates["synopsis"] = payload_synopsis
    if payload_cover and not preview.cover:
        updates["cover"] = payload_cover

    return preview.model_copy(update=updates) if updates else preview


def _json_payload_from_text(text: str) -> object | None:
    normalized = text.lstrip("\ufeff").strip()
    if not normalized.startswith(("{", "[")):
        return None
    try:
        return json.loads(normalized)
    except json.JSONDecodeError:
        return None


def _find_json_value(payload: object, keys: tuple[str, ...]) -> object | None:
    if isinstance(payload, dict):
        for key in keys:
            value = payload.get(key)
            if value not in (None, ""):
                return value
        for value in payload.values():
            nested = _find_json_value(value, keys)
            if nested not in (None, ""):
                return nested
    elif isinstance(payload, list):
        for value in payload:
            nested = _find_json_value(value, keys)
            if nested not in (None, ""):
                return nested
    return None


def _json_value_text(payload: object, keys: tuple[str, ...], *, max_length: int = 0) -> str:
    value = _find_json_value(payload, keys)
    if value is None or isinstance(value, (dict, list)):
        return ""
    text = re.sub(r"\s+", " ", str(value)).strip()
    if max_length and len(text) > max_length:
        return text[:max_length].rstrip()
    return text


def _json_value_body_text(payload: object, keys: tuple[str, ...], *, max_length: int = 0) -> str:
    value = _find_json_value(payload, keys)
    if value is None or isinstance(value, (dict, list)):
        return ""
    text = str(value).replace("\r\n", "\n").replace("\r", "\n").strip()
    lines = [re.sub(r"[ \t]+", " ", line).strip() for line in text.splitlines()]
    text = "\n".join(line for line in lines if line).strip()
    if max_length and len(text) > max_length:
        return text[:max_length].rstrip()
    return text


def _json_value_url(payload: object, keys: tuple[str, ...], base_url: str) -> str | None:
    value = _find_json_value(payload, keys)
    if value is None or isinstance(value, (dict, list)):
        return None
    text = str(value).strip()
    return urljoin(base_url, text) if text else None


def _chapters_from_json_payload(payload: object, base_url: str) -> list[ChapterPreview]:
    candidates = _find_json_value(
        payload, ("chapters", "chapter_list", "chapterList", "catalog", "volume_list", "items", "data")
    )
    if not isinstance(candidates, list):
        first_chapter_content = _json_value_text(
            payload, ("first_chapter_content", "firstChapterContent"), max_length=1
        )
        if first_chapter_content:
            title = _json_value_text(
                payload,
                ("first_chapter_name", "firstChapterName", "chapter_name", "chapterName"),
                max_length=160,
            )
            return [ChapterPreview(title=title or "第一章", url=base_url)]
        return []

    chapters: list[ChapterPreview] = []
    seen: set[str] = set()
    for index, item in enumerate(candidates, start=1):
        if not isinstance(item, dict):
            continue
        title = _json_value_text(item, ("title", "chapter_title", "chapterTitle", "name"), max_length=160)
        url = _json_value_url(item, ("url", "chapter_url", "chapterUrl", "link", "href"), base_url)
        if not url:
            url = _json_chapter_url_from_ids(item, base_url)
        if not title:
            title = f"第{index}章"
        if not url or url in seen:
            continue
        seen.add(url)
        chapters.append(ChapterPreview(title=title, url=url))
    return chapters[:2000]


def _json_chapter_url_from_ids(item: dict[str, object], base_url: str) -> str:
    book_id = _json_value_text(item, ("book_id", "bookId"), max_length=80)
    chapter_id = _json_value_text(item, ("chapter_id", "chapterId", "id"), max_length=80)
    if not chapter_id:
        return ""

    parsed = urlparse(base_url)
    if book_id and "/novels/api/book/" in parsed.path:
        return f"{parsed.scheme}://{parsed.netloc}/novels/api/book/{book_id}/chapters/{chapter_id}"
    return urljoin(base_url, chapter_id)


async def _extend_json_preview_chapters(
    client: httpx.AsyncClient,
    preview: PreviewResponse,
    payload: object,
    source_url: str,
) -> PreviewResponse:
    if preview.chapterCount > 1:
        return preview

    chapters_url = _json_chapters_url(payload, source_url)
    if not chapters_url:
        return preview

    try:
        response = await client.get(chapters_url, headers=_request_headers(chapters_url, referer=source_url))
        response.raise_for_status()
    except Exception:
        return preview

    chapters_payload = _json_payload_from_text(response.text)
    if chapters_payload is None:
        return preview

    chapters = _chapters_from_json_payload(chapters_payload, chapters_url)
    if len(chapters) <= preview.chapterCount:
        return preview

    return preview.model_copy(update={"chapters": chapters, "chapterCount": len(chapters)})


def _json_chapters_url(payload: object, source_url: str) -> str:
    book_id = _json_value_text(payload, ("book_id", "bookId", "id"), max_length=80)
    if not book_id:
        return ""

    parsed = urlparse(source_url)
    path = parsed.path
    if "/novels/api/book/" in path:
        base_path = path.split("/chapters/", 1)[0]
        return f"{parsed.scheme}://{parsed.netloc}{base_path}/chapters?paging=0"
    return ""


def _preview_from_json_text(text: str, source_url: str, payload: AddBookPayload) -> PreviewResponse | None:
    data = _json_payload_from_text(text)
    if data is None:
        return None

    fallback_title = payload.title or Path(urlparse(source_url).path).stem or "未命名小说"
    title = (
        _json_value_text(data, ("book_name", "bookName", "title", "name"), max_length=120) or fallback_title
    )
    author = _json_value_text(data, ("author_name", "authorName", "author", "writer"), max_length=80) or None
    synopsis = _json_value_text(
        data, ("intro", "book_desc", "description", "desc", "abstract", "summary"), max_length=500
    )
    cover = _json_value_url(
        data, ("cover_url", "coverUrl", "cover_picture", "cover", "thumb_url", "image"), source_url
    )
    chapters = _chapters_from_json_payload(data, source_url)
    if not chapters:
        chapters = [ChapterPreview(title=title, url=source_url)]

    return PreviewResponse(
        title=title,
        author=author,
        synopsis=synopsis or "未抓取到简介，建议后续针对目标站点补充规则。",
        cover=cover,
        chapterCount=len(chapters),
        chapters=chapters,
    )


def _chapter_text_from_json_text(text: str) -> str:
    data = _json_payload_from_text(text)
    if data is None:
        return ""
    return _json_value_body_text(
        data,
        (
            "content",
            "chapter_content",
            "chapterContent",
            "body",
            "text",
            "txt",
            "book_content",
            "bookContent",
            "first_chapter_content",
            "firstChapterContent",
            "chapter_text",
            "chapterText",
            "intro",
            "description",
            "abstract",
        ),
        max_length=50000,
    )


def _collect_generic_chapter_links(anchors: list[Any], base_url: str) -> list[ChapterPreview]:
    items: list[ChapterPreview] = []
    seen: set[str] = set()
    base_host = (urlparse(base_url).hostname or "").lower()

    for anchor in anchors:
        href = str(anchor.get("href") or "").strip()
        text = anchor.get_text(" ", strip=True)
        if not href or not text or href.startswith(("javascript:", "#")):
            continue
        absolute_url = urljoin(base_url, href)
        parsed = urlparse(absolute_url)
        if base_host and (parsed.hostname or "").lower() != base_host:
            continue
        if absolute_url in seen:
            continue
        seen.add(absolute_url)
        items.append(ChapterPreview(title=text[:180], url=absolute_url))

    return items


def _extract_linovelib_chapters(soup: BeautifulSoup, base_url: str) -> list[ChapterPreview]:
    items = _extract_linovelib_volume_blocks(soup, base_url)
    if items:
        return items

    items: list[ChapterPreview] = []
    seen: set[str] = set()
    current_volume = ""

    for node in soup.select("#volumes li"):
        classes = node.get("class") or []
        text = node.get_text(" ", strip=True)
        if not text:
            continue

        if "chapter-bar" in classes:
            current_volume = text
            continue

        anchor = node.find("a", href=True)
        if anchor is None:
            continue

        href = str(anchor.get("href", "")).strip()
        chapter_title = anchor.get_text(" ", strip=True) or text
        if not href or len(chapter_title) < 1:
            continue

        absolute_url = urljoin(base_url, href)
        if absolute_url in seen:
            continue

        seen.add(absolute_url)
        if current_volume:
            chapter_title = f"{current_volume} - {chapter_title}"
        items.append(ChapterPreview(title=chapter_title[:160], url=absolute_url))

    return items


def _extract_linovelib_volume_blocks(soup: BeautifulSoup, base_url: str) -> list[ChapterPreview]:
    items: list[ChapterPreview] = []
    seen: set[str] = set()

    for volume in soup.select(".volume-list .volume"):
        volume_title = ""
        title_node = volume.select_one(".volume-info h2, h2.v-line, h3")
        if title_node and title_node.get_text(" ", strip=True):
            volume_title = title_node.get_text(" ", strip=True)

        for anchor in volume.select(".chapter-list a[href], ul.chapter-list a[href]"):
            href = str(anchor.get("href", "")).strip()
            chapter_title = anchor.get_text(" ", strip=True)
            if not href or not chapter_title or href.startswith("javascript:"):
                continue

            absolute_url = urljoin(base_url, href)
            if absolute_url in seen:
                continue

            seen.add(absolute_url)
            if volume_title:
                chapter_title = f"{volume_title} - {chapter_title}"
            items.append(ChapterPreview(title=chapter_title[:160], url=absolute_url))

    return items


def _kakuyomu_state_from_html(html: str) -> dict[str, Any]:
    soup = BeautifulSoup(html, "html.parser")
    script = soup.select_one("#__NEXT_DATA__")
    if script is None or not script.string:
        raise ValueError("Kakuyomu 页面缺少 __NEXT_DATA__ 数据")
    payload = json.loads(script.string)
    page_props = payload.get("props", {}).get("pageProps", {})
    state = page_props.get("__APOLLO_STATE__")
    if not isinstance(state, dict) or not state:
        raise ValueError("Kakuyomu 页面缺少 __APOLLO_STATE__ 数据")
    return state


def _kakuyomu_work_id_from_url(url: str) -> str | None:
    match = KAKUYOMU_WORK_PATH_PATTERN.match(urlparse(url).path)
    return match.group("work_id") if match else None


def _kakuyomu_work_from_state(state: dict[str, Any], work_id: str) -> dict[str, Any]:
    work = state.get(f"Work:{work_id}")
    if not isinstance(work, dict):
        raise ValueError("未能在 Kakuyomu 页面中定位作品信息")
    return work


def _kakuyomu_author_from_state(state: dict[str, Any], work: dict[str, Any]) -> str | None:
    author_ref = work.get("author", {})
    if isinstance(author_ref, dict):
        author = state.get(str(author_ref.get("__ref") or ""))
        if isinstance(author, dict):
            for key in ("activityName", "name", "screenName"):
                value = str(author.get(key) or "").strip()
                if value:
                    return value
    return None


def _kakuyomu_synopsis_from_work(work: dict[str, Any]) -> str:
    catchphrase = str(work.get("catchphrase") or "").strip()
    introduction = str(work.get("introduction") or "").strip()
    return _append_prefixed_text(catchphrase, introduction)


def _kakuyomu_chapters_from_state(
    state: dict[str, Any], work_id: str, work: dict[str, Any]
) -> list[ChapterPreview]:
    items: list[ChapterPreview] = []
    seen: set[str] = set()
    origin = "https://kakuyomu.jp"

    for toc_ref in work.get("tableOfContents", []):
        ref_key = toc_ref.get("__ref") if isinstance(toc_ref, dict) else None
        toc = state.get(str(ref_key or ""))
        if not isinstance(toc, dict):
            continue

        chapter_title = ""
        chapter_ref = toc.get("chapter")
        if isinstance(chapter_ref, dict):
            chapter_meta = state.get(str(chapter_ref.get("__ref") or ""))
            if isinstance(chapter_meta, dict):
                chapter_title = str(chapter_meta.get("title") or chapter_meta.get("name") or "").strip()

        for episode_ref in toc.get("episodeUnions", []):
            episode_key = episode_ref.get("__ref") if isinstance(episode_ref, dict) else None
            episode = state.get(str(episode_key or ""))
            if not isinstance(episode, dict):
                continue
            episode_id = str(episode.get("id") or "").strip()
            episode_title = str(episode.get("title") or "").strip()
            if not episode_id or not episode_title:
                continue
            title = f"{chapter_title} - {episode_title}" if chapter_title else episode_title
            chapter_url = f"{origin}/works/{work_id}/episodes/{episode_id}"
            if chapter_url in seen:
                continue
            seen.add(chapter_url)
            items.append(ChapterPreview(title=title[:180], url=chapter_url))

    return items


def _pixiv_novel_id_from_url(url: str) -> str | None:
    parsed = urlparse(url)
    if parsed.path != "/novel/show.php":
        return None
    novel_id = parse_qs(parsed.query).get("id", [""])[0].strip()
    return novel_id or None


def _pixiv_series_id_from_url(url: str) -> str | None:
    match = PIXIV_SERIES_PATH_PATTERN.match(urlparse(url).path)
    return match.group("series_id") if match else None


def _pixiv_artwork_id_from_url(url: str) -> str | None:
    match = PIXIV_ARTWORK_PATH_PATTERN.match(urlparse(url).path)
    return match.group("artwork_id") if match else None


def _pixiv_comic_work_id_from_url(url: str) -> str | None:
    match = PIXIV_COMIC_WORK_PATH_PATTERN.match(urlparse(url).path)
    return match.group("work_id") if match else None


def _pixiv_comic_story_id_from_url(url: str) -> str | None:
    match = PIXIV_COMIC_STORY_PATH_PATTERN.match(urlparse(url).path)
    return match.group("story_id") if match else None


def _pixiv_api_headers(referer: str | None = None) -> dict[str, str]:
    return {
        "User-Agent": DEFAULT_HEADERS["User-Agent"],
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "ja,en;q=0.9",
        "Referer": referer or "https://www.pixiv.net/",
    }


def _pixiv_comic_api_headers(referer: str) -> dict[str, str]:
    return {
        "User-Agent": DEFAULT_HEADERS["User-Agent"],
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "ja,en;q=0.9",
        "Referer": referer,
        "X-Requested-With": "XMLHttpRequest",
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-origin",
    }


async def _fetch_pixiv_comic_api(
    client: httpx.AsyncClient,
    url: str,
    referer: str,
    *,
    headers: dict[str, str] | None = None,
) -> dict[str, Any]:
    request_headers = _pixiv_comic_api_headers(referer)
    if headers:
        request_headers.update(headers)
    response = await client.get(url, headers=request_headers)
    response.raise_for_status()
    payload = response.json()
    if not isinstance(payload, dict):
        raise ValueError("Pixiv Comic 接口返回了无法识别的数据结构")
    error = payload.get("error")
    if error:
        if isinstance(error, dict):
            message = str(error.get("user_message") or error.get("system_message") or "").strip()
        else:
            message = str(error).strip()
        raise ValueError(message or "Pixiv Comic 接口返回错误")
    data = payload.get("data")
    if not isinstance(data, dict):
        raise ValueError("Pixiv Comic 接口缺少 data 数据")
    return payload


async def _fetch_json(client: httpx.AsyncClient, url: str, headers: dict[str, str]) -> dict[str, Any]:
    response = await client.get(url, headers=headers)
    response.raise_for_status()
    payload = response.json()
    if payload.get("error"):
        raise ValueError(str(payload.get("message") or "目标站点返回错误"))
    body = payload.get("body")
    if not isinstance(body, (dict, list)):
        raise ValueError("目标站点返回了无法识别的数据结构")
    return {"body": body, "url": str(response.url)}


def _pixiv_content_to_text(content: str) -> str:
    value = content.replace("\r\n", "\n").replace("\r", "\n")
    value = value.replace("[newpage]", "\n\n")
    value = re.sub(r"\[\[rb:([^>]+)\s*>\s*([^\]]+)\]\]", r"\1(\2)", value)
    value = re.sub(r"\[\[jumpuri:([^>]+)\s*>\s*([^\]]+)\]\]", r"\1(\2)", value)
    value = re.sub(r"\[jump:(\d+)\]", "", value)
    value = re.sub(r"\[chapter:[^\]]+\]", "", value)
    value = re.sub(r"\n{3,}", "\n\n", value)
    return value.strip()


def _extract_pixiv_image_urls(body: dict[str, Any]) -> list[str]:
    image_urls: list[str] = []
    for bucket_key in ("textEmbeddedImages", "contentImages"):
        bucket = body.get(bucket_key)
        if not isinstance(bucket, dict):
            continue
        for item in bucket.values():
            if not isinstance(item, dict):
                continue
            urls = item.get("urls")
            if isinstance(urls, dict):
                for key in ("original", "1200x1200", "regular", "small"):
                    candidate = str(urls.get(key) or "").strip()
                    if candidate and candidate not in image_urls:
                        image_urls.append(candidate)
                        break
            else:
                candidate = str(item.get("originalUrl") or item.get("url") or "").strip()
                if candidate and candidate not in image_urls:
                    image_urls.append(candidate)
    return image_urls


def _syosetu_chapters_from_soup(soup: BeautifulSoup, base_url: str) -> list[ChapterPreview]:
    items: list[ChapterPreview] = []
    seen: set[str] = set()
    current_heading = ""

    for node in soup.select(".p-eplist > *"):
        classes = node.get("class") or []
        if "p-eplist__chapter-title" in classes:
            current_heading = node.get_text(" ", strip=True)
            continue
        if "p-eplist__sublist" not in classes:
            continue
        anchor = node.select_one("a[href]")
        if anchor is None:
            continue
        href = str(anchor.get("href") or "").strip()
        title = anchor.get_text(" ", strip=True)
        if not href or not title:
            continue
        absolute_url = urljoin(base_url, href)
        if absolute_url in seen:
            continue
        seen.add(absolute_url)
        if current_heading:
            title = f"{current_heading} - {title}"
        items.append(ChapterPreview(title=title[:180], url=absolute_url))

    if items:
        return items

    current_heading = ""
    for node in soup.select(".index_box > *, .novel_sublist2, .novel_sublist, .chapter_title"):
        classes = node.get("class") or []
        class_text = " ".join(classes)
        if "chapter_title" in class_text:
            current_heading = node.get_text(" ", strip=True)
            continue

        anchor = node.select_one("a[href]")
        if anchor is None:
            continue
        href = str(anchor.get("href") or "").strip()
        title = anchor.get_text(" ", strip=True)
        if not href or not title:
            continue
        absolute_url = urljoin(base_url, href)
        if absolute_url in seen:
            continue
        seen.add(absolute_url)
        if current_heading and current_heading not in title:
            title = f"{current_heading} - {title}"
        items.append(ChapterPreview(title=title[:180], url=absolute_url))

    return items


def _hameln_chapters_from_soup(soup: BeautifulSoup, base_url: str) -> list[ChapterPreview]:
    items: list[ChapterPreview] = []
    seen: set[str] = set()

    for anchor in soup.select("table tr a[href$='.html']"):
        href = str(anchor.get("href") or "").strip()
        title = anchor.get_text(" ", strip=True)
        if not href or not title:
            continue
        absolute_url = urljoin(base_url, href)
        if absolute_url in seen:
            continue
        seen.add(absolute_url)
        items.append(ChapterPreview(title=title[:180], url=absolute_url))

    return items


def _hameln_author_from_soup(soup: BeautifulSoup) -> str | None:
    first_info = soup.select_one("#maind .ss p")
    if first_info is None:
        return None
    text = first_info.get_text(" ", strip=True)
    match = re.search(r"作者：\s*([^\s×]+)", text)
    return match.group(1).strip() if match else None


def _hameln_chapter_text(soup: BeautifulSoup) -> str:
    body = soup.select_one("#honbun")
    if body is None:
        return ""
    parts = [body.get_text("\n", strip=True)]
    afterword = soup.select_one("#atogaki")
    if afterword is not None:
        afterword_text = afterword.get_text("\n", strip=True)
        if afterword_text:
            parts.append(f"【后记】\n{afterword_text}")
    return "\n\n".join(part.strip() for part in parts if part.strip()).strip()


def load_manifest(book_dir: Path) -> dict:
    manifest_path = book_dir / "manifest.json"
    if not manifest_path.exists():
        return {}

    try:
        return json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def save_manifest(book_dir: Path, manifest: dict) -> None:
    (book_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def build_translated_filename(filename: str) -> str:
    chapter_path = Path(filename)
    return f"{chapter_path.stem}.translated.txt"


def build_translated_meta_filename(filename: str) -> str:
    chapter_path = Path(filename)
    return f"{chapter_path.stem}.translated.json"


def build_translated_image_asset_path(asset_path: str) -> str:
    image_path = Path(asset_path)
    translated_path = image_path.with_name(f"{image_path.stem}.translated.png")
    return translated_path.as_posix()


def chapter_text_path(book_dir: Path, filename: str) -> Path:
    return book_dir / filename


def translated_text_path(book_dir: Path, filename: str) -> Path:
    return book_dir / build_translated_filename(filename)


def translated_meta_path(book_dir: Path, filename: str) -> Path:
    return book_dir / build_translated_meta_filename(filename)


def translated_checkpoint_path(book_dir: Path, filename: str) -> Path:
    return Path(f"{translated_meta_path(book_dir, filename)}.part")


def _manga_translation_source_signatures(
    book_dir: Path,
    image_files: list[str],
) -> list[dict[str, int | str]]:
    signatures: list[dict[str, int | str]] = []
    for asset_path in image_files:
        source_path = (book_dir / asset_path).resolve()
        stat = source_path.stat()
        signatures.append(
            {
                "path": asset_path,
                "size": stat.st_size,
                "mtime_ns": stat.st_mtime_ns,
            }
        )
    return signatures


def _write_manga_translation_checkpoint(
    checkpoint_path: Path,
    *,
    book_dir: Path,
    base_url: str,
    model: str,
    target_language: str,
    image_files: list[str],
    pages: list[MangaTranslatedPagePayload],
) -> None:
    payload = {
        "version": 1,
        "renderer_version": MANGA_RENDERER_VERSION,
        "base_url": base_url,
        "model": model,
        "target_language": target_language,
        "source_signatures": _manga_translation_source_signatures(book_dir, image_files),
        "pages": [page.model_dump(mode="python", exclude_none=True) for page in pages],
    }
    checkpoint_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = Path(f"{checkpoint_path}.tmp")
    temporary_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    temporary_path.replace(checkpoint_path)


def _load_manga_translation_checkpoint(
    checkpoint_path: Path,
    *,
    book_dir: Path,
    base_url: str,
    model: str,
    target_language: str,
    image_files: list[str],
) -> list[MangaTranslatedPagePayload]:
    if not checkpoint_path.exists():
        return []
    try:
        raw_payload = json.loads(checkpoint_path.read_text(encoding="utf-8"))
        expected_signatures = _manga_translation_source_signatures(book_dir, image_files)
    except (OSError, ValueError, json.JSONDecodeError):
        checkpoint_path.unlink(missing_ok=True)
        return []
    if not isinstance(raw_payload, dict) or any(
        (
            raw_payload.get("version") != 1,
            raw_payload.get("renderer_version") != MANGA_RENDERER_VERSION,
            raw_payload.get("base_url") != base_url,
            raw_payload.get("model") != model,
            raw_payload.get("target_language") != target_language,
            raw_payload.get("source_signatures") != expected_signatures,
        )
    ):
        checkpoint_path.unlink(missing_ok=True)
        return []

    raw_pages = raw_payload.get("pages")
    if not isinstance(raw_pages, list):
        checkpoint_path.unlink(missing_ok=True)
        return []

    resolved_book_dir = book_dir.resolve()
    pages: list[MangaTranslatedPagePayload] = []
    for page_number, asset_path in enumerate(image_files, start=1):
        if page_number > len(raw_pages) or not isinstance(raw_pages[page_number - 1], dict):
            break
        try:
            page = MangaTranslatedPagePayload.model_validate(raw_pages[page_number - 1])
        except Exception:
            break
        translated_asset_path = build_translated_image_asset_path(asset_path)
        translated_image_path = (book_dir / translated_asset_path).resolve()
        if (
            page.page_number != page_number
            or page.source_image_file != asset_path
            or page.translated_image_file != translated_asset_path
            or not translated_image_path.is_relative_to(resolved_book_dir)
            or not is_valid_image_file(translated_image_path)
        ):
            break
        pages.append(page)
    return pages


def _load_translated_page_metadata(book_dir: Path, filename: str) -> dict[str, Any]:
    payload_path = translated_meta_path(book_dir, filename)
    if not payload_path.exists():
        return {}
    try:
        payload = json.loads(payload_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    return payload if isinstance(payload, dict) else {}


def _load_translated_page_payload_models(book_dir: Path, filename: str) -> list[MangaTranslatedPagePayload]:
    payload = _load_translated_page_metadata(book_dir, filename)
    translated_pages = payload.get("translated_pages")
    if not isinstance(translated_pages, list):
        return []

    parsed_pages: list[MangaTranslatedPagePayload] = []
    for item in translated_pages:
        if not isinstance(item, dict):
            continue
        try:
            parsed_pages.append(MangaTranslatedPagePayload.model_validate(item))
        except Exception:
            continue
    return parsed_pages


def load_manga_translation_page_payloads(
    book_dir: Path,
    filename: str,
    *,
    include_final: bool = True,
) -> list[MangaTranslatedPagePayload]:
    """Return completed page results from an active checkpoint or final metadata."""
    checkpoint_path = translated_checkpoint_path(book_dir, filename)
    if checkpoint_path.exists():
        try:
            checkpoint = json.loads(checkpoint_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            checkpoint = {}
        raw_pages = checkpoint.get("pages") if isinstance(checkpoint, dict) else None
        if isinstance(raw_pages, list):
            pages: list[MangaTranslatedPagePayload] = []
            for expected_page_number, item in enumerate(raw_pages, start=1):
                if not isinstance(item, dict):
                    break
                try:
                    page = MangaTranslatedPagePayload.model_validate(item)
                except Exception:
                    break
                if page.page_number != expected_page_number:
                    break
                pages.append(page)
            if pages:
                return pages
    return _load_translated_page_payload_models(book_dir, filename) if include_final else []


def load_translated_page_payload(book_dir: Path, filename: str) -> list[str]:
    payload = _load_translated_page_metadata(book_dir, filename)
    page_translations = payload.get("page_translations")
    if isinstance(page_translations, list):
        return [str(item).strip() for item in page_translations if isinstance(item, str)]
    return [
        page.page_translation.strip()
        for page in _load_translated_page_payload_models(book_dir, filename)
        if page.page_translation.strip()
    ]


def translated_image_payload_is_current(book_dir: Path, filename: str) -> bool:
    payload = _load_translated_page_metadata(book_dir, filename)
    try:
        renderer_version = int(payload.get("renderer_version") or 0)
    except (TypeError, ValueError):
        renderer_version = 0
    return renderer_version >= MANGA_RENDERER_VERSION


def save_translated_page_payload(
    book_dir: Path,
    filename: str,
    page_translations: list[str],
    translated_image_files: list[str] | None = None,
    translated_pages: list[MangaTranslatedPagePayload] | None = None,
) -> str:
    resolved_page_translations = [str(item).strip() for item in page_translations if str(item).strip()]
    resolved_translated_image_files = [
        str(item).strip() for item in (translated_image_files or []) if str(item).strip()
    ]
    if translated_pages and not resolved_page_translations:
        resolved_page_translations = [
            page.page_translation.strip() for page in translated_pages if page.page_translation.strip()
        ]
    if translated_pages and not resolved_translated_image_files:
        resolved_translated_image_files = [
            str(page.translated_image_file or "").strip()
            for page in translated_pages
            if str(page.translated_image_file or "").strip()
        ]

    target_path = translated_meta_path(book_dir, filename)
    payload: dict[str, Any] = {
        "page_translations": resolved_page_translations,
        "renderer_version": MANGA_RENDERER_VERSION,
    }
    if translated_image_files is not None:
        payload["translated_image_files"] = resolved_translated_image_files
    if translated_pages is not None:
        payload["translated_pages"] = [
            page.model_dump(mode="python", exclude_none=True) for page in translated_pages
        ]
        payload["page_count"] = len(translated_pages)
        if translated_pages:
            payload["target_language"] = translated_pages[0].target_language
    target_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return target_path.name


async def translate_single_manga_image(
    *,
    image_bytes: bytes,
    original_name: str,
    target_language: str,
    settings: TranslationSettings,
    title: str = "单图翻译",
    log_callback: Callable[[str, str], Awaitable[None] | None] | None = None,
) -> tuple[bytes, str]:
    if not image_bytes:
        raise ValueError("漫画图片文件为空")

    safe_name = Path(original_name or "upload.png").name
    fallback_extension = Path(safe_name).suffix.lower() or ".png"
    extension = _image_extension_from_bytes(image_bytes, fallback_extension)
    workspace_dir = DATA_DIR / "tmp" / "image-translate" / f"image-{secrets.token_hex(8)}"
    workspace_dir.mkdir(parents=True, exist_ok=False)

    try:
        source_asset_path = f"images/0001-01-upload{extension}"
        source_image_path = workspace_dir / source_asset_path
        source_image_path.parent.mkdir(parents=True, exist_ok=True)
        source_image_path.write_bytes(image_bytes)

        (
            page_translations,
            translated_image_files,
            translated_pages,
        ) = await _translate_manga_pages_with_command_detailed(
            settings=settings,
            target_language=target_language,
            chapter_index=1,
            title=title.strip() or Path(safe_name).stem or "单图翻译",
            image_files=[source_asset_path],
            book_dir=workspace_dir,
            log_callback=log_callback,
        )
        if not translated_image_files:
            raise RuntimeError("漫画单图翻译未生成输出图片")

        translated_image_path = (workspace_dir / translated_image_files[0]).resolve()
        if not translated_image_path.exists() or not translated_image_path.is_file():
            raise RuntimeError(f"漫画单图翻译输出不存在：{translated_image_files[0]}")

        translated_bytes = _ensure_png_image_bytes(translated_image_path.read_bytes())
        page_translation = page_translations[0].strip() if page_translations else ""
        if translated_pages:
            await _emit_single_image_diagnostics(
                log_callback=log_callback,
                page_payload=translated_pages[0],
                source_name=safe_name,
                target_language=target_language,
                trace_id=workspace_dir.name,
            )
        return translated_bytes, page_translation
    finally:
        shutil.rmtree(workspace_dir, ignore_errors=True)


def apply_downloaded_chapter_payload(manifest: dict, payload: dict) -> bool:
    chapter_index = payload.get("index")
    if not isinstance(chapter_index, int):
        return False
    chapter = _chapter_lookup(manifest).get(chapter_index)
    if chapter is None:
        return False

    chapter["file_name"] = payload["file_name"]
    chapter["downloaded"] = payload["downloaded"]
    chapter["illustration"] = payload["illustration"]
    chapter["image_urls"] = payload["image_urls"]
    chapter["image_files"] = payload["image_files"]
    chapter["translated_image_files"] = [
        item for item in payload.get("translated_image_files", []) if isinstance(item, str)
    ]
    chapter["page_count"] = payload["page_count"]
    chapter["images_repaired"] = payload.get("images_repaired", chapter.get("images_repaired"))
    chapter["content_source"] = payload.get("content_source")
    chapter["authorization_method"] = payload.get("authorization_method")
    chapter["access_restricted"] = bool(payload.get("access_restricted"))
    chapter["download_error"] = None
    chapter["translated_file_name"] = chapter.get("translated_file_name") or build_translated_filename(
        payload["file_name"]
    )
    chapter["translated_meta_file_name"] = chapter.get(
        "translated_meta_file_name"
    ) or build_translated_meta_filename(payload["file_name"])
    return True


async def download_chapter_payload(
    book_dir: Path,
    manifest: dict,
    chapter_index: int,
    *,
    qidian_cookies: dict[str, str] | None = None,
) -> dict:
    chapter = _chapter_lookup(manifest).get(chapter_index)
    if chapter is None:
        raise ValueError(f"章节不存在：{chapter_index}")

    image_concurrency = _image_download_concurrency(str(manifest.get("source_url") or ""), 1)
    async with _build_http_client() as client:
        return await _download_single_chapter(
            client,
            book_dir,
            chapter_index,
            chapter,
            image_download_semaphore=asyncio.Semaphore(image_concurrency),
            qidian_cookies=qidian_cookies,
        )


async def download_selected_chapters(
    book_dir: Path,
    manifest: dict,
    chapter_indexes: list[int],
    concurrency: int = 1,
    progress_callback: Callable[[int, int, list[str]], Awaitable[None] | None] | None = None,
    *,
    qidian_cookies: dict[str, str] | None = None,
) -> dict:
    chapter_lookup = _chapter_lookup(manifest)
    selected_indexes = [
        chapter_index for chapter_index in chapter_indexes if chapter_lookup.get(chapter_index)
    ]
    if not selected_indexes:
        return manifest

    concurrency = max(1, concurrency)
    image_concurrency = _image_download_concurrency(str(manifest.get("source_url") or ""), concurrency)
    updated = False
    completed_count = 0
    total_count = len(selected_indexes)
    active_titles: dict[int, str] = {}
    semaphore = asyncio.Semaphore(concurrency)
    image_download_semaphore = asyncio.Semaphore(image_concurrency)

    async with _build_http_client() as client:

        async def worker(chapter_index: int) -> dict:
            chapter = chapter_lookup[chapter_index]
            chapter_title = str(chapter.get("title") or f"第{chapter_index}章")
            async with semaphore:
                active_titles[chapter_index] = chapter_title
                await _notify_download_progress(
                    progress_callback, completed_count, total_count, list(active_titles.values())
                )
                try:
                    return await _download_single_chapter(
                        client,
                        book_dir,
                        chapter_index,
                        chapter,
                        image_download_semaphore=image_download_semaphore,
                        qidian_cookies=qidian_cookies,
                    )
                finally:
                    active_titles.pop(chapter_index, None)

        pending_tasks = [asyncio.create_task(worker(chapter_index)) for chapter_index in selected_indexes]
        try:
            for pending_task in asyncio.as_completed(pending_tasks):
                payload = await pending_task
                apply_downloaded_chapter_payload(manifest, payload)
                completed_count += 1
                updated = True
                save_manifest(book_dir, manifest)
                await _notify_download_progress(
                    progress_callback, completed_count, total_count, list(active_titles.values())
                )
        except Exception:
            for task in pending_tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*pending_tasks, return_exceptions=True)
            raise

    if updated:
        save_manifest(book_dir, manifest)

    return manifest


async def _notify_download_progress(
    progress_callback: Callable[[int, int, list[str]], Awaitable[None] | None] | None,
    completed_count: int,
    total_count: int,
    active_titles: list[str],
) -> None:
    if progress_callback is None:
        return
    result = progress_callback(completed_count, total_count, active_titles)
    if result is not None:
        await result


async def _download_single_chapter(
    client: httpx.AsyncClient,
    book_dir: Path,
    chapter_index: int,
    chapter: dict,
    *,
    image_download_semaphore: asyncio.Semaphore | None = None,
    qidian_cookies: dict[str, str] | None = None,
) -> dict:
    filename = str(chapter.get("file_name") or f"{chapter_index:04d}-chapter-{chapter_index}.txt")
    source_url = str(chapter.get("url") or "").strip()
    chapter_title = str(chapter.get("title") or f"第{chapter_index}章")
    existing_path = chapter_text_path(book_dir, filename)

    if not source_url:
        return {
            "index": chapter_index,
            "file_name": filename,
            "downloaded": existing_path.exists(),
            "illustration": bool(chapter.get("illustration")),
            "image_urls": [item for item in chapter.get("image_urls", []) if isinstance(item, str)],
            "image_files": [item for item in chapter.get("image_files", []) if isinstance(item, str)],
            "translated_image_files": [
                item for item in chapter.get("translated_image_files", []) if isinstance(item, str)
            ],
            "page_count": int(
                chapter.get("page_count")
                or len(chapter.get("image_files", []))
                or len(chapter.get("image_urls", []))
                or 0
            ),
            "images_repaired": bool(chapter.get("images_repaired")),
            "content_source": chapter.get("content_source"),
            "authorization_method": chapter.get("authorization_method"),
            "access_restricted": bool(chapter.get("access_restricted")),
        }

    if qidian_cookies is None:
        result = await _fetch_chapter_data(client, source_url, chapter_title)
    else:
        result = await _fetch_chapter_data(
            client,
            source_url,
            chapter_title,
            qidian_cookies=qidian_cookies,
        )
    image_files = await _download_chapter_images(
        client,
        book_dir,
        chapter_index,
        result.image_urls,
        source_url,
        image_download_semaphore=image_download_semaphore,
    )
    existing_path.write_text(result.text, encoding="utf-8")
    return {
        "index": chapter_index,
        "file_name": filename,
        "downloaded": True,
        "illustration": result.illustration,
        "image_urls": result.image_urls,
        "image_files": image_files,
        "translated_image_files": [],
        "page_count": len(image_files) or len(result.image_urls),
        "images_repaired": _is_18comic_url(source_url),
        "content_source": result.content_source,
        "authorization_method": result.authorization_method,
        "access_restricted": bool(chapter.get("access_restricted")) or result.access_restricted,
    }


async def translate_selected_chapters(
    book_dir: Path,
    manifest: dict,
    chapter_indexes: list[int],
    language: str,
    settings: TranslationSettings,
    log_callback: Callable[[str, str], Awaitable[None] | None] | None = None,
    progress_callback: Callable[[int, int], Awaitable[None] | None] | None = None,
) -> dict:
    chapter_lookup = _chapter_lookup(manifest)
    updated = False
    is_manga = str(manifest.get("book_kind") or "").strip() == "漫画"

    if is_manga:
        for chapter_index in chapter_indexes:
            chapter = chapter_lookup.get(chapter_index)
            if not chapter:
                continue
            filename = str(chapter.get("file_name") or f"{chapter_index:04d}-chapter-{chapter_index}.txt")
            source_path = chapter_text_path(book_dir, filename)
            if not source_path.exists():
                raise ValueError(f"章节未下载，无法翻译：{chapter_index}")
            translated_filename = build_translated_filename(filename)
            translated_meta_filename = build_translated_meta_filename(filename)
            checkpoint_path = translated_checkpoint_path(book_dir, filename)
            source_title = str(chapter.get("title") or f"第{chapter_index}章")
            repair_18comic_chapter_images(book_dir, manifest, chapter_index)
            (
                page_translations,
                translated_image_files,
                translated_pages,
            ) = await _translate_manga_pages_with_command_detailed(
                settings=settings,
                target_language=language,
                chapter_index=chapter_index,
                title=source_title,
                image_files=[item for item in chapter.get("image_files", []) if isinstance(item, str)],
                book_dir=book_dir,
                log_callback=log_callback,
                progress_callback=progress_callback,
                checkpoint_path=checkpoint_path,
            )
            translated_text = _merge_page_translations(source_title, page_translations)
            save_translated_page_payload(
                book_dir,
                filename,
                page_translations,
                translated_image_files,
                translated_pages=translated_pages,
            )
            checkpoint_path.unlink(missing_ok=True)
            chapter["translated_meta_file_name"] = translated_meta_filename
            chapter["translated_image_files"] = translated_image_files
            chapter["translated"] = True
            chapter["translated_file_name"] = translated_filename
            translated_text_path(book_dir, filename).write_text(translated_text, encoding="utf-8")
            updated = True
    else:
        _resolve_openai_compatible_model_config(settings, feature_name="翻译")

        async with _create_model_http_client(timeout=120.0) as client:
            for chapter_index in chapter_indexes:
                chapter = chapter_lookup.get(chapter_index)
                if not chapter:
                    continue

                filename = str(chapter.get("file_name") or f"{chapter_index:04d}-chapter-{chapter_index}.txt")
                source_path = chapter_text_path(book_dir, filename)
                if not source_path.exists():
                    raise ValueError(f"章节未下载，无法翻译：{chapter_index}")

                translated_filename = build_translated_filename(filename)
                source_title = str(chapter.get("title") or f"第{chapter_index}章")
                source_text = source_path.read_text(encoding="utf-8")
                translated_text = await _translate_text(
                    client=client,
                    settings=settings,
                    target_language=language,
                    title=source_title,
                    content=source_text,
                )
                chapter["translated_image_files"] = []
                chapter["translated"] = True
                chapter["translated_file_name"] = translated_filename
                translated_text_path(book_dir, filename).write_text(translated_text, encoding="utf-8")
                updated = True

    if updated:
        save_manifest(book_dir, manifest)

    return manifest


async def _notify_task_log(
    log_callback: Callable[[str, str], Awaitable[None] | None] | None,
    level: str,
    message: str,
) -> None:
    if log_callback is None:
        return
    result = log_callback(level, message)
    if result is not None:
        await result


def _resolve_translation_target_language(language: str) -> str:
    normalized = str(language or "").strip()
    if normalized in {"中文", "英文", "日文"}:
        return normalized
    return "中文"


def _normalize_openai_compatible_base_url(value: str) -> str:
    return normalize_openai_compatible_base_url(value)


def _resolve_openai_compatible_model_config(
    settings: TranslationSettings,
    *,
    feature_name: str,
) -> tuple[str, str, str]:
    return resolve_openai_compatible_model_config(settings, feature_name=feature_name)


def _resolve_manga_image_provider_config(settings: TranslationSettings) -> tuple[str, str, str]:
    return _resolve_openai_compatible_model_config(settings, feature_name="漫画译图")


def _has_custom_manga_ocr_config(settings: TranslationSettings) -> bool:
    return bool(settings.mangaOcr.enabled)


def _resolve_manga_ocr_config(
    settings: TranslationSettings,
    *,
    fallback_base_url: str,
    fallback_api_key: str,
) -> tuple[str, str]:
    ocr_config = settings.mangaOcr
    if not ocr_config.enabled:
        return fallback_base_url, fallback_api_key

    base_url = str(ocr_config.baseUrl or "").strip().rstrip("/")
    api_key = str(ocr_config.apiKey or "").strip()

    if not base_url:
        raise ValueError("漫画 OCR 接口地址未配置")
    base_host = (urlparse(base_url).hostname or "").lower()
    if base_host in {"example.com", "www.example.com", "your-newapi-endpoint"}:
        raise ValueError("漫画 OCR 接口地址仍是占位值，请先在设置中填写真实 API 地址")

    return base_url, api_key


def _should_force_manga_ocr_pipeline(settings: TranslationSettings) -> bool:
    return _has_custom_manga_ocr_config(settings)


def _build_manga_image_edit_prompt(
    *,
    target_language: str,
    chapter_title: str,
    chapter_index: int,
    page_number: int,
    total_pages: int,
) -> str:
    return (
        "Edit this manga page in place.\n"
        f"- Auto-detect the original language and translate all visible text into {target_language}.\n"
        "- Remove the original text completely and replace it with the translated text directly inside the image.\n"
        "- Keep panel layout, character art, bubble shapes, reading order, line art, screentone, and background unchanged.\n"
        "- Keep translated text inside the original bubble or caption region whenever possible.\n"
        "- Match the original text emphasis and approximate placement.\n"
        "- If a region has no readable text, keep that region unchanged.\n"
        "- Return exactly one fully edited manga page image.\n"
        f"Context: chapter_index={chapter_index}, chapter_title={chapter_title}, page={page_number}/{total_pages}"
    )


def _summarize_image_api_error(response: httpx.Response) -> str:
    try:
        payload = response.json()
    except ValueError:
        payload = None

    if isinstance(payload, dict):
        error = payload.get("error")
        if isinstance(error, dict):
            message = str(error.get("message") or "").strip()
            code = str(error.get("code") or "").strip()
            if message and code:
                return f"{message} ({code})"
            if message:
                return message
        detail = str(payload.get("detail") or payload.get("message") or "").strip()
        if detail:
            return detail

    text_value = response.text.strip()
    if text_value:
        return text_value[:400]
    return f"HTTP {response.status_code}"


def _decode_base64_image(value: str) -> bytes:
    raw_value = value.strip()
    if raw_value.startswith("data:") and "," in raw_value:
        raw_value = raw_value.split(",", 1)[1]
    return base64.b64decode(raw_value)


def _extract_image_bytes_from_payload(payload: dict[str, Any]) -> bytes | str:
    candidates: list[Any] = []
    for key in ("data", "images", "result"):
        value = payload.get(key)
        if isinstance(value, list):
            candidates.extend(value)
        elif value is not None:
            candidates.append(value)

    for item in candidates:
        if isinstance(item, dict):
            b64_value = str(item.get("b64_json") or item.get("base64") or "").strip()
            if b64_value:
                return _decode_base64_image(b64_value)
            url_value = str(item.get("url") or "").strip()
            if url_value:
                return url_value
            result_value = str(item.get("result") or "").strip()
            if result_value:
                try:
                    return _decode_base64_image(result_value)
                except Exception:
                    if result_value.startswith("http://") or result_value.startswith("https://"):
                        return result_value
        elif isinstance(item, str):
            raw_item = item.strip()
            if not raw_item:
                continue
            try:
                return _decode_base64_image(raw_item)
            except Exception:
                if raw_item.startswith("http://") or raw_item.startswith("https://"):
                    return raw_item

    raise ValueError("漫画译图接口返回中未找到可用图片数据")


def _extract_image_bytes_from_text_body(body: str) -> bytes | str | None:
    value = str(body or "").strip()
    if not value:
        return None
    if value.startswith("http://") or value.startswith("https://"):
        return value
    try:
        return _decode_base64_image(value)
    except Exception:
        return None


def _should_use_chat_completions_image_fallback(model: str) -> bool:
    lowered = str(model or "").strip().lower()
    if not lowered:
        return False
    if any(token in lowered for token in ("image", "dall-e", "flux", "sd", "stable-diffusion", "wanx")):
        return False
    return any(token in lowered for token in CHAT_COMPLETION_IMAGE_MODEL_HINTS)


def _should_fallback_from_image_edit_error(exc: Exception) -> bool:
    message = str(exc).lower()
    return (
        "http 404" in message
        or "invalid url" in message
        or "/images/edits" in message
        or "bad_response_status_code" in message
        or "not found" in message
        or "405" in message
    )


def _strip_markdown_fences(value: str) -> str:
    text_value = str(value or "").strip()
    if text_value.startswith("```"):
        text_value = re.sub(r"^```[a-zA-Z0-9_-]*\s*", "", text_value)
        text_value = re.sub(r"\s*```$", "", text_value)
    return text_value.strip()


def _extract_json_object_from_text(value: str) -> dict[str, Any]:
    cleaned = _strip_markdown_fences(value)
    if not cleaned:
        raise ValueError("模型未返回可解析的 JSON 内容")

    try:
        payload = json.loads(cleaned)
    except json.JSONDecodeError as exc:
        start = cleaned.find("{")
        end = cleaned.rfind("}")
        if start < 0 or end <= start:
            raise ValueError(f"模型返回不是有效 JSON：{cleaned[:240]}") from exc
        try:
            payload = json.loads(cleaned[start : end + 1])
        except json.JSONDecodeError as nested_exc:
            raise ValueError(
                f"模型返回的 JSON 格式错误（位置 {nested_exc.pos}）：{nested_exc.msg}"
            ) from nested_exc

    if not isinstance(payload, dict):
        raise ValueError("模型返回的 JSON 顶层不是对象")
    return payload


def _normalize_region_bbox(raw_bbox: Any, image_size: tuple[int, int]) -> tuple[int, int, int, int] | None:
    if not isinstance(raw_bbox, (list, tuple)) or len(raw_bbox) != 4:
        return None
    width, height = image_size
    try:
        x1, y1, x2, y2 = [int(round(float(item))) for item in raw_bbox]
    except (TypeError, ValueError):
        return None

    x1 = max(0, min(x1, width - 1))
    y1 = max(0, min(y1, height - 1))
    x2 = max(x1 + 1, min(x2, width))
    y2 = max(y1 + 1, min(y2, height))
    if x2 - x1 < 4 or y2 - y1 < 4:
        return None
    return x1, y1, x2, y2


def _intersect_region_bboxes(
    left: tuple[int, int, int, int] | None,
    right: tuple[int, int, int, int] | None,
) -> tuple[int, int, int, int] | None:
    if left is None:
        return right
    if right is None:
        return left
    x1 = max(left[0], right[0])
    y1 = max(left[1], right[1])
    x2 = min(left[2], right[2])
    y2 = min(left[3], right[3])
    if x2 - x1 < 4 or y2 - y1 < 4:
        return None
    return x1, y1, x2, y2


def _bbox_area(bbox: tuple[int, int, int, int] | None) -> int:
    if bbox is None:
        return 0
    return max(0, bbox[2] - bbox[0]) * max(0, bbox[3] - bbox[1])


def _bbox_iou(
    left: tuple[int, int, int, int] | None,
    right: tuple[int, int, int, int] | None,
) -> float:
    if left is None or right is None:
        return 0.0
    overlap = _intersect_region_bboxes(left, right)
    if overlap is None:
        return 0.0
    overlap_area = _bbox_area(overlap)
    if overlap_area <= 0:
        return 0.0
    union = _bbox_area(left) + _bbox_area(right) - overlap_area
    if union <= 0:
        return 0.0
    return overlap_area / union


def _bbox_smaller_overlap_ratio(
    left: tuple[int, int, int, int] | None,
    right: tuple[int, int, int, int] | None,
) -> float:
    if left is None or right is None:
        return 0.0
    overlap = _intersect_region_bboxes(left, right)
    if overlap is None:
        return 0.0
    smaller_area = min(_bbox_area(left), _bbox_area(right))
    if smaller_area <= 0:
        return 0.0
    return _bbox_area(overlap) / smaller_area


def _manga_region_identity_key(region: MangaOcrRegion) -> tuple[str, str]:
    normalized_text = re.sub(r"\s+", "", str(region.source_text or "")).strip().lower()
    direction = str(region.direction or region.source_direction or "").strip().lower()
    return normalized_text, direction


def _manga_region_rank(region: MangaOcrRegion) -> tuple[int, int]:
    richness = 0
    if region.safe_box is not None:
        richness += 3
    if region.body_bbox is not None:
        richness += 2
    if region.direction is not None:
        richness += 1
    if region.shape is not None:
        richness += 1
    if region.background is not None:
        richness += 1
    if region.text_color is not None:
        richness += 1
    return richness, -_bbox_area(region.body_bbox or region.bbox)


def _dedupe_manga_ocr_regions(regions: list[MangaOcrRegion]) -> tuple[list[MangaOcrRegion], int]:
    deduped: list[MangaOcrRegion] = []
    dropped_count = 0
    for region in regions:
        region_key = _manga_region_identity_key(region)
        duplicate_index: int | None = None
        for index, existing in enumerate(deduped):
            if region_key != _manga_region_identity_key(existing):
                continue
            overlap = _bbox_iou(existing.body_bbox or existing.bbox, region.body_bbox or region.bbox)
            if overlap < 0.72:
                overlap = _bbox_iou(existing.bbox, region.bbox)
            if overlap >= 0.72:
                duplicate_index = index
                break
        if duplicate_index is None:
            deduped.append(region)
            continue
        dropped_count += 1
        if _manga_region_rank(region) > _manga_region_rank(deduped[duplicate_index]):
            deduped[duplicate_index] = region
    return deduped, dropped_count


def _manga_ocr_text_score(value: str) -> tuple[int, int]:
    normalized = re.sub(r"\s+", "", str(value or ""))
    readable = sum(1 for char in normalized if char.isalnum() or ord(char) > 127)
    return readable, len(normalized)


def _manga_ocr_text_key(value: str) -> str:
    return re.sub(r"[^\w\u0080-\uffff]+", "", str(value or "").lower())


def _manga_ocr_text_agrees(left: str, right: str) -> bool:
    left_key = _manga_ocr_text_key(left)
    right_key = _manga_ocr_text_key(right)
    if not left_key or not right_key:
        return False
    if left_key == right_key:
        return True
    return min(len(left_key), len(right_key)) >= 2 and (left_key in right_key or right_key in left_key)


def _hybrid_region_match_score(model_region: MangaOcrRegion, windows_region: MangaOcrRegion) -> float:
    intersection_over_union = _bbox_iou(model_region.bbox, windows_region.bbox)
    contained_ratio = _bbox_smaller_overlap_ratio(model_region.bbox, windows_region.bbox)
    if _manga_ocr_text_agrees(model_region.source_text, windows_region.source_text):
        # Repeated numbers and short labels are common on manga pages. Text alone
        # must never match boxes from distant panels, otherwise the longer text is
        # copied into an unrelated tiny box.
        if intersection_over_union >= 0.02 or contained_ratio >= 0.12:
            return 2.0 + max(intersection_over_union, contained_ratio)
        return 0.0
    if intersection_over_union >= 0.18 or contained_ratio >= 0.40:
        return max(intersection_over_union, contained_ratio)
    return 0.0


def _model_region_confirmation_score(
    primary_region: MangaOcrRegion,
    verification_region: MangaOcrRegion,
) -> float:
    if not _manga_ocr_text_agrees(primary_region.source_text, verification_region.source_text):
        return 0.0
    intersection_over_union = _bbox_iou(primary_region.bbox, verification_region.bbox)
    contained_ratio = _bbox_smaller_overlap_ratio(primary_region.bbox, verification_region.bbox)
    if intersection_over_union < 0.18 and contained_ratio < 0.40:
        return 0.0
    return max(intersection_over_union, contained_ratio)


def _confirm_hybrid_model_regions(
    primary_payload: MangaOcrPagePayload,
    verification_payload: MangaOcrPagePayload,
    windows_payload: MangaOcrPagePayload,
) -> MangaOcrPagePayload:
    confirmed_regions: list[MangaOcrRegion] = []
    for region in primary_payload.regions:
        grounded_by_windows = any(
            _hybrid_region_match_score(region, windows_region) > 0
            and _manga_ocr_text_agrees(region.source_text, windows_region.source_text)
            for windows_region in windows_payload.regions
        )
        confirmed_by_model = any(
            _model_region_confirmation_score(region, verification_region) > 0
            for verification_region in verification_payload.regions
        )
        if grounded_by_windows or confirmed_by_model:
            confirmed_regions.append(region)

    normalized_regions = [
        region.model_copy(update={"order": index}) for index, region in enumerate(confirmed_regions, start=1)
    ]
    diagnostics = dict(primary_payload.diagnostics or {})
    diagnostics["vision_confirmation_region_count"] = len(verification_payload.regions)
    diagnostics["vision_confirmation_rejected_region_count"] = len(primary_payload.regions) - len(
        normalized_regions
    )
    diagnostics["vision_confirmation_final_region_count"] = len(normalized_regions)
    return primary_payload.model_copy(update={"regions": normalized_regions, "diagnostics": diagnostics})


def _merge_hybrid_manga_ocr_payloads(
    model_payload: MangaOcrPagePayload,
    windows_payload: MangaOcrPagePayload,
    *,
    include_unmatched_model_regions: bool = True,
) -> MangaOcrPagePayload:
    windows_regions = list(windows_payload.regions)
    windows_groups: dict[int, list[MangaOcrRegion]] = {}
    unmatched_model_regions: list[MangaOcrRegion] = []

    for model_region in model_payload.regions:
        best_index: int | None = None
        best_match_score = 0.0
        for index, windows_region in enumerate(windows_regions):
            match_score = _hybrid_region_match_score(model_region, windows_region)
            if match_score > best_match_score:
                best_match_score = match_score
                best_index = index
        if best_index is None:
            unmatched_model_regions.append(model_region)
            continue
        windows_groups.setdefault(best_index, []).append(model_region)

    ordered_entries: list[tuple[int, MangaOcrRegion]] = (
        [(region.order, region) for region in unmatched_model_regions]
        if include_unmatched_model_regions
        else []
    )
    hybrid_merged_region_count = 0
    for index, windows_region in enumerate(windows_regions):
        model_group = windows_groups.get(index, [])
        if not model_group:
            ordered_entries.append((windows_region.order, windows_region))
            continue
        hybrid_merged_region_count += len(model_group)
        candidates = [windows_region, *model_group]
        layout_region = max(candidates, key=_manga_region_rank)
        agreeing_text_candidates = [
            region
            for region in candidates
            if region is windows_region
            or _manga_ocr_text_agrees(region.source_text, windows_region.source_text)
        ]
        text_region = max(
            agreeing_text_candidates,
            key=lambda region: _manga_ocr_text_score(region.source_text),
        )
        if (
            _manga_ocr_text_score(text_region.source_text) > _manga_ocr_text_score(layout_region.source_text)
            and _bbox_area(text_region.body_bbox or text_region.bbox)
            >= _bbox_area(layout_region.body_bbox or layout_region.bbox)
            and _bbox_smaller_overlap_ratio(text_region.bbox, layout_region.bbox) >= 0.45
        ):
            # Local OCR engines often disagree on a multiline block: Windows OCR can
            # return a tiny single-line box while RapidOCR recovers the complete text.
            # Keeping the tiny box with the longer text causes incomplete erasure and
            # severe overflow, so the geometry and sampled colors must follow the
            # region that actually contains the more complete text.
            layout_region = text_region
        merged_region = layout_region.model_copy(
            update={
                "source_text": text_region.source_text,
                "source_direction": layout_region.source_direction or windows_region.source_direction,
                "direction": layout_region.direction or windows_region.direction,
            }
        )
        ordered_entries.append((min(region.order for region in model_group), merged_region))

    merged_regions = [region for _, region in sorted(ordered_entries, key=lambda item: item[0])]

    deduped_regions, deduped_count = _dedupe_manga_ocr_regions(merged_regions)
    ordered_regions = [
        region.model_copy(update={"order": index}) for index, region in enumerate(deduped_regions, start=1)
    ]
    diagnostics = {
        **dict(model_payload.diagnostics or {}),
        "ocr_backend": "hybrid_windows_openai",
        "model_region_count": len(model_payload.regions),
        "windows_region_count": len(windows_payload.regions),
        "hybrid_merged_region_count": hybrid_merged_region_count,
        "hybrid_deduped_region_count": deduped_count,
        "final_region_count": len(ordered_regions),
        "windows_ocr_engine_language": str(
            (windows_payload.diagnostics or {}).get("ocr_engine_language") or ""
        ),
    }
    return MangaOcrPagePayload(
        page_number=model_payload.page_number or windows_payload.page_number,
        image_size=model_payload.image_size or windows_payload.image_size,
        regions=ordered_regions,
        diagnostics=diagnostics,
    )


def _normalize_region_box_within(
    raw_bbox: Any,
    image_size: tuple[int, int],
    limit_bbox: tuple[int, int, int, int] | None = None,
) -> tuple[int, int, int, int] | None:
    normalized = _normalize_region_bbox(raw_bbox, image_size)
    if normalized is None:
        return None
    if limit_bbox is None:
        return normalized
    return _intersect_region_bboxes(normalized, limit_bbox)


def _shrink_absolute_bbox(
    bbox: tuple[int, int, int, int],
    inset_x: int,
    inset_y: int,
) -> tuple[int, int, int, int] | None:
    x1, y1, x2, y2 = bbox
    resolved_x = max(0, int(inset_x))
    resolved_y = max(0, int(inset_y))
    shrunk = (x1 + resolved_x, y1 + resolved_y, x2 - resolved_x, y2 - resolved_y)
    if shrunk[2] - shrunk[0] < 8 or shrunk[3] - shrunk[1] < 8:
        return None
    return shrunk


def _parse_hex_color(value: Any) -> tuple[int, int, int] | None:
    text_value = str(value or "").strip()
    if not re.fullmatch(r"#?[0-9a-fA-F]{6}", text_value):
        return None
    normalized = text_value[1:] if text_value.startswith("#") else text_value
    return tuple(int(normalized[index : index + 2], 16) for index in (0, 2, 4))


def _average_rgb_pixels(pixels: list[tuple[int, int, int]]) -> tuple[int, int, int]:
    if not pixels:
        return (255, 255, 255)
    red = sum(int(item[0]) for item in pixels) // len(pixels)
    green = sum(int(item[1]) for item in pixels) // len(pixels)
    blue = sum(int(item[2]) for item in pixels) // len(pixels)
    return red, green, blue


def _dominant_rgb_pixels(pixels: list[tuple[int, int, int]]) -> tuple[int, int, int]:
    if not pixels:
        return (255, 255, 255)
    buckets: dict[tuple[int, int, int], list[tuple[int, int, int]]] = {}
    for pixel in pixels:
        color = tuple(int(channel) for channel in pixel)
        bucket = tuple(channel // 12 for channel in color)
        buckets.setdefault(bucket, []).append(color)
    dominant = max(buckets.values(), key=len)
    return _average_rgb_pixels(dominant)


def _image_pixels(image: Image.Image) -> list[Any]:
    flattened = getattr(image, "get_flattened_data", None)
    if callable(flattened):
        return list(flattened())
    return list(image.getdata())  # pragma: no cover - Pillow < 12.1 兼容


def _sample_region_fill_color_python(
    image: Image.Image,
    bbox: tuple[int, int, int, int],
    preferred_color: Any = None,
    *,
    body_bbox: tuple[int, int, int, int] | None = None,
) -> tuple[int, int, int]:
    parsed = _parse_hex_color(preferred_color)
    if parsed is not None:
        return parsed

    width, height = image.size
    x1, y1, x2, y2 = bbox
    sample_bbox = body_bbox or bbox
    padding = max(2, min((x2 - x1) // 8, (y2 - y1) // 8, 12))
    pixels: list[tuple[int, int, int]] = []
    rgb_image = image.convert("RGB")

    center_inset_x = max(1, min(12, (sample_bbox[2] - sample_bbox[0]) // 7))
    center_inset_y = max(1, min(12, (sample_bbox[3] - sample_bbox[1]) // 7))
    center_bbox = _shrink_absolute_bbox(sample_bbox, center_inset_x, center_inset_y)
    if body_bbox is not None and center_bbox is not None:
        interior_pixels = _image_pixels(rgb_image.crop(center_bbox))
        if interior_pixels:
            high_luminance_pixels = [
                color
                for color in interior_pixels
                if _color_luminance(color) >= 176 and _color_saturation(color) <= 72
            ]
            low_luminance_pixels = [
                color
                for color in interior_pixels
                if _color_luminance(color) <= 104 and _color_saturation(color) <= 96
            ]
            minimum_count = max(16, len(interior_pixels) // 5)
            if len(high_luminance_pixels) >= minimum_count and len(low_luminance_pixels) < minimum_count:
                return _dominant_rgb_pixels(high_luminance_pixels)
            if len(low_luminance_pixels) >= minimum_count and len(high_luminance_pixels) < minimum_count:
                return _dominant_rgb_pixels(low_luminance_pixels)
            if len(high_luminance_pixels) >= len(low_luminance_pixels) * 1.25:
                return _dominant_rgb_pixels(high_luminance_pixels)
            if len(low_luminance_pixels) >= len(high_luminance_pixels) * 1.25:
                return _dominant_rgb_pixels(low_luminance_pixels)

    def append_strip(left: int, top: int, right: int, bottom: int) -> None:
        crop = rgb_image.crop((max(0, left), max(0, top), min(width, right), min(height, bottom)))
        pixels.extend(_image_pixels(crop))

    append_strip(x1 - padding, y1 - padding, x2 + padding, y1)
    append_strip(x1 - padding, y2, x2 + padding, y2 + padding)
    append_strip(x1 - padding, y1, x1, y2)
    append_strip(x2, y1, x2 + padding, y2)

    if not pixels:
        return (255, 255, 255)

    return _dominant_rgb_pixels(pixels)


def _dominant_rgb_array(pixels: Any, *, bucket_size: int = 12) -> tuple[int, int, int]:
    flattened = np.asarray(pixels, dtype=np.uint8).reshape(-1, 3)
    if flattened.size == 0:
        return (255, 255, 255)
    bucket_count = (255 // bucket_size) + 1
    buckets = flattened.astype(np.int16) // bucket_size
    bucket_codes = buckets[:, 0] * bucket_count * bucket_count + buckets[:, 1] * bucket_count + buckets[:, 2]
    counts = np.bincount(bucket_codes, minlength=bucket_count**3)
    dominant_code = int(np.argmax(counts))
    dominant = flattened[bucket_codes == dominant_code].astype(np.uint64)
    averages = dominant.sum(axis=0) // max(1, len(dominant))
    return tuple(int(value) for value in averages)


def _sample_region_fill_color_vectorized(
    image: Image.Image,
    bbox: tuple[int, int, int, int],
    preferred_color: Any = None,
    *,
    body_bbox: tuple[int, int, int, int] | None = None,
) -> tuple[int, int, int]:
    parsed = _parse_hex_color(preferred_color)
    if parsed is not None:
        return parsed

    width, height = image.size
    x1, y1, x2, y2 = bbox
    sample_bbox = body_bbox or bbox
    padding = max(2, min((x2 - x1) // 8, (y2 - y1) // 8, 12))
    rgb_image = image.convert("RGB")

    center_inset_x = max(1, min(12, (sample_bbox[2] - sample_bbox[0]) // 7))
    center_inset_y = max(1, min(12, (sample_bbox[3] - sample_bbox[1]) // 7))
    center_bbox = _shrink_absolute_bbox(sample_bbox, center_inset_x, center_inset_y)
    if body_bbox is not None and center_bbox is not None:
        interior = np.asarray(rgb_image.crop(center_bbox), dtype=np.uint8).reshape(-1, 3)
        if interior.size:
            luminance = interior[:, 0] * 0.299 + interior[:, 1] * 0.587 + interior[:, 2] * 0.114
            saturation = interior.max(axis=1) - interior.min(axis=1)
            low = interior[(luminance <= 104) & (saturation <= 96)]
            high = interior[(luminance >= 176) & (saturation <= 72)]
            minimum_count = max(16, len(interior) // 5)
            if len(high) >= minimum_count and len(low) < minimum_count:
                return _dominant_rgb_array(high)
            if len(low) >= minimum_count and len(high) < minimum_count:
                return _dominant_rgb_array(low)
            if len(high) >= len(low) * 1.25:
                return _dominant_rgb_array(high)
            if len(low) >= len(high) * 1.25:
                return _dominant_rgb_array(low)

    crop_boxes = (
        (x1 - padding, y1 - padding, x2 + padding, y1),
        (x1 - padding, y2, x2 + padding, y2 + padding),
        (x1 - padding, y1, x1, y2),
        (x2, y1, x2 + padding, y2),
    )
    strips = []
    for left, top, right, bottom in crop_boxes:
        clipped = (max(0, left), max(0, top), min(width, right), min(height, bottom))
        if clipped[2] > clipped[0] and clipped[3] > clipped[1]:
            strips.append(np.asarray(rgb_image.crop(clipped), dtype=np.uint8).reshape(-1, 3))
    return _dominant_rgb_array(np.concatenate(strips, axis=0)) if strips else (255, 255, 255)


def _sample_region_fill_color(
    image: Image.Image,
    bbox: tuple[int, int, int, int],
    preferred_color: Any = None,
    *,
    body_bbox: tuple[int, int, int, int] | None = None,
) -> tuple[int, int, int]:
    if np is None:
        return _sample_region_fill_color_python(
            image,
            bbox,
            preferred_color,
            body_bbox=body_bbox,
        )
    return _sample_region_fill_color_vectorized(
        image,
        bbox,
        preferred_color,
        body_bbox=body_bbox,
    )


def _resolve_text_color(
    fill_color: tuple[int, int, int], preferred_color: Any = None
) -> tuple[int, int, int]:
    parsed = _parse_hex_color(preferred_color)
    if parsed is not None:
        return parsed
    luminance = 0.299 * fill_color[0] + 0.587 * fill_color[1] + 0.114 * fill_color[2]
    return (24, 24, 24) if luminance >= 140 else (245, 245, 245)


# 描边宽度占字号比例：与 manga-image-translator 渲染默认值保持一致（config.render.stroke_width=0.07）。
MANGA_STROKE_RATIO = 0.07


@dataclass(frozen=True)
class MangaTextStyle:
    text_color: tuple[int, int, int]
    stroke_color: tuple[int, int, int] | None
    stroke_width: int
    font_size: int
    bold: bool
    confidence: float
    ink_mask: Image.Image


def _srgb_channel_to_linear(value: float) -> float:
    channel = value / 255.0
    return ((channel + 0.055) / 1.055) ** 2.4 if channel > 0.04045 else channel / 12.92


def _rgb_to_lab(color: tuple[int, int, int]) -> tuple[float, float, float]:
    """sRGB → CIELAB（D65），纯 Python 实现，避免引入 OpenCV 依赖。"""
    r = _srgb_channel_to_linear(color[0])
    g = _srgb_channel_to_linear(color[1])
    b = _srgb_channel_to_linear(color[2])
    x = (r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047
    y = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
    z = (r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883

    def _f(t: float) -> float:
        return t ** (1.0 / 3.0) if t > 0.008856 else (903.3 * t + 16.0) / 116.0

    fx, fy, fz = _f(x), _f(y), _f(z)
    return (116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))


def _color_difference(color1: tuple[int, int, int], color2: tuple[int, int, int]) -> float:
    """CIE76 色差。等价于参考实现在 OpenCV 8 位 LAB 上 ×0.392 的结果（×0.392 仅用于抵消 8 位 L 通道缩放）。"""
    lab1 = _rgb_to_lab(color1)
    lab2 = _rgb_to_lab(color2)
    return ((lab1[0] - lab2[0]) ** 2 + (lab1[1] - lab2[1]) ** 2 + (lab1[2] - lab2[2]) ** 2) ** 0.5


def _fg_bg_compare(
    fg: tuple[int, int, int], bg: tuple[int, int, int]
) -> tuple[tuple[int, int, int], tuple[int, int, int]]:
    """复刻 manga-image-translator 的 fg_bg_compare：
    当描边色偏灰或与文字色差不足时，按文字明度强制描边为纯黑/纯白，保证清晰的漫画描边。"""
    fg_avg = sum(fg) / 3.0
    bg_is_gray = (max(bg) - min(bg)) < 10
    if bg_is_gray or _color_difference(fg, bg) < 30:
        bg = (255, 255, 255) if fg_avg <= 127 else (0, 0, 0)
    return fg, bg


def _resolve_stroke_color(
    text_color: tuple[int, int, int], fill_color: tuple[int, int, int]
) -> tuple[int, int, int]:
    """以区域背景（气泡填充）作为描边基色，再经 fg_bg_compare 修正对比度。"""
    _, stroke = _fg_bg_compare(text_color, fill_color)
    return stroke


def _median_rgb(pixels: list[tuple[int, int, int]]) -> tuple[int, int, int]:
    if not pixels:
        return (24, 24, 24)
    midpoint = len(pixels) // 2
    channels = [sorted(int(pixel[index]) for pixel in pixels) for index in range(3)]
    return tuple(channel[midpoint] for channel in channels)


def _active_mask_run_size(mask: Image.Image, *, horizontal: bool) -> int:
    width, height = mask.size
    pixels = mask.load()
    run_lengths: list[int] = []
    current_run = 0
    primary_size = height if horizontal else width
    secondary_size = width if horizontal else height
    minimum_ink = max(1, int(round(secondary_size * 0.012)))
    for primary in range(primary_size):
        ink_count = sum(
            1
            for secondary in range(secondary_size)
            if (pixels[secondary, primary] if horizontal else pixels[primary, secondary]) > 0
        )
        if ink_count >= minimum_ink:
            current_run += 1
        elif current_run:
            run_lengths.append(current_run)
            current_run = 0
    if current_run:
        run_lengths.append(current_run)
    return max(run_lengths, default=max(1, height if horizontal else width))


def _estimate_manga_text_style_python(
    image: Image.Image,
    text_bbox: tuple[int, int, int, int],
    fill_color: tuple[int, int, int],
    *,
    preferred_color: Any = None,
    direction: str = "horizontal",
) -> MangaTextStyle:
    clipped_bbox = _normalize_region_bbox(text_bbox, image.size) or (0, 0, 1, 1)
    crop = image.crop(clipped_bbox).convert("RGB")
    width, height = crop.size
    parsed_preferred = _parse_hex_color(preferred_color)
    candidate_pixels: list[tuple[int, int, int]] = []
    for pixel in _image_pixels(crop):
        color = tuple(int(channel) for channel in pixel)
        background_difference = _color_difference(color, fill_color)
        if background_difference < 24:
            continue
        if parsed_preferred is not None and _color_difference(color, parsed_preferred) > 56:
            continue
        candidate_pixels.append(color)

    if candidate_pixels:
        buckets: dict[tuple[int, int, int], list[tuple[int, int, int]]] = {}
        for color in candidate_pixels:
            bucket = tuple(int(channel) // 24 for channel in color)
            buckets.setdefault(bucket, []).append(color)
        dominant_pixels = max(
            buckets.values(),
            key=lambda values: (
                len(values),
                sum(_color_difference(value, fill_color) for value in values) / max(1, len(values)),
            ),
        )
        detected_color = _median_rgb(dominant_pixels)
    else:
        detected_color = _resolve_text_color(fill_color, preferred_color)

    if parsed_preferred is not None and _color_difference(detected_color, parsed_preferred) <= 38:
        detected_color = parsed_preferred

    mask = Image.new("L", (max(1, width), max(1, height)), 0)
    mask_pixels = mask.load()
    crop_pixels = crop.load()
    for current_y in range(height):
        for current_x in range(width):
            color = tuple(int(channel) for channel in crop_pixels[current_x, current_y])
            color_distance = _color_difference(color, detected_color)
            background_difference = _color_difference(color, fill_color)
            color_threshold = 52 if parsed_preferred is not None else 76
            if background_difference >= 20 and color_distance <= color_threshold:
                mask_pixels[current_x, current_y] = 255

    if mask.getbbox() is None:
        fallback_threshold = 34
        for current_y in range(height):
            for current_x in range(width):
                color = tuple(int(channel) for channel in crop_pixels[current_x, current_y])
                if _color_difference(color, fill_color) >= fallback_threshold:
                    mask_pixels[current_x, current_y] = 255

    if mask.getbbox() is not None:
        proximity_mask = mask.filter(ImageFilter.MaxFilter(5))
        proximity_pixels = proximity_mask.load()
        for current_y in range(height):
            for current_x in range(width):
                if proximity_pixels[current_x, current_y] <= 0:
                    continue
                color = tuple(int(channel) for channel in crop_pixels[current_x, current_y])
                if _color_difference(color, fill_color) >= 18:
                    mask_pixels[current_x, current_y] = 255

    ink_bbox = mask.getbbox() or (0, 0, max(1, width), max(1, height))
    ink_width = max(1, ink_bbox[2] - ink_bbox[0])
    ink_height = max(1, ink_bbox[3] - ink_bbox[1])
    is_vertical = direction == "vertical"
    glyph_span = _active_mask_run_size(mask, horizontal=not is_vertical)
    font_size = int(round(glyph_span * 1.30))
    font_size = max(10, min(180, font_size, max(ink_width, ink_height) * 2))
    ink_pixels = sum(1 for value in _image_pixels(mask) if value > 0)
    coverage = ink_pixels / max(1, ink_width * ink_height)
    bold = coverage >= 0.23

    expanded_mask = mask.filter(ImageFilter.MaxFilter(5))
    ring_mask = ImageChops.subtract(expanded_mask, mask.filter(ImageFilter.MaxFilter(3)))
    stroke_pixels: list[tuple[int, int, int]] = []
    ring_values = ring_mask.load()
    for current_y in range(height):
        for current_x in range(width):
            if ring_values[current_x, current_y] <= 0:
                continue
            color = tuple(int(channel) for channel in crop_pixels[current_x, current_y])
            if _color_difference(color, fill_color) >= 36 and _color_difference(color, detected_color) >= 42:
                stroke_pixels.append(color)
    minimum_stroke_pixels = max(10, int(round(ink_pixels * 0.08)))
    stroke_color = _median_rgb(stroke_pixels) if len(stroke_pixels) >= minimum_stroke_pixels else None
    if stroke_color is not None:
        _, stroke_color = _fg_bg_compare(detected_color, stroke_color)
    stroke_width = max(1, round(font_size * MANGA_STROKE_RATIO)) if stroke_color is not None else 0
    confidence = min(1.0, ink_pixels / max(12.0, width * height * 0.08))
    return MangaTextStyle(
        text_color=detected_color,
        stroke_color=stroke_color,
        stroke_width=stroke_width,
        font_size=font_size,
        bold=bold,
        confidence=confidence,
        ink_mask=mask,
    )


def _lab_color_array(color: tuple[int, int, int]) -> Any:
    color_array = np.asarray([[color]], dtype=np.float32) / 255.0
    return cv2.cvtColor(color_array, cv2.COLOR_RGB2LAB)[0, 0]


def _upper_median_rgb(pixels: Any) -> tuple[int, int, int]:
    if pixels.size == 0:
        return (24, 24, 24)
    midpoint = len(pixels) // 2
    partitioned = np.partition(pixels, midpoint, axis=0)
    return tuple(int(value) for value in partitioned[midpoint])


def _longest_active_mask_run(mask: Any, *, horizontal: bool) -> int:
    secondary_size = mask.shape[1] if horizontal else mask.shape[0]
    minimum_ink = max(1, int(round(secondary_size * 0.012)))
    ink_counts = np.count_nonzero(mask, axis=1 if horizontal else 0)
    active = ink_counts >= minimum_ink
    if not np.any(active):
        return max(1, mask.shape[0] if horizontal else mask.shape[1])
    padded = np.pad(active.astype(np.int8), (1, 1))
    transitions = np.flatnonzero(np.diff(padded))
    return int(np.max(transitions[1::2] - transitions[::2]))


def _estimate_manga_text_style_vectorized(
    image: Image.Image,
    text_bbox: tuple[int, int, int, int],
    fill_color: tuple[int, int, int],
    *,
    preferred_color: Any = None,
    direction: str = "horizontal",
) -> MangaTextStyle:
    clipped_bbox = _normalize_region_bbox(text_bbox, image.size) or (0, 0, 1, 1)
    crop = image.crop(clipped_bbox).convert("RGB")
    rgb = np.asarray(crop, dtype=np.uint8)
    height, width = rgb.shape[:2]
    lab = cv2.cvtColor(rgb.astype(np.float32) / 255.0, cv2.COLOR_RGB2LAB)
    fill_lab = _lab_color_array(fill_color)
    background_difference = np.linalg.norm(lab - fill_lab, axis=2)
    parsed_preferred = _parse_hex_color(preferred_color)

    candidate_mask = background_difference >= 24
    if parsed_preferred is not None:
        preferred_lab = _lab_color_array(parsed_preferred)
        candidate_mask &= np.linalg.norm(lab - preferred_lab, axis=2) <= 56
    candidate_pixels = rgb[candidate_mask]
    if candidate_pixels.size:
        buckets = candidate_pixels.astype(np.int16) // 24
        bucket_codes = buckets[:, 0] * 121 + buckets[:, 1] * 11 + buckets[:, 2]
        counts = np.bincount(bucket_codes, minlength=1331)
        maximum_count = int(counts.max())
        candidate_codes = np.flatnonzero(counts == maximum_count)
        if len(candidate_codes) > 1:
            distance_sums = np.bincount(
                bucket_codes,
                weights=background_difference[candidate_mask],
                minlength=1331,
            )
            averages = distance_sums[candidate_codes] / np.maximum(1, counts[candidate_codes])
            dominant_code = int(candidate_codes[int(np.argmax(averages))])
        else:
            dominant_code = int(candidate_codes[0])
        detected_color = _upper_median_rgb(candidate_pixels[bucket_codes == dominant_code])
    else:
        detected_color = _resolve_text_color(fill_color, preferred_color)

    if parsed_preferred is not None and _color_difference(detected_color, parsed_preferred) <= 38:
        detected_color = parsed_preferred
    detected_lab = _lab_color_array(detected_color)
    color_difference = np.linalg.norm(lab - detected_lab, axis=2)
    color_threshold = 52 if parsed_preferred is not None else 76
    mask_array = (background_difference >= 20) & (color_difference <= color_threshold)
    if not np.any(mask_array):
        mask_array = background_difference >= 34
    if np.any(mask_array):
        proximity = cv2.dilate(mask_array.astype(np.uint8), np.ones((5, 5), dtype=np.uint8)) > 0
        mask_array |= proximity & (background_difference >= 18)

    mask_bytes = np.where(mask_array, 255, 0).astype(np.uint8)
    mask = Image.fromarray(mask_bytes, mode="L")
    ink_bbox = mask.getbbox() or (0, 0, max(1, width), max(1, height))
    ink_width = max(1, ink_bbox[2] - ink_bbox[0])
    ink_height = max(1, ink_bbox[3] - ink_bbox[1])
    is_vertical = direction == "vertical"
    glyph_span = _longest_active_mask_run(mask_array, horizontal=not is_vertical)
    font_size = int(round(glyph_span * 1.30))
    font_size = max(10, min(180, font_size, max(ink_width, ink_height) * 2))
    ink_pixels = int(np.count_nonzero(mask_array))
    coverage = ink_pixels / max(1, ink_width * ink_height)
    bold = coverage >= 0.23

    expanded = cv2.dilate(mask_bytes, np.ones((5, 5), dtype=np.uint8))
    inner = cv2.dilate(mask_bytes, np.ones((3, 3), dtype=np.uint8))
    ring_mask = (expanded > inner) & (background_difference >= 36) & (color_difference >= 42)
    stroke_pixels = rgb[ring_mask]
    minimum_stroke_pixels = max(10, int(round(ink_pixels * 0.08)))
    stroke_color = _upper_median_rgb(stroke_pixels) if len(stroke_pixels) >= minimum_stroke_pixels else None
    if stroke_color is not None:
        _, stroke_color = _fg_bg_compare(detected_color, stroke_color)
    stroke_width = max(1, round(font_size * MANGA_STROKE_RATIO)) if stroke_color is not None else 0
    confidence = min(1.0, ink_pixels / max(12.0, width * height * 0.08))
    return MangaTextStyle(
        text_color=detected_color,
        stroke_color=stroke_color,
        stroke_width=stroke_width,
        font_size=font_size,
        bold=bold,
        confidence=confidence,
        ink_mask=mask,
    )


def _estimate_manga_text_style(
    image: Image.Image,
    text_bbox: tuple[int, int, int, int],
    fill_color: tuple[int, int, int],
    *,
    preferred_color: Any = None,
    direction: str = "horizontal",
) -> MangaTextStyle:
    if cv2 is None or np is None:
        return _estimate_manga_text_style_python(
            image,
            text_bbox,
            fill_color,
            preferred_color=preferred_color,
            direction=direction,
        )
    return _estimate_manga_text_style_vectorized(
        image,
        text_bbox,
        fill_color,
        preferred_color=preferred_color,
        direction=direction,
    )


def _inpaint_manga_text_region(crop: Image.Image, removal_mask: Image.Image) -> Image.Image:
    source = crop.convert("RGBA")
    width, height = source.size
    mask = removal_mask.convert("L")
    mask_pixels = mask.load()
    repaired = source.copy()
    repaired_pixels = repaired.load()
    visited = [[False for _ in range(width)] for _ in range(height)]
    queue: deque[tuple[int, int]] = deque()
    neighbor_offsets = (
        (-1, -1),
        (0, -1),
        (1, -1),
        (-1, 0),
        (1, 0),
        (-1, 1),
        (0, 1),
        (1, 1),
    )

    for current_y in range(height):
        for current_x in range(width):
            if mask_pixels[current_x, current_y] > 0:
                continue
            if any(
                0 <= current_x + offset_x < width
                and 0 <= current_y + offset_y < height
                and mask_pixels[current_x + offset_x, current_y + offset_y] > 0
                for offset_x, offset_y in neighbor_offsets
            ):
                visited[current_y][current_x] = True
                queue.append((current_x, current_y))

    while queue:
        source_x, source_y = queue.popleft()
        source_color = repaired_pixels[source_x, source_y]
        for offset_x, offset_y in neighbor_offsets:
            target_x = source_x + offset_x
            target_y = source_y + offset_y
            if not (0 <= target_x < width and 0 <= target_y < height):
                continue
            if visited[target_y][target_x] or mask_pixels[target_x, target_y] <= 0:
                continue
            visited[target_y][target_x] = True
            repaired_pixels[target_x, target_y] = source_color
            queue.append((target_x, target_y))

    return repaired


def _erase_manga_source_text(
    canvas: Image.Image,
    text_bbox: tuple[int, int, int, int],
    style: MangaTextStyle,
    fill_color: tuple[int, int, int],
    *,
    limit_bbox: tuple[int, int, int, int] | None = None,
    limit_mask: Image.Image | None = None,
) -> tuple[int, str]:
    clipped_bbox = _normalize_region_bbox(text_bbox, canvas.size)
    if clipped_bbox is None or style.ink_mask.getbbox() is None:
        return 0, "none"
    crop = canvas.crop(clipped_bbox).convert("RGBA")
    mask = style.ink_mask
    if mask.size != crop.size:
        mask = mask.resize(crop.size, Image.Resampling.NEAREST)
    dilation_radius = max(1, min(5, int(round(style.font_size * 0.08))))
    kernel_size = dilation_radius * 2 + 1
    removal_mask = mask.filter(ImageFilter.MaxFilter(kernel_size))
    if limit_bbox is not None and limit_mask is not None:
        normalized_limit = _normalize_region_bbox(limit_bbox, canvas.size)
        intersection = _intersect_region_bboxes(clipped_bbox, normalized_limit)
        if normalized_limit is None or intersection is None:
            return 0, "none"
        normalized_mask = limit_mask.convert("L")
        expected_size = (
            normalized_limit[2] - normalized_limit[0],
            normalized_limit[3] - normalized_limit[1],
        )
        if normalized_mask.size != expected_size:
            normalized_mask = normalized_mask.resize(expected_size, Image.Resampling.NEAREST)
        permitted_mask = Image.new("L", crop.size, 0)
        permitted_crop = normalized_mask.crop(
            (
                intersection[0] - normalized_limit[0],
                intersection[1] - normalized_limit[1],
                intersection[2] - normalized_limit[0],
                intersection[3] - normalized_limit[1],
            )
        )
        permitted_mask.paste(
            permitted_crop,
            (
                intersection[0] - clipped_bbox[0],
                intersection[1] - clipped_bbox[1],
            ),
        )
        removal_mask = ImageChops.multiply(removal_mask, permitted_mask)
    erased_pixels = sum(1 for value in _image_pixels(removal_mask) if value > 0)
    if erased_pixels <= 0:
        return 0, "none"

    rgb_crop = crop.convert("RGB")
    unmasked_pixels = [
        tuple(int(channel) for channel in pixel)
        for pixel, mask_value in zip(_image_pixels(rgb_crop), _image_pixels(removal_mask), strict=True)
        if mask_value == 0
    ]
    average_background_delta = (
        sum(_color_difference(pixel, fill_color) for pixel in unmasked_pixels) / len(unmasked_pixels)
        if unmasked_pixels
        else 0.0
    )
    background_luminances = sorted(_color_luminance(pixel) for pixel in unmasked_pixels)
    if background_luminances:
        low_index = min(len(background_luminances) - 1, int(len(background_luminances) * 0.05))
        high_index = min(len(background_luminances) - 1, int(len(background_luminances) * 0.95))
        background_spread = background_luminances[high_index] - background_luminances[low_index]
    else:
        background_spread = 0.0
    if average_background_delta <= 22 and background_spread <= 18:
        replacement = Image.new("RGBA", crop.size, fill_color + (255,))
        method = "solid"
    else:
        replacement = _inpaint_manga_text_region(crop, removal_mask)
        method = "inpaint"
    crop.paste(replacement, (0, 0), removal_mask)
    canvas.paste(crop, (clipped_bbox[0], clipped_bbox[1]))
    return erased_pixels, method


def _local_render_font_paths(*, bold: bool = False) -> list[Path]:
    windows_fonts_dir = Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts"
    regular_paths = [
        windows_fonts_dir / "msyh.ttc",
        windows_fonts_dir / "simsun.ttc",
        windows_fonts_dir / "NotoSansCJK-Regular.ttc",
        windows_fonts_dir / "arial.ttf",
        Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"),
        Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"),
        Path("/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf"),
        Path("/System/Library/Fonts/PingFang.ttc"),
        Path("/System/Library/Fonts/Supplemental/Arial.ttf"),
    ]
    bold_paths = [
        windows_fonts_dir / "msyhbd.ttc",
        windows_fonts_dir / "simhei.ttf",
        windows_fonts_dir / "arialbd.ttf",
        Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"),
        Path("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"),
        Path("/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf"),
        Path("/System/Library/Fonts/PingFang.ttc"),
        Path("/System/Library/Fonts/Supplemental/Arial Bold.ttf"),
    ]
    return bold_paths + regular_paths if bold else regular_paths + bold_paths


def _load_local_render_font(font_size: int, *, bold: bool = False) -> ImageFont.ImageFont:
    safe_size = max(10, int(font_size))
    for font_path in _local_render_font_paths(bold=bold):
        if not font_path.exists():
            continue
        try:
            return ImageFont.truetype(str(font_path), safe_size, encoding="utf-8")
        except Exception:
            continue
    # Pillow 在部分 Linux 发行版中可以通过 Fontconfig 按文件名解析
    # DejaVu Sans；这能覆盖字体安装位置不同于上述常见目录的环境。
    fallback_names = (
        ("DejaVuSans-Bold.ttf", "DejaVuSans.ttf") if bold else ("DejaVuSans.ttf", "DejaVuSans-Bold.ttf")
    )
    for font_name in fallback_names:
        try:
            return ImageFont.truetype(font_name, safe_size, encoding="utf-8")
        except Exception:
            continue
    # Pillow 12 自带可缩放的默认字体。即使系统没有安装任何字体，仍必须
    # 保留调用方请求的字号，否则样式估算和 OCR 图像证据都会退化到约 10px。
    return ImageFont.load_default(size=safe_size)


VERTICAL_PUNCTUATION_MAP: dict[str, str] = {
    ",": "︐",
    "，": "︐",
    "、": "︑",
    ".": "︒",
    "。": "︒",
    ":": "︓",
    "：": "︓",
    ";": "︔",
    "；": "︔",
    "!": "︕",
    "！": "︕",
    "?": "︖",
    "？": "︖",
    "(": "︵",
    "（": "︵",
    ")": "︶",
    "）": "︶",
    "[": "﹇",
    "【": "︻",
    "]": "﹈",
    "】": "︼",
    "{": "︷",
    "}": "︸",
    "<": "︿",
    "《": "︽",
    ">": "﹀",
    "》": "︾",
    "「": "﹁",
    "」": "﹂",
    "『": "﹃",
    "』": "﹄",
    "“": "﹁",
    "”": "﹂",
    "‘": "﹃",
    "’": "﹄",
    "—": "︱",
    "－": "︱",
    "-": "︱",
    "_": "︳",
    "…": "︙",
}

VERTICAL_PUNCTUATION_OFFSET_RATIOS: dict[str, tuple[float, float]] = {
    "︐": (0.0, -0.10),
    "︑": (0.0, -0.10),
    "︒": (0.0, -0.14),
    "︓": (0.0, -0.08),
    "︔": (0.0, -0.08),
    "︕": (0.0, -0.06),
    "︖": (0.0, -0.06),
    "︙": (0.0, -0.05),
    "︱": (0.0, -0.02),
    "︳": (0.0, -0.02),
}


def _split_text_paragraphs(text: str) -> list[str]:
    content = str(text or "").replace("\r", "").strip()
    if not content:
        return []
    return [item.strip() for item in content.split("\n") if item.strip()]


def _normalize_vertical_text(text: str) -> str:
    content = str(text or "")
    if not content:
        return ""
    content = re.sub(r"(?:\.|．|。){3,}", "︙", content)
    content = content.replace("……", "︙")
    content = content.replace("...", "︙")
    normalized_chars: list[str] = []
    for raw_char in content:
        if raw_char == "\n":
            normalized_chars.append(raw_char)
            continue
        if raw_char.isspace():
            normalized_chars.append("　")
            continue
        normalized_chars.append(VERTICAL_PUNCTUATION_MAP.get(raw_char, raw_char))
    return "".join(normalized_chars)


LAYOUT_NO_LINE_START = set("，。、！？；：)]）】》」』〉”’%,.!?;:")
LAYOUT_NO_LINE_END = set("([（【《「『〈“‘$￥")


def _is_ascii_word_character(char: str) -> bool:
    return char.isascii() and (char.isalnum() or char in {"'", "-", "_", "/", ".", "+", "%", "&"})


def _text_supports_vertical_layout(text: str) -> bool:
    content = re.sub(r"\s+", "", str(text or ""))
    if not content:
        return False
    if re.search(r"[A-Za-z]{3,}", content):
        return False
    if re.search(r"\d{3,}", content):
        return False
    if re.search(r"[A-Za-z0-9][./:+-][A-Za-z0-9]", content):
        return False
    ascii_dense = len(re.findall(r"[A-Za-z0-9]", content))
    return ascii_dense <= max(3, len(content) // 5)


def _tokenize_layout_text(text: str) -> list[str]:
    content = str(text or "")
    if not content:
        return []

    tokens: list[str] = []
    buffer: list[str] = []

    def flush_buffer() -> None:
        if buffer:
            tokens.append("".join(buffer))
            buffer.clear()

    for raw_char in content:
        if raw_char.isspace():
            flush_buffer()
            if tokens and tokens[-1] != " ":
                tokens.append(" ")
            continue
        if _is_ascii_word_character(raw_char):
            buffer.append(raw_char)
            continue
        flush_buffer()
        tokens.append(raw_char)
    flush_buffer()
    return tokens


def _join_layout_tokens(tokens: list[str]) -> str:
    return "".join(tokens).strip()


def _measure_text_width(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont) -> int:
    value = str(text or "").strip()
    if not value:
        return 0
    bbox = draw.textbbox((0, 0), value, font=font)
    return max(0, bbox[2] - bbox[0])


def _line_break_penalty(
    left_text: str,
    right_text: str,
    *,
    line_width: int,
    max_width: int,
) -> float:
    penalty = abs(max_width - line_width) / max(12, max_width)
    if left_text and left_text[-1] in LAYOUT_NO_LINE_END:
        penalty += 6.0
    if right_text and right_text[0] in LAYOUT_NO_LINE_START:
        penalty += 6.0
    if len(left_text) <= 1:
        penalty += 1.5
    return penalty


def _select_wrap_break_index(
    draw: ImageDraw.ImageDraw,
    tokens: list[str],
    font: ImageFont.ImageFont,
    max_width: int,
) -> int:
    if len(tokens) <= 1:
        return 1

    candidates: list[tuple[float, float, int, int]] = []
    for index in range(1, len(tokens)):
        left_text = _join_layout_tokens(tokens[:index]).rstrip()
        right_text = _join_layout_tokens(tokens[index:]).lstrip()
        if not left_text:
            continue
        line_width = _measure_text_width(draw, left_text, font)
        penalty = _line_break_penalty(
            left_text,
            right_text,
            line_width=line_width,
            max_width=max_width,
        )
        if line_width > max_width * 1.08:
            penalty += 4.0
        if tokens[index - 1] == " " or tokens[index] == " ":
            penalty -= 0.35
        candidates.append((penalty, abs(max_width - line_width), -len(left_text), index))

    if candidates:
        return min(candidates)[-1]
    return max(1, len(tokens) - 1)


def _horizontal_layout_penalty(
    draw: ImageDraw.ImageDraw,
    lines: list[str],
    font: ImageFont.ImageFont,
    max_width: int,
) -> float:
    if not lines:
        return 8.0
    line_widths = [_measure_text_width(draw, line, font) for line in lines if line.strip()]
    if not line_widths:
        return 8.0
    widest = max(line_widths)
    narrowest = min(line_widths)
    penalty = ((widest - narrowest) / max(12, max_width)) * 1.4
    if len(line_widths) > 1 and line_widths[-1] < widest * 0.42:
        penalty += 1.8
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped[0] in LAYOUT_NO_LINE_START:
            penalty += 2.5
        if stripped[-1] in LAYOUT_NO_LINE_END:
            penalty += 2.5
    return penalty


def _measure_text_token(
    draw: ImageDraw.ImageDraw,
    token: str,
    font: ImageFont.ImageFont,
) -> dict[str, Any]:
    bbox = draw.textbbox((0, 0), token, font=font)
    return {
        "text": token,
        "bbox": bbox,
        "width": max(1, bbox[2] - bbox[0]),
        "height": max(1, bbox[3] - bbox[1]),
        "offset_ratio": VERTICAL_PUNCTUATION_OFFSET_RATIOS.get(token, (0.0, 0.0)),
    }


def _finalize_vertical_column(
    chars: list[dict[str, Any]],
    char_gap: int,
) -> dict[str, Any]:
    column_width = max((int(item.get("width") or 0) for item in chars), default=0)
    column_height = 0
    for index, item in enumerate(chars):
        if index:
            column_height += char_gap
        column_height += int(item.get("height") or 0)
    return {
        "chars": chars,
        "width": column_width,
        "height": column_height,
    }


def _balance_vertical_characters(
    chars: list[dict[str, Any]],
    char_gap: int,
    column_count: int,
) -> list[dict[str, Any]]:
    if not chars:
        return []
    if column_count <= 1:
        return [_finalize_vertical_column(chars, char_gap)]

    total_height = 0
    for index, item in enumerate(chars):
        if index:
            total_height += char_gap
        total_height += int(item.get("height") or 0)
    target_height = total_height / max(column_count, 1)

    columns: list[dict[str, Any]] = []
    start = 0
    total_chars = len(chars)
    while start < total_chars:
        remaining_columns = column_count - len(columns)
        remaining_chars = total_chars - start
        if remaining_columns <= 1:
            end = total_chars
        else:
            max_take = remaining_chars - (remaining_columns - 1)
            current_height = 0
            end = start
            while end < start + max_take:
                char_height = int(chars[end].get("height") or 0)
                candidate_height = current_height + (char_gap if end > start else 0) + char_height
                remaining_after = total_chars - (end + 1)
                if (
                    end > start
                    and candidate_height > target_height
                    and remaining_after >= remaining_columns - 1
                ):
                    break
                current_height = candidate_height
                end += 1
                if current_height >= target_height and remaining_after >= remaining_columns - 1:
                    break
            if end <= start:
                end = start + 1
        columns.append(_finalize_vertical_column(chars[start:end], char_gap))
        start = end
    return columns


def _wrap_text_for_box(
    draw: ImageDraw.ImageDraw, text: str, font: ImageFont.ImageFont, max_width: int
) -> list[str]:
    paragraphs = _split_text_paragraphs(text)
    if not paragraphs:
        return []

    lines: list[str] = []
    for paragraph in paragraphs:
        remaining_tokens = _tokenize_layout_text(paragraph)
        current_tokens: list[str] = []
        while remaining_tokens:
            token = remaining_tokens.pop(0)
            if not current_tokens and token == " ":
                continue
            candidate_tokens = current_tokens + [token]
            candidate_text = _join_layout_tokens(candidate_tokens)
            candidate_width = _measure_text_width(draw, candidate_text, font)
            if current_tokens and candidate_width > max_width:
                break_index = _select_wrap_break_index(draw, candidate_tokens, font, max_width)
                line_text = _join_layout_tokens(candidate_tokens[:break_index]).strip()
                if line_text:
                    lines.append(line_text)
                remainder_tokens = candidate_tokens[break_index:]
                while remainder_tokens and remainder_tokens[0] == " ":
                    remainder_tokens.pop(0)
                remaining_tokens = remainder_tokens + remaining_tokens
                current_tokens = []
                continue
            current_tokens = candidate_tokens
        final_line = _join_layout_tokens(current_tokens).strip()
        if final_line:
            lines.append(final_line)
    return lines or [str(text or "").strip()]


def _normalize_layout_direction(
    preferred_direction: Any,
    box_size: tuple[int, int],
    text: str,
) -> str:
    normalized = str(preferred_direction or "").strip().lower()
    alias_map = {
        "v": "vertical",
        "vert": "vertical",
        "vertical": "vertical",
        "竖排": "vertical",
        "h": "horizontal",
        "hor": "horizontal",
        "horizontal": "horizontal",
        "横排": "horizontal",
    }
    resolved = alias_map.get(normalized)
    if resolved:
        return resolved

    box_width, box_height = box_size
    aspect_ratio = box_height / max(box_width, 1)
    dense_length = len(re.sub(r"\s+", "", str(text or "")))
    if aspect_ratio >= 2.2 and _text_supports_vertical_layout(text):
        return "vertical"
    if aspect_ratio >= 1.55 and dense_length <= 20 and _text_supports_vertical_layout(text):
        return "vertical"
    return "horizontal"


def _build_horizontal_layout_candidate(
    draw: ImageDraw.ImageDraw,
    text: str,
    box_size: tuple[int, int],
    font_size: int,
    *,
    bold: bool = False,
) -> dict[str, Any]:
    max_width, max_height = box_size
    font = _load_local_render_font(font_size, bold=bold)
    lines = _wrap_text_for_box(draw, text, font, max(8, max_width))
    rendered_text = "\n".join(lines)
    spacing = max(1, min(10, font_size // 6 + (1 if len(lines) <= 2 else 0)))
    bbox = draw.multiline_textbbox((0, 0), rendered_text, font=font, spacing=spacing, align="center")
    content_width = max(0, bbox[2] - bbox[0])
    content_height = max(0, bbox[3] - bbox[1])
    safe_width = max_width * 0.90
    safe_height = max_height * 0.88
    overflow = max(0.0, content_width - safe_width) + max(0.0, content_height - safe_height)
    return {
        "direction": "horizontal",
        "font": font,
        "font_size": font_size,
        "lines": lines,
        "spacing": spacing,
        "content_width": content_width,
        "content_height": content_height,
        "fits": content_width <= safe_width and content_height <= safe_height,
        "overflow": overflow,
        "layout_penalty": _horizontal_layout_penalty(draw, lines, font, max_width),
    }


def _build_vertical_columns(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.ImageFont,
    max_height: int,
    char_gap: int,
) -> list[dict[str, Any]]:
    paragraphs = _split_text_paragraphs(_normalize_vertical_text(text))
    if not paragraphs:
        return []

    columns: list[dict[str, Any]] = []
    for paragraph in paragraphs:
        paragraph_chars = [_measure_text_token(draw, raw_char, font) for raw_char in paragraph if raw_char]
        if not paragraph_chars:
            continue

        column_count = 1
        balanced_columns = [_finalize_vertical_column(paragraph_chars, char_gap)]
        while column_count < len(paragraph_chars):
            balanced_columns = _balance_vertical_characters(paragraph_chars, char_gap, column_count)
            if (
                balanced_columns
                and max(int(column.get("height") or 0) for column in balanced_columns) <= max_height
            ):
                break
            column_count += 1
        else:
            balanced_columns = _balance_vertical_characters(paragraph_chars, char_gap, len(paragraph_chars))
        columns.extend(balanced_columns)
    return columns


def _build_vertical_layout_candidate(
    draw: ImageDraw.ImageDraw,
    text: str,
    box_size: tuple[int, int],
    font_size: int,
    *,
    bold: bool = False,
) -> dict[str, Any]:
    max_width, max_height = box_size
    font = _load_local_render_font(font_size, bold=bold)
    char_gap = max(1, min(5, font_size // 10 + 1))
    column_gap = max(2, min(10, font_size // 5))
    columns = _build_vertical_columns(draw, text, font, max(8, max_height), char_gap)
    content_width = sum(int(column.get("width") or 0) for column in columns)
    if len(columns) > 1:
        content_width += column_gap * (len(columns) - 1)
    content_height = max((int(column.get("height") or 0) for column in columns), default=0)
    safe_width = max_width * 0.90
    safe_height = max_height * 0.88
    overflow = max(0.0, content_width - safe_width) + max(0.0, content_height - safe_height)
    column_heights = [int(column.get("height") or 0) for column in columns]
    tallest = max(column_heights, default=0)
    shortest = min(column_heights, default=0)
    vertical_penalty = 0.0
    if tallest > 0:
        vertical_penalty += ((tallest - shortest) / tallest) * 2.2
    vertical_penalty += max(0, len(columns) - 2) * 0.9
    if not _text_supports_vertical_layout(text):
        vertical_penalty += 3.5
    return {
        "direction": "vertical",
        "font": font,
        "font_size": font_size,
        "columns": columns,
        "char_gap": char_gap,
        "column_gap": column_gap,
        "content_width": content_width,
        "content_height": content_height,
        "fits": bool(columns) and content_width <= safe_width and content_height <= safe_height,
        "overflow": overflow,
        "layout_penalty": vertical_penalty,
    }


def _layout_score_tuple(layout: dict[str, Any], box_size: tuple[int, int]) -> tuple[int, float, float, int]:
    box_width, box_height = box_size
    content_width = int(layout.get("content_width") or 0)
    content_height = int(layout.get("content_height") or 0)
    overflow = float(layout.get("overflow") or 0.0)
    fill_ratio = max(
        content_width / max(1, box_width),
        content_height / max(1, box_height),
    )
    edge_penalty = max(0.0, fill_ratio - 0.84) * 12.0
    underfill_penalty = max(0.0, 0.46 - fill_ratio) * 4.5
    if layout.get("direction") == "vertical":
        # A single thin column can be almost as tall as the bubble and therefore
        # look "full" according to the longest-axis ratio while wasting nearly
        # all horizontal space. Score the two-dimensional footprint as well so
        # longer translations split into readable right-to-left columns instead
        # of shrinking to a narrow strip.
        footprint_ratio = (content_width / max(1, box_width)) * (content_height / max(1, box_height))
        underfill_penalty += max(0.0, 0.16 - footprint_ratio) * 8.0
    layout_penalty = float(layout.get("layout_penalty") or 0.0)
    return (
        0 if bool(layout.get("fits")) else 1,
        round(overflow + edge_penalty, 3),
        round(layout_penalty + underfill_penalty, 3),
        -int(layout.get("font_size") or 0),
    )


def _fit_text_layout_for_direction(
    text: str,
    box_size: tuple[int, int],
    direction: str,
    *,
    preferred_font_size: int | None = None,
    bold: bool = False,
) -> dict[str, Any]:
    max_width, max_height = box_size
    scratch_image = Image.new("RGB", (max(max_width, 8), max(max_height, 8)), (255, 255, 255))
    draw = ImageDraw.Draw(scratch_image)
    size_limit = max_width * (2 if direction == "vertical" else 1)
    box_limit = max(12, min(180, max_height, size_limit))
    initial_size = (
        max(10, min(box_limit, int(round(preferred_font_size * 1.12))))
        if preferred_font_size is not None
        else box_limit
    )

    best_layout: dict[str, Any] | None = None
    for font_size in range(initial_size, 9, -1):
        if direction == "vertical":
            candidate = _build_vertical_layout_candidate(draw, text, box_size, font_size, bold=bold)
        else:
            candidate = _build_horizontal_layout_candidate(draw, text, box_size, font_size, bold=bold)
        if best_layout is None or _layout_score_tuple(candidate, box_size) < _layout_score_tuple(
            best_layout, box_size
        ):
            best_layout = candidate

    if best_layout is not None:
        return best_layout
    return _build_horizontal_layout_candidate(draw, text, box_size, 10, bold=bold)


def _fit_text_layout_to_box(
    text: str,
    box_size: tuple[int, int],
    preferred_direction: Any = None,
    *,
    preferred_font_size: int | None = None,
    bold: bool = False,
) -> dict[str, Any]:
    explicit_direction = _normalize_manga_text_direction(preferred_direction)
    preferred = _normalize_layout_direction(preferred_direction, box_size, text)
    aspect_ratio = box_size[1] / max(box_size[0], 1)
    primary_layout = _fit_text_layout_for_direction(
        text,
        box_size,
        preferred,
        preferred_font_size=preferred_font_size,
        bold=bold,
    )
    alternate_direction = "horizontal" if preferred == "vertical" else "vertical"
    alternate_layout = _fit_text_layout_for_direction(
        text,
        box_size,
        alternate_direction,
        preferred_font_size=preferred_font_size,
        bold=bold,
    )
    if explicit_direction is not None and bool(primary_layout.get("fits")):
        return primary_layout
    bias = (
        0.55
        if preferred == "vertical" and aspect_ratio >= 1.55 and _text_supports_vertical_layout(text)
        else 0.25
    )
    return min(
        (primary_layout, alternate_layout),
        key=lambda item: (
            _layout_score_tuple(item, box_size)[0],
            _layout_score_tuple(item, box_size)[1],
            _layout_score_tuple(item, box_size)[2] + (0.0 if item["direction"] == preferred else bias),
            _layout_score_tuple(item, box_size)[3],
        ),
    )


def _layout_requires_extra_margin(layout: dict[str, Any], box_size: tuple[int, int]) -> bool:
    box_width, box_height = box_size
    content_width = int(layout.get("content_width") or 0)
    content_height = int(layout.get("content_height") or 0)
    if content_width > box_width * 0.88 or content_height > box_height * 0.88:
        return True
    lines = [str(item).strip() for item in layout.get("lines", []) if str(item).strip()]
    return bool(len(lines) > 1 and len(lines[-1]) <= 1)


def _fit_text_layout_for_render(
    text: str,
    box_size: tuple[int, int],
    preferred_direction: Any = None,
    *,
    preferred_font_size: int | None = None,
    bold: bool = False,
) -> dict[str, Any]:
    inset_x = 0
    inset_y = 0
    current_box = box_size
    layout = _fit_text_layout_to_box(
        text,
        current_box,
        preferred_direction,
        preferred_font_size=preferred_font_size,
        bold=bold,
    )
    for _ in range(3):
        if not _layout_requires_extra_margin(layout, current_box):
            break
        inset_x += 2 if box_size[0] >= 72 else 1
        inset_y += 2 if box_size[1] >= 72 else 1
        current_box = (
            max(8, box_size[0] - inset_x * 2),
            max(8, box_size[1] - inset_y * 2),
        )
        layout = _fit_text_layout_to_box(
            text,
            current_box,
            preferred_direction or layout.get("direction"),
            preferred_font_size=preferred_font_size,
            bold=bold,
        )
    if inset_x or inset_y:
        layout = dict(layout)
        layout["render_inset"] = (inset_x, inset_y)
    return layout


def _resolve_region_insets(
    region: dict[str, Any],
    bbox: tuple[int, int, int, int],
    direction: str,
) -> tuple[int, int]:
    x1, y1, x2, y2 = bbox
    width = max(1, x2 - x1)
    height = max(1, y2 - y1)
    aspect_ratio = height / max(width, 1)

    padding_ratio: float | None = None
    try:
        padding_ratio = float(region.get("padding_ratio"))
    except (TypeError, ValueError):
        padding_ratio = None
    if padding_ratio is not None:
        padding_ratio = max(0.55, min(0.92, padding_ratio))

    if direction == "vertical":
        inset_x_ratio = 0.20 if aspect_ratio >= 2.6 else 0.17 if aspect_ratio >= 1.8 else 0.14
        inset_y_ratio = 0.10 if aspect_ratio >= 2.2 else 0.12
    else:
        inset_x_ratio = 0.12 if width >= height else 0.14
        inset_y_ratio = 0.14 if width >= height else 0.12

    if padding_ratio is not None:
        requested_margin = max(0.04, min(0.22, (1.0 - padding_ratio) / 2))
        inset_x_ratio = max(inset_x_ratio, requested_margin)
        inset_y_ratio = max(inset_y_ratio, requested_margin * (0.85 if direction == "vertical" else 1.0))

    inset_x = max(3, min(width // 3, int(round(width * inset_x_ratio))))
    inset_y = max(3, min(height // 3, int(round(height * inset_y_ratio))))
    if width - inset_x * 2 < 16:
        inset_x = max(1, (width - 16) // 2)
    if height - inset_y * 2 < 16:
        inset_y = max(1, (height - 16) // 2)
    return inset_x, inset_y


def _resolve_region_fill_shape(
    region: dict[str, Any],
    bbox: tuple[int, int, int, int],
    direction: str,
) -> str:
    normalized = str(region.get("shape") or "").strip().lower()
    alias_map = {
        "oval": "ellipse",
        "ellipse": "ellipse",
        "circle": "ellipse",
        "round": "roundrect",
        "rounded": "roundrect",
        "roundrect": "roundrect",
        "rounded_rectangle": "roundrect",
        "box": "rect",
        "rect": "rect",
        "rectangle": "rect",
    }
    if normalized in alias_map:
        return alias_map[normalized]

    x1, y1, x2, y2 = bbox
    width = max(1, x2 - x1)
    height = max(1, y2 - y1)
    aspect_ratio = max(width, height) / max(1, min(width, height))
    # 竖排方向也根据宽高比推断形状，而非一律视为椭圆。
    # 宽高比接近 1 的区域更可能是圆形气泡，细长矩形则更可能是旁白框。
    if aspect_ratio <= 1.45:
        return "ellipse"
    if direction == "vertical" and aspect_ratio <= 2.0:
        return "ellipse"
    if aspect_ratio <= 2.8:
        return "roundrect"
    return "rect"


def _fill_region_background(
    draw: ImageDraw.ImageDraw,
    bbox: tuple[int, int, int, int],
    fill_color: tuple[int, int, int],
    fill_shape: str,
) -> None:
    x1, y1, x2, y2 = bbox
    if fill_shape == "ellipse":
        draw.ellipse((x1, y1, x2, y2), fill=fill_color)
        return
    if fill_shape == "roundrect":
        radius = max(6, min((x2 - x1) // 2, (y2 - y1) // 2, 24))
        try:
            draw.rounded_rectangle((x1, y1, x2, y2), radius=radius, fill=fill_color)
            return
        except AttributeError:
            pass
    draw.rectangle((x1, y1, x2, y2), fill=fill_color)


def _color_distance_manhattan(left: tuple[int, int, int], right: tuple[int, int, int]) -> int:
    return sum(abs(int(left[index]) - int(right[index])) for index in range(3))


def _color_luminance(color: tuple[int, int, int]) -> float:
    return 0.299 * color[0] + 0.587 * color[1] + 0.114 * color[2]


def _color_saturation(color: tuple[int, int, int]) -> int:
    return max(color) - min(color)


def _build_region_shape_mask(size: tuple[int, int], fill_shape: str) -> Image.Image:
    width, height = size
    mask = Image.new("L", (max(1, width), max(1, height)), 0)
    draw = ImageDraw.Draw(mask)
    left, top, right, bottom = 0, 0, max(0, width - 1), max(0, height - 1)
    if fill_shape == "ellipse":
        draw.ellipse((left, top, right, bottom), fill=255)
        return mask
    if fill_shape == "roundrect":
        radius = max(6, min((right - left) // 2, (bottom - top) // 2, 24))
        try:
            draw.rounded_rectangle((left, top, right, bottom), radius=radius, fill=255)
            return mask
        except AttributeError:
            pass
    draw.rectangle((left, top, right, bottom), fill=255)
    return mask


def _seed_positions_for_region(size: tuple[int, int]) -> list[tuple[int, int]]:
    width, height = size
    seed_offsets = (
        (0.50, 0.50),
        (0.50, 0.34),
        (0.50, 0.66),
        (0.34, 0.50),
        (0.66, 0.50),
        (0.38, 0.38),
        (0.62, 0.38),
        (0.38, 0.62),
        (0.62, 0.62),
        (0.50, 0.22),
        (0.50, 0.78),
    )
    points: list[tuple[int, int]] = []
    for ratio_x, ratio_y in seed_offsets:
        x = min(width - 1, max(0, int(round((width - 1) * ratio_x))))
        y = min(height - 1, max(0, int(round((height - 1) * ratio_y))))
        point = (x, y)
        if point not in points:
            points.append(point)
    return points


def _score_bubble_seed(
    pixel: tuple[int, int, int],
    fill_color: tuple[int, int, int],
) -> float:
    luminance = _color_luminance(pixel)
    fill_luminance = _color_luminance(fill_color)
    distance = _color_distance_manhattan(pixel, fill_color)
    if fill_luminance >= 170:
        return luminance * 1.4 - distance * 1.15 - _color_saturation(pixel) * 0.12
    return -distance * 1.1 - abs(luminance - fill_luminance) * 0.45 - _color_saturation(pixel) * 0.08


def _pixel_matches_bubble_fill(
    pixel: tuple[int, int, int],
    seed_color: tuple[int, int, int],
    fill_color: tuple[int, int, int],
) -> bool:
    fill_luminance = _color_luminance(fill_color)
    seed_luminance = _color_luminance(seed_color)
    pixel_luminance = _color_luminance(pixel)
    distance_from_fill = _color_distance_manhattan(pixel, fill_color)
    distance_from_seed = _color_distance_manhattan(pixel, seed_color)
    luminance_delta = abs(pixel_luminance - seed_luminance)
    saturation = _color_saturation(pixel)

    if fill_luminance >= 185:
        return distance_from_seed <= 72 or (
            distance_from_fill <= 112
            and pixel_luminance >= max(148.0, seed_luminance - 44.0)
            and saturation <= 100
        )
    if fill_luminance >= 135:
        return distance_from_seed <= 62 or (
            distance_from_fill <= 90 and luminance_delta <= 48.0 and saturation <= 112
        )
    return distance_from_seed <= 56 or (distance_from_fill <= 78 and luminance_delta <= 36.0)


def _extract_precise_bubble_mask_python(
    image: Image.Image,
    bbox: tuple[int, int, int, int],
    fill_color: tuple[int, int, int],
    fill_shape: str,
) -> Image.Image:
    x1, y1, x2, y2 = bbox
    crop = image.crop((x1, y1, x2, y2)).convert("RGB")
    width, height = crop.size
    if width < 4 or height < 4:
        return _build_region_shape_mask((width, height), fill_shape)

    blur_radius = max(1.2, min(4.0, min(width, height) / 34.0))
    blurred = crop.filter(ImageFilter.GaussianBlur(radius=blur_radius))
    blurred_pixels = blurred.load()
    shape_mask = _build_region_shape_mask((width, height), fill_shape)
    shape_pixels = shape_mask.load()

    seeds: list[tuple[float, int, int, tuple[int, int, int]]] = []
    for seed_x, seed_y in _seed_positions_for_region((width, height)):
        if shape_pixels[seed_x, seed_y] <= 0:
            continue
        seed_color = tuple(int(channel) for channel in blurred_pixels[seed_x, seed_y])
        seeds.append((_score_bubble_seed(seed_color, fill_color), seed_x, seed_y, seed_color))
    if not seeds:
        return shape_mask
    seeds.sort(key=lambda item: item[0], reverse=True)

    best_mask: Image.Image | None = None
    best_area = 0
    neighbor_offsets = ((1, 0), (-1, 0), (0, 1), (0, -1))
    for _, seed_x, seed_y, seed_color in seeds[:6]:
        if shape_pixels[seed_x, seed_y] <= 0:
            continue

        visited: set[tuple[int, int]] = set()
        queue: deque[tuple[int, int]] = deque([(seed_x, seed_y)])
        component_mask = Image.new("L", (width, height), 0)
        component_pixels = component_mask.load()
        area = 0

        while queue:
            current_x, current_y = queue.popleft()
            if (current_x, current_y) in visited:
                continue
            visited.add((current_x, current_y))

            if current_x < 0 or current_x >= width or current_y < 0 or current_y >= height:
                continue
            if shape_pixels[current_x, current_y] <= 0:
                continue

            current_color = tuple(int(channel) for channel in blurred_pixels[current_x, current_y])
            if not _pixel_matches_bubble_fill(current_color, seed_color, fill_color):
                continue

            if component_pixels[current_x, current_y] == 0:
                component_pixels[current_x, current_y] = 255
                area += 1
            for offset_x, offset_y in neighbor_offsets:
                queue.append((current_x + offset_x, current_y + offset_y))

        if area > best_area:
            best_mask = component_mask
            best_area = area

    min_area_ratio = 0.14 if fill_shape == "ellipse" else 0.10 if fill_shape == "roundrect" else 0.08
    min_area = max(24, int(width * height * min_area_ratio))
    if best_mask is None or best_area < min_area:
        return shape_mask

    expanded_mask = best_mask.filter(ImageFilter.MaxFilter(7)).filter(ImageFilter.MinFilter(3))
    inner_shape_kernel = 7 if fill_shape == "ellipse" else 5
    inner_shape_mask = shape_mask.filter(ImageFilter.MinFilter(inner_shape_kernel))
    refined_mask = ImageChops.multiply(ImageChops.lighter(expanded_mask, inner_shape_mask), shape_mask)
    if refined_mask.getbbox() is None:
        return shape_mask
    return refined_mask


def _extract_precise_bubble_mask_vectorized(
    image: Image.Image,
    bbox: tuple[int, int, int, int],
    fill_color: tuple[int, int, int],
    fill_shape: str,
) -> Image.Image:
    x1, y1, x2, y2 = bbox
    crop = image.crop((x1, y1, x2, y2)).convert("RGB")
    width, height = crop.size
    if width < 4 or height < 4:
        return _build_region_shape_mask((width, height), fill_shape)

    blur_radius = max(1.2, min(4.0, min(width, height) / 34.0))
    blurred = crop.filter(ImageFilter.GaussianBlur(radius=blur_radius))
    pixels = np.asarray(blurred, dtype=np.int16)
    shape_mask = _build_region_shape_mask((width, height), fill_shape)
    shape_array = np.asarray(shape_mask, dtype=np.uint8) > 0

    seeds: list[tuple[float, int, int, tuple[int, int, int]]] = []
    for seed_x, seed_y in _seed_positions_for_region((width, height)):
        if not shape_array[seed_y, seed_x]:
            continue
        seed_color = tuple(int(channel) for channel in pixels[seed_y, seed_x])
        seeds.append((_score_bubble_seed(seed_color, fill_color), seed_x, seed_y, seed_color))
    if not seeds:
        return shape_mask
    seeds.sort(key=lambda item: item[0], reverse=True)

    fill = np.asarray(fill_color, dtype=np.int16)
    fill_luminance = _color_luminance(fill_color)
    pixel_luminance = pixels[:, :, 0] * 0.299 + pixels[:, :, 1] * 0.587 + pixels[:, :, 2] * 0.114
    distance_from_fill = np.abs(pixels - fill).sum(axis=2)
    saturation = pixels.max(axis=2) - pixels.min(axis=2)
    best_component: Any | None = None
    best_area = 0

    for _, seed_x, seed_y, seed_color in seeds[:6]:
        seed = np.asarray(seed_color, dtype=np.int16)
        seed_luminance = _color_luminance(seed_color)
        distance_from_seed = np.abs(pixels - seed).sum(axis=2)
        luminance_delta = np.abs(pixel_luminance - seed_luminance)
        if fill_luminance >= 185:
            matches = (distance_from_seed <= 72) | (
                (distance_from_fill <= 112)
                & (pixel_luminance >= max(148.0, seed_luminance - 44.0))
                & (saturation <= 100)
            )
        elif fill_luminance >= 135:
            matches = (distance_from_seed <= 62) | (
                (distance_from_fill <= 90) & (luminance_delta <= 48.0) & (saturation <= 112)
            )
        else:
            matches = (distance_from_seed <= 56) | ((distance_from_fill <= 78) & (luminance_delta <= 36.0))
        candidate = (matches & shape_array).astype(np.uint8)
        if not candidate[seed_y, seed_x]:
            continue
        _, labels = cv2.connectedComponents(candidate, connectivity=4)
        label = int(labels[seed_y, seed_x])
        if label <= 0:
            continue
        component = labels == label
        area = int(np.count_nonzero(component))
        if area > best_area:
            best_component = component
            best_area = area

    min_area_ratio = 0.14 if fill_shape == "ellipse" else 0.10 if fill_shape == "roundrect" else 0.08
    min_area = max(24, int(width * height * min_area_ratio))
    if best_component is None or best_area < min_area:
        return shape_mask

    best_mask = Image.fromarray(np.where(best_component, 255, 0).astype(np.uint8), mode="L")
    expanded_mask = best_mask.filter(ImageFilter.MaxFilter(7)).filter(ImageFilter.MinFilter(3))
    inner_shape_kernel = 7 if fill_shape == "ellipse" else 5
    inner_shape_mask = shape_mask.filter(ImageFilter.MinFilter(inner_shape_kernel))
    refined_mask = ImageChops.multiply(ImageChops.lighter(expanded_mask, inner_shape_mask), shape_mask)
    return refined_mask if refined_mask.getbbox() is not None else shape_mask


def _extract_precise_bubble_mask(
    image: Image.Image,
    bbox: tuple[int, int, int, int],
    fill_color: tuple[int, int, int],
    fill_shape: str,
) -> Image.Image:
    if cv2 is None or np is None:
        return _extract_precise_bubble_mask_python(image, bbox, fill_color, fill_shape)
    return _extract_precise_bubble_mask_vectorized(image, bbox, fill_color, fill_shape)


def _resolve_mask_content_box(
    mask: Image.Image,
    fill_shape: str,
    direction: str,
) -> tuple[int, int, int, int] | None:
    mask_bbox = mask.getbbox()
    if mask_bbox is None:
        return None

    left, top, right, bottom = mask_bbox
    width = right - left
    height = bottom - top
    if width < 16 or height < 16:
        return None

    pixels = mask.load()
    row_ratio = 0.60 if fill_shape == "ellipse" else 0.42 if fill_shape == "roundrect" else 0.20
    col_ratio = 0.54 if fill_shape == "ellipse" else 0.42 if fill_shape == "roundrect" else 0.20
    if direction == "vertical" and fill_shape == "ellipse":
        row_ratio = 0.56
        col_ratio = 0.48

    row_widths: list[tuple[int, int]] = []
    max_row_width = 0
    for current_y in range(top, bottom):
        row_left: int | None = None
        row_right: int | None = None
        for current_x in range(left, right):
            if pixels[current_x, current_y] <= 0:
                continue
            if row_left is None:
                row_left = current_x
            row_right = current_x
        if row_left is None or row_right is None:
            continue
        row_width = row_right - row_left + 1
        row_widths.append((current_y, row_width))
        max_row_width = max(max_row_width, row_width)

    col_heights: list[tuple[int, int]] = []
    max_col_height = 0
    for current_x in range(left, right):
        column_top: int | None = None
        column_bottom: int | None = None
        for current_y in range(top, bottom):
            if pixels[current_x, current_y] <= 0:
                continue
            if column_top is None:
                column_top = current_y
            column_bottom = current_y
        if column_top is None or column_bottom is None:
            continue
        column_height = column_bottom - column_top + 1
        col_heights.append((current_x, column_height))
        max_col_height = max(max_col_height, column_height)

    if max_row_width <= 0 or max_col_height <= 0:
        return None

    qualified_rows = [
        current_y
        for current_y, row_width in row_widths
        if row_width >= max(8, int(round(max_row_width * row_ratio)))
    ]
    qualified_cols = [
        current_x
        for current_x, column_height in col_heights
        if column_height >= max(8, int(round(max_col_height * col_ratio)))
    ]

    if not qualified_rows or not qualified_cols:
        return mask_bbox

    content_left = qualified_cols[0]
    content_top = qualified_rows[0]
    content_right = qualified_cols[-1] + 1
    content_bottom = qualified_rows[-1] + 1

    content_width = content_right - content_left
    content_height = content_bottom - content_top
    pad_x = max(2, min(10, content_width // (9 if direction == "vertical" else 12)))
    pad_y = max(2, min(10, content_height // (12 if direction == "vertical" else 10)))

    content_left = min(content_right - 8, content_left + pad_x)
    content_top = min(content_bottom - 8, content_top + pad_y)
    content_right = max(content_left + 8, content_right - pad_x)
    content_bottom = max(content_top + 8, content_bottom - pad_y)

    if content_right - content_left < 16 or content_bottom - content_top < 16:
        return mask_bbox
    return content_left, content_top, content_right, content_bottom


def _shrink_mask(mask: Image.Image, steps: int) -> Image.Image:
    if steps <= 0 or mask.getbbox() is None:
        return mask
    result = mask
    for _ in range(max(1, int(steps))):
        shrunk = result.filter(ImageFilter.MinFilter(3))
        if shrunk.getbbox() is None:
            break
        result = shrunk
    return result


def _build_region_fill_area_mask(
    outer_mask: Image.Image,
    fill_shape: str,
    direction: str,
) -> Image.Image:
    # 不收缩填充掩码，使用完整的气泡轮廓区域进行背景填充，
    # 确保原文被完全擦除。高斯模糊已经提供了足够的边缘柔化。
    del fill_shape, direction
    return outer_mask


def _resolve_manga_cleanup_limit_mask(
    text_bbox: tuple[int, int, int, int],
    body_bbox: tuple[int, int, int, int],
    bubble_fill_mask: Image.Image,
    *,
    safe_box: tuple[int, int, int, int] | None,
    explicit_shape: str | None,
) -> tuple[Image.Image, bool]:
    """Return the artwork-safe mask used only for removing source glyphs.

    Older upstream-compatible project files contain ``lines`` but no QingJuan
    ``body_bbox`` metadata.  Parsing such a file necessarily falls back to the
    tight OCR text box for the body box.  Applying an ellipse/roundrect mask to
    that tight box clips glyphs near its corners, which leaves Japanese stroke
    fragments behind.  A full rectangular permit mask is safe in this one
    case: ``_erase_manga_source_text`` still edits only the detected/dilated ink
    pixels and the rectangle cannot extend outside the OCR text box.
    """
    missing_container_geometry = (
        explicit_shape is None
        and body_bbox == text_bbox
        and (safe_box is None or safe_box == text_bbox)
    )
    if missing_container_geometry:
        return Image.new("L", bubble_fill_mask.size, 255), True
    return bubble_fill_mask, False


def _build_region_safe_text_mask(
    fill_mask: Image.Image,
    fill_shape: str,
    direction: str,
) -> Image.Image:
    # 减少收缩步数，让翻译文字更贴近原文位置，
    # 避免文字被挤压到气泡中心导致与残留原文错位。
    shrink_steps = 2 if fill_shape == "ellipse" else 1
    if direction == "vertical":
        shrink_steps += 1
    return _shrink_mask(fill_mask, shrink_steps)


def _resolve_region_text_box(
    region: dict[str, Any],
    *,
    image_size: tuple[int, int],
    body_bbox: tuple[int, int, int, int],
    safe_mask: Image.Image,
    fill_shape: str,
    direction: str,
) -> tuple[int, int, int, int]:
    safe_box = _normalize_region_box_within(region.get("safe_box"), image_size, body_bbox)
    derived_box_rel = _resolve_mask_content_box(safe_mask, fill_shape, direction)
    derived_box_abs: tuple[int, int, int, int] | None = None
    if derived_box_rel is not None:
        derived_box_abs = _intersect_region_bboxes(
            (
                body_bbox[0] + derived_box_rel[0],
                body_bbox[1] + derived_box_rel[1],
                body_bbox[0] + derived_box_rel[2],
                body_bbox[1] + derived_box_rel[3],
            ),
            body_bbox,
        )

    if safe_box is not None:
        target_box = safe_box
        if derived_box_abs is not None:
            overlap = _intersect_region_bboxes(safe_box, derived_box_abs)
            if overlap is not None:
                overlap_area = (overlap[2] - overlap[0]) * (overlap[3] - overlap[1])
                safe_area = (safe_box[2] - safe_box[0]) * (safe_box[3] - safe_box[1])
                if overlap_area >= safe_area * 0.72:
                    target_box = overlap
        tightened = _shrink_absolute_bbox(
            target_box,
            max(1, min(8, (target_box[2] - target_box[0]) // 18)),
            max(1, min(8, (target_box[3] - target_box[1]) // 18)),
        )
        return tightened or target_box

    if derived_box_abs is not None:
        tightened = _shrink_absolute_bbox(
            derived_box_abs,
            max(
                1,
                min(8, (derived_box_abs[2] - derived_box_abs[0]) // (10 if direction == "vertical" else 12)),
            ),
            max(
                1,
                min(8, (derived_box_abs[3] - derived_box_abs[1]) // (12 if direction == "vertical" else 10)),
            ),
        )
        return tightened or derived_box_abs

    inset_x, inset_y = _resolve_region_insets(region, body_bbox, direction)
    fallback_box = (
        body_bbox[0] + inset_x,
        body_bbox[1] + inset_y,
        body_bbox[2] - inset_x,
        body_bbox[3] - inset_y,
    )
    return _intersect_region_bboxes(fallback_box, body_bbox) or body_bbox


def _apply_region_mask_fill(
    canvas: Image.Image,
    bbox: tuple[int, int, int, int],
    fill_color: tuple[int, int, int],
    mask: Image.Image,
) -> None:
    if mask.getbbox() is None:
        return
    x1, y1, x2, y2 = bbox
    fill_layer = Image.new("RGBA", (max(1, x2 - x1), max(1, y2 - y1)), fill_color + (255,))
    softened_mask = mask.filter(ImageFilter.GaussianBlur(radius=1.2))
    canvas.paste(fill_layer, (x1, y1), softened_mask)


def _render_text_layout(
    draw: ImageDraw.ImageDraw,
    region_left: int,
    region_top: int,
    box_size: tuple[int, int],
    layout: dict[str, Any],
    text_color: tuple[int, int, int],
    stroke_color: tuple[int, int, int] | None = None,
    stroke_width: int | None = None,
) -> None:
    box_width, box_height = box_size
    render_inset = layout.get("render_inset") or (0, 0)
    try:
        inset_x, inset_y = int(render_inset[0]), int(render_inset[1])
    except (TypeError, ValueError, IndexError):
        inset_x, inset_y = 0, 0
    if inset_x or inset_y:
        region_left += max(0, inset_x)
        region_top += max(0, inset_y)
        box_width = max(1, box_width - max(0, inset_x) * 2)
        box_height = max(1, box_height - max(0, inset_y) * 2)
    font = layout["font"]
    direction = str(layout.get("direction") or "horizontal")
    # 描边宽度按字号比例计算（与 manga-image-translator 一致），无描边色时退化为纯文字。
    font_size_value = int(layout.get("font_size") or 0)
    resolved_stroke_width = (
        max(0, int(stroke_width))
        if stroke_width is not None
        else max(1, round(font_size_value * MANGA_STROKE_RATIO))
        if stroke_color is not None
        else 0
    )

    if direction == "vertical":
        columns = [column for column in layout.get("columns", []) if column.get("chars")]
        if not columns:
            return
        total_width = int(layout.get("content_width") or 0)
        current_right = region_left + max(0, (box_width - total_width) / 2) + total_width
        column_gap = int(layout.get("column_gap") or 0)
        char_gap = int(layout.get("char_gap") or 0)
        for column in columns:
            column_width = int(column.get("width") or 0)
            column_height = int(column.get("height") or 0)
            column_left = current_right - column_width
            cursor_y = region_top + max(0, (box_height - column_height) / 2)
            for char_info in column.get("chars", []):
                char = str(char_info.get("text") or "")
                char_width = int(char_info.get("width") or 0)
                char_height = int(char_info.get("height") or 0)
                glyph_bbox = char_info.get("bbox") or draw.textbbox((0, 0), char, font=font)
                offset_x_ratio, offset_y_ratio = char_info.get("offset_ratio") or (0.0, 0.0)
                font_size = int(layout.get("font_size") or 0)
                char_x = (
                    column_left
                    + max(0, (column_width - char_width) / 2)
                    - glyph_bbox[0]
                    + font_size * offset_x_ratio
                )
                char_y = cursor_y - glyph_bbox[1] + font_size * offset_y_ratio
                if resolved_stroke_width:
                    draw.text(
                        (char_x, char_y),
                        char,
                        font=font,
                        fill=text_color,
                        stroke_width=resolved_stroke_width,
                        stroke_fill=stroke_color,
                    )
                else:
                    draw.text((char_x, char_y), char, font=font, fill=text_color)
                cursor_y += char_height + char_gap
            current_right = column_left - column_gap
        return

    lines = [str(item) for item in layout.get("lines", []) if str(item).strip()]
    rendered_text = "\n".join(lines).strip()
    if not rendered_text:
        return
    spacing = int(layout.get("spacing") or 0)
    text_bbox = draw.multiline_textbbox(
        (0, 0),
        rendered_text,
        font=font,
        spacing=spacing,
        align="center",
        stroke_width=resolved_stroke_width,
    )
    text_width = max(0, text_bbox[2] - text_bbox[0])
    text_height = max(0, text_bbox[3] - text_bbox[1])
    text_x = region_left + max(0, (box_width - text_width) / 2) - text_bbox[0]
    text_y = region_top + max(0, (box_height - text_height) / 2) - text_bbox[1]
    draw.multiline_text(
        (text_x, text_y),
        rendered_text,
        font=font,
        fill=text_color,
        spacing=spacing,
        align="center",
        stroke_width=resolved_stroke_width,
        stroke_fill=stroke_color,
    )


def _render_text_layout_to_bubble_layer(
    body_bbox: tuple[int, int, int, int],
    content_box: tuple[int, int, int, int],
    layout: dict[str, Any],
    text_color: tuple[int, int, int],
    stroke_color: tuple[int, int, int] | None,
    stroke_width: int | None,
    safe_mask: Image.Image,
) -> tuple[Image.Image, int]:
    body_width = max(1, body_bbox[2] - body_bbox[0])
    body_height = max(1, body_bbox[3] - body_bbox[1])
    layer = Image.new("RGBA", (body_width, body_height), (0, 0, 0, 0))
    layer_draw = ImageDraw.Draw(layer)
    _render_text_layout(
        layer_draw,
        content_box[0] - body_bbox[0],
        content_box[1] - body_bbox[1],
        (
            max(1, content_box[2] - content_box[0]),
            max(1, content_box[3] - content_box[1]),
        ),
        layout,
        text_color,
        stroke_color,
        stroke_width,
    )

    normalized_mask = safe_mask.convert("L")
    if normalized_mask.size != layer.size:
        normalized_mask = normalized_mask.resize(layer.size, Image.Resampling.NEAREST)
    alpha = layer.getchannel("A")
    outside_mask = ImageChops.subtract(alpha, ImageChops.multiply(alpha, normalized_mask))
    outside_pixel_count = sum(1 for value in _image_pixels(outside_mask) if value > 0)
    layer.putalpha(ImageChops.multiply(alpha, normalized_mask))
    return layer, outside_pixel_count


def _largest_rectangle_in_mask(
    mask: Image.Image,
    limit_box: tuple[int, int, int, int] | None = None,
) -> tuple[int, int, int, int] | None:
    normalized_mask = mask.convert("L")
    width, height = normalized_mask.size
    left, top, right, bottom = limit_box or (0, 0, width, height)
    left = max(0, min(width, int(left)))
    top = max(0, min(height, int(top)))
    right = max(left, min(width, int(right)))
    bottom = max(top, min(height, int(bottom)))
    if right <= left or bottom <= top:
        return None

    pixels = normalized_mask.load()
    heights = [0] * width
    best_area = 0
    best_box: tuple[int, int, int, int] | None = None
    for current_y in range(top, bottom):
        for current_x in range(left, right):
            heights[current_x] = heights[current_x] + 1 if pixels[current_x, current_y] >= 250 else 0

        stack: list[int] = []
        for current_x in range(left, right + 1):
            current_height = heights[current_x] if current_x < right else 0
            while stack and heights[stack[-1]] > current_height:
                bar_x = stack.pop()
                bar_height = heights[bar_x]
                rectangle_left = stack[-1] + 1 if stack else left
                area = bar_height * (current_x - rectangle_left)
                if area <= best_area:
                    continue
                best_area = area
                best_box = (
                    rectangle_left,
                    current_y - bar_height + 1,
                    current_x,
                    current_y + 1,
                )
            if current_x < right:
                stack.append(current_x)

    if best_box is None:
        return None
    if best_box[2] - best_box[0] >= 6 and best_box[3] - best_box[1] >= 6:
        return best_box[0] + 1, best_box[1] + 1, best_box[2] - 1, best_box[3] - 1
    return best_box


def _render_compressed_text_layout_to_bubble_layer(
    body_bbox: tuple[int, int, int, int],
    content_box: tuple[int, int, int, int],
    layout: dict[str, Any],
    text_color: tuple[int, int, int],
    stroke_color: tuple[int, int, int] | None,
    stroke_width: int | None,
    safe_mask: Image.Image,
) -> tuple[Image.Image, float]:
    body_width = max(1, body_bbox[2] - body_bbox[0])
    body_height = max(1, body_bbox[3] - body_bbox[1])
    output_layer = Image.new("RGBA", (body_width, body_height), (0, 0, 0, 0))
    relative_content_box = (
        max(0, content_box[0] - body_bbox[0]),
        max(0, content_box[1] - body_bbox[1]),
        min(body_width, content_box[2] - body_bbox[0]),
        min(body_height, content_box[3] - body_bbox[1]),
    )
    target_box = _largest_rectangle_in_mask(safe_mask, relative_content_box)
    if target_box is None:
        return output_layer, 0.0

    resolved_stroke_width = max(0, int(stroke_width or 0))
    source_padding = max(4, resolved_stroke_width * 2 + 2)
    source_width = max(
        relative_content_box[2] - relative_content_box[0],
        int(layout.get("content_width") or 0) + source_padding * 2,
        8,
    )
    source_height = max(
        relative_content_box[3] - relative_content_box[1],
        int(layout.get("content_height") or 0) + source_padding * 2,
        8,
    )
    source_layer = Image.new("RGBA", (source_width, source_height), (0, 0, 0, 0))
    _render_text_layout(
        ImageDraw.Draw(source_layer),
        source_padding,
        source_padding,
        (
            max(1, source_width - source_padding * 2),
            max(1, source_height - source_padding * 2),
        ),
        layout,
        text_color,
        stroke_color,
        stroke_width,
    )
    glyph_box = source_layer.getchannel("A").getbbox()
    if glyph_box is None:
        return output_layer, 0.0
    glyph_layer = source_layer.crop(glyph_box)
    target_width = max(1, target_box[2] - target_box[0])
    target_height = max(1, target_box[3] - target_box[1])
    scale = min(
        1.0,
        target_width / max(1, glyph_layer.width),
        target_height / max(1, glyph_layer.height),
    )
    scaled_size = (
        max(1, min(target_width, int(math.floor(glyph_layer.width * scale)))),
        max(1, min(target_height, int(math.floor(glyph_layer.height * scale)))),
    )
    if glyph_layer.size != scaled_size:
        glyph_layer = glyph_layer.resize(scaled_size, Image.Resampling.LANCZOS)
    target_x = target_box[0] + max(0, (target_width - glyph_layer.width) // 2)
    target_y = target_box[1] + max(0, (target_height - glyph_layer.height) // 2)
    output_layer.alpha_composite(glyph_layer, (target_x, target_y))
    output_layer.putalpha(ImageChops.multiply(output_layer.getchannel("A"), safe_mask.convert("L")))
    return output_layer, scale


def _normalize_manga_text_direction(value: Any) -> str | None:
    normalized = str(value or "").strip().lower()
    alias_map = {
        "v": "vertical",
        "vert": "vertical",
        "vertical": "vertical",
        "竖排": "vertical",
        "h": "horizontal",
        "hor": "horizontal",
        "horizontal": "horizontal",
        "横排": "horizontal",
    }
    return alias_map.get(normalized)


def _normalize_manga_region_shape(value: Any) -> str | None:
    normalized = str(value or "").strip().lower()
    alias_map = {
        "oval": "ellipse",
        "ellipse": "ellipse",
        "circle": "ellipse",
        "round": "roundrect",
        "rounded": "roundrect",
        "roundrect": "roundrect",
        "rounded_rectangle": "roundrect",
        "box": "rect",
        "rect": "rect",
        "rectangle": "rect",
    }
    return alias_map.get(normalized)


def _normalize_manga_padding_ratio(value: Any) -> float | None:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return max(0.55, min(0.90, parsed))


def _coerce_manga_ocr_region(
    raw_region: Any,
    *,
    image_size: tuple[int, int],
    fallback_order: int,
) -> MangaOcrRegion | None:
    if not isinstance(raw_region, dict):
        return None

    source_text = str(raw_region.get("source_text") or raw_region.get("text") or "").strip()
    bbox = _normalize_region_bbox(raw_region.get("bbox"), image_size)
    if bbox is None or not source_text:
        return None

    normalized_body_bbox = _normalize_region_box_within(raw_region.get("body_bbox"), image_size)
    if normalized_body_bbox is not None and _intersect_region_bboxes(normalized_body_bbox, bbox):
        body_bbox = _union_region_bboxes(normalized_body_bbox, bbox)
    else:
        body_bbox = bbox
    safe_box = _normalize_region_box_within(raw_region.get("safe_box"), image_size, body_bbox)
    source_direction = _normalize_manga_text_direction(raw_region.get("source_direction"))
    direction = _normalize_manga_text_direction(raw_region.get("direction")) or source_direction
    if direction is None:
        direction = _normalize_layout_direction(
            source_direction,
            (max(8, body_bbox[2] - body_bbox[0]), max(8, body_bbox[3] - body_bbox[1])),
            source_text,
        )

    try:
        order = int(raw_region.get("order") or fallback_order)
    except (TypeError, ValueError):
        order = fallback_order

    background = str(raw_region.get("background") or "").strip() or None
    text_color = str(raw_region.get("text_color") or "").strip() or None
    shape = _normalize_manga_region_shape(raw_region.get("shape"))
    padding_ratio = _normalize_manga_padding_ratio(raw_region.get("padding_ratio"))

    return MangaOcrRegion(
        order=max(1, order),
        bbox=bbox,
        body_bbox=body_bbox,
        safe_box=safe_box,
        source_text=source_text,
        source_direction=source_direction,
        direction=direction,
        background=background,
        text_color=text_color,
        shape=shape,
        padding_ratio=padding_ratio,
    )


def _coerce_manga_ocr_page_payload(
    raw_payload: dict[str, Any],
    *,
    image_size: tuple[int, int],
    page_number: int,
) -> MangaOcrPagePayload:
    regions_value = raw_payload.get("regions")
    if not isinstance(regions_value, list):
        raise ValueError("视觉 OCR 模型返回缺少 regions 数组")

    raw_region_count = len(regions_value)
    regions: list[MangaOcrRegion] = []
    for index, raw_region in enumerate(regions_value, start=1):
        region = _coerce_manga_ocr_region(raw_region, image_size=image_size, fallback_order=index)
        if region is not None:
            regions.append(region)
    coerced_region_count = len(regions)
    deduped_regions, deduped_region_count = _dedupe_manga_ocr_regions(regions)

    ordered_regions = sorted(
        deduped_regions,
        key=lambda item: (
            item.order,
            item.bbox[1] if item.bbox else 0,
            item.bbox[0] if item.bbox else 0,
        ),
    )
    normalized_regions = [
        region.model_copy(update={"order": index}) for index, region in enumerate(ordered_regions, start=1)
    ]
    return MangaOcrPagePayload(
        page_number=page_number,
        image_size=image_size,
        regions=normalized_regions,
        diagnostics={
            "raw_region_count": raw_region_count,
            "coerced_region_count": coerced_region_count,
            "deduped_region_count": deduped_region_count,
            "final_region_count": len(normalized_regions),
        },
    )


def _histogram_median(histogram: list[int], total_pixels: int) -> int:
    midpoint = max(1, total_pixels) // 2
    cumulative = 0
    for value, histogram_count in enumerate(histogram):
        cumulative += histogram_count
        if cumulative >= midpoint:
            return value
    return 255


def _manga_region_image_evidence_score(
    image: Image.Image,
    bbox: tuple[int, int, int, int],
) -> float:
    crop = image.crop(bbox).convert("RGB")
    width, height = crop.size
    if width <= 2 or height <= 2:
        return 0.0
    max_dimension = max(width, height)
    if max_dimension > 512:
        scale = 512 / max_dimension
        crop = crop.resize(
            (max(3, int(round(width * scale))), max(3, int(round(height * scale)))),
            Image.Resampling.BILINEAR,
        )
        width, height = crop.size

    channel_histograms = crop.histogram()
    total_pixels = width * height
    medians = tuple(
        _histogram_median(channel_histograms[index * 256 : (index + 1) * 256], total_pixels)
        for index in range(3)
    )
    extrema = crop.getextrema()
    contrast_range = max(high - low for low, high in extrema)
    if contrast_range < 14:
        return 0.0
    foreground_threshold = max(12, min(42, int(round(contrast_range * 0.12))))
    row_minimum = max(2, int(round(width * 0.008)))
    column_minimum = max(2, int(round(height * 0.025)))
    active_rows = [0] * height
    active_columns = [0] * width
    pixels = crop.load()
    for y in range(height):
        for x in range(width):
            pixel = pixels[x, y]
            if max(abs(pixel[channel] - medians[channel]) for channel in range(3)) < foreground_threshold:
                continue
            active_rows[y] += 1
            active_columns[x] += 1
    row_coverage = sum(count >= row_minimum for count in active_rows) / height
    column_coverage = sum(count >= column_minimum for count in active_columns) / width
    return min(row_coverage, column_coverage)


def _filter_manga_ocr_regions_by_image_evidence(
    payload: MangaOcrPagePayload,
    image: Image.Image,
) -> MangaOcrPagePayload:
    accepted_regions = [
        region for region in payload.regions if _manga_region_image_evidence_score(image, region.bbox) >= 0.34
    ]
    normalized_regions = [
        region.model_copy(update={"order": index}) for index, region in enumerate(accepted_regions, start=1)
    ]
    diagnostics = dict(payload.diagnostics or {})
    diagnostics["image_evidence_rejected_region_count"] = len(payload.regions) - len(normalized_regions)
    diagnostics["image_evidence_region_count"] = len(normalized_regions)
    diagnostics["final_region_count"] = len(normalized_regions)
    return payload.model_copy(update={"regions": normalized_regions, "diagnostics": diagnostics})


def _estimate_manga_region_char_budget(
    region: MangaOcrRegion | MangaTranslatedRegion,
) -> int:
    bbox = region.safe_box or region.body_bbox or region.bbox
    if bbox is None:
        return 32
    width = max(8, bbox[2] - bbox[0])
    height = max(8, bbox[3] - bbox[1])
    area = width * height
    direction = str(region.direction or region.source_direction or "horizontal")
    budget = int(round(area / (1600 if direction == "vertical" else 900)))
    if direction == "vertical":
        budget = min(budget, max(6, height // 18 + 4))
    if width <= 72:
        budget = min(budget, 20)
    return max(6, min(72, budget))


def _normalize_manga_region_translation_text(value: Any) -> str:
    text = _strip_markdown_fences(str(value or ""))
    if not text:
        return ""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = re.sub(r"[ \t]{2,}", " ", text).strip()
    if len(text) >= 2 and (text[0], text[-1]) in {
        ('"', '"'),
        ("'", "'"),
        ("“", "”"),
        ("「", "」"),
        ("『", "』"),
    }:
        inner = text[1:-1].strip()
        if inner:
            text = inner
    return text


def _manga_translation_char_count(value: Any) -> int:
    return len(re.sub(r"\s+", "", str(value or "")))


def _build_manga_translation_compaction_prompt(
    *,
    target_language: str,
    source_regions: list[MangaOcrRegion],
    translated_regions: list[MangaTranslatedRegion],
) -> str:
    source_by_order = {region.order: region for region in source_regions}
    compact_items: list[dict[str, Any]] = []
    for translated_region in translated_regions:
        source_region = source_by_order.get(translated_region.order)
        if source_region is None:
            continue
        max_chars = _estimate_manga_region_char_budget(source_region)
        if _manga_translation_char_count(translated_region.translation) <= max_chars:
            continue
        compact_items.append(
            {
                "order": source_region.order,
                "source_text": source_region.source_text,
                "current_translation": translated_region.translation,
                "max_chars": max_chars,
            }
        )
    if not compact_items:
        return ""
    return (
        f"Rewrite the existing {target_language} manga translations so they fit their bubbles. "
        "Return JSON only with schema "
        '{"translations":[{"order":1,"translation":"..."}]}. '
        "Return exactly one item for every input item. Each max_chars value is a hard maximum "
        "for non-whitespace characters. Keep the complete meaning, tone, names, emphasis, and "
        "speech intent, but remove redundant wording and punctuation. Never return an empty "
        "translation, notes, labels, ellipses that replace meaning, or truncated fragments. "
        f"Input items: {json.dumps(compact_items, ensure_ascii=False)}"
    )


def _build_manga_ocr_prompt(*, image_size: tuple[int, int]) -> str:
    width, height = image_size
    return (
        "You are a manga OCR and layout analyzer. "
        "Inspect the entire page at full resolution and detect every readable text region. "
        "Include vertical dialogue, horizontal dialogue, narration, furigana, small side notes, "
        "outlined or colored text, and sound effects; do not stop after finding the largest bubbles. "
        "Return JSON only. Do not output markdown or explanations. "
        'JSON schema: {"regions":[{"order":1,"bbox":[x1,y1,x2,y2],"body_bbox":[x1,y1,x2,y2],"safe_box":[x1,y1,x2,y2],"source_text":"...","background":"#RRGGBB","text_color":"#RRGGBB","source_direction":"vertical|horizontal","direction":"vertical|horizontal","padding_ratio":0.72,"shape":"ellipse|roundrect|rect"}]}. '
        f"Coordinates must use the original image pixels. Original image size: {width}x{height}. "
        "Auto-detect the original language from the image. "
        "Do not translate the text. Keep source_text exactly as recognized from the image. "
        "Prefer one region per speech bubble, caption box, side-note group, or sound-effect block. "
        "Bounding boxes must tightly fit the visible text and bubble body instead of the entire panel. "
        "bbox may include the full readable area, but body_bbox should cover the bubble or caption body and exclude tails when possible. "
        "safe_box should be a conservative inner rectangle that avoids borders and tails. "
        "source_direction should describe the original text flow; direction should describe the recommended render direction for translated text. "
        "For tall bubbles, prefer vertical. For wide bubbles or narration boxes, prefer horizontal. "
        "padding_ratio must be a number between 0.55 and 0.90 describing the safe inner area for redrawing text. "
        "shape should describe the original bubble body when possible."
    )


def _expand_region_bbox(
    bbox: tuple[int, int, int, int],
    image_size: tuple[int, int],
    *,
    expand_x_ratio: float,
    expand_y_ratio: float,
    min_expand: int = 4,
) -> tuple[int, int, int, int]:
    x1, y1, x2, y2 = bbox
    width, height = image_size
    box_width = max(1, x2 - x1)
    box_height = max(1, y2 - y1)
    expand_x = max(min_expand, int(round(box_width * expand_x_ratio)))
    expand_y = max(min_expand, int(round(box_height * expand_y_ratio)))
    return (
        max(0, x1 - expand_x),
        max(0, y1 - expand_y),
        min(width, x2 + expand_x),
        min(height, y2 + expand_y),
    )


def _external_ocr_inferred_direction(bbox: tuple[int, int, int, int]) -> str:
    width = max(1, bbox[2] - bbox[0])
    height = max(1, bbox[3] - bbox[1])
    return "vertical" if height > width * 1.35 else "horizontal"


def _axis_overlap_length(left_start: int, left_end: int, right_start: int, right_end: int) -> int:
    return max(0, min(left_end, right_end) - max(left_start, right_start))


def _axis_gap_length(left_start: int, left_end: int, right_start: int, right_end: int) -> int:
    overlap = _axis_overlap_length(left_start, left_end, right_start, right_end)
    if overlap > 0:
        return 0
    return max(right_start - left_end, left_start - right_end, 0)


def _union_region_bboxes(
    left: tuple[int, int, int, int],
    right: tuple[int, int, int, int],
) -> tuple[int, int, int, int]:
    return (
        min(left[0], right[0]),
        min(left[1], right[1]),
        max(left[2], right[2]),
        max(left[3], right[3]),
    )


def _should_merge_external_ocr_boxes(
    left_bbox: tuple[int, int, int, int],
    right_bbox: tuple[int, int, int, int],
    direction: str,
) -> bool:
    left_width = max(1, left_bbox[2] - left_bbox[0])
    right_width = max(1, right_bbox[2] - right_bbox[0])
    left_height = max(1, left_bbox[3] - left_bbox[1])
    right_height = max(1, right_bbox[3] - right_bbox[1])
    avg_width = (left_width + right_width) / 2
    avg_height = (left_height + right_height) / 2

    horizontal_gap = _axis_gap_length(left_bbox[0], left_bbox[2], right_bbox[0], right_bbox[2])
    vertical_gap = _axis_gap_length(left_bbox[1], left_bbox[3], right_bbox[1], right_bbox[3])
    vertical_overlap = _axis_overlap_length(left_bbox[1], left_bbox[3], right_bbox[1], right_bbox[3])
    vertical_overlap_ratio = vertical_overlap / max(1.0, min(left_height, right_height))

    if direction == "vertical":
        return (
            horizontal_gap <= max(10, int(round(avg_width * 0.9)))
            and vertical_overlap_ratio >= 0.52
            and vertical_gap <= max(10, int(round(avg_height * 0.22)))
        )

    return (
        vertical_overlap_ratio >= 0.58
        and vertical_gap <= max(8, int(round(avg_height * 0.28)))
        and horizontal_gap <= max(12, int(round(avg_width * 0.95)))
    )


def _merge_external_ocr_lines(
    items: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    if len(items) <= 1:
        return items

    remaining = [dict(item) for item in items]
    merged: list[dict[str, Any]] = []

    while remaining:
        current = remaining.pop(0)
        current_bbox = current["bbox"]
        current_direction = str(current["direction"] or "horizontal")
        group = [current]
        changed = True

        while changed:
            changed = False
            next_remaining: list[dict[str, Any]] = []
            for candidate in remaining:
                if str(candidate["direction"] or "horizontal") != current_direction:
                    next_remaining.append(candidate)
                    continue
                if _external_ocr_item_is_non_mergeable(current) or _external_ocr_item_is_non_mergeable(
                    candidate
                ):
                    next_remaining.append(candidate)
                    continue
                if _should_merge_external_ocr_boxes(current_bbox, candidate["bbox"], current_direction):
                    group.append(candidate)
                    current_bbox = _union_region_bboxes(current_bbox, candidate["bbox"])
                    changed = True
                else:
                    next_remaining.append(candidate)
            remaining = next_remaining

        if current_direction == "vertical":
            ordered_group = sorted(group, key=lambda item: (item["bbox"][0], item["bbox"][1]), reverse=True)
        else:
            ordered_group = sorted(group, key=lambda item: (item["bbox"][1], item["bbox"][0]))

        merged_text = "\n".join(
            str(item["text"]).strip() for item in ordered_group if str(item["text"]).strip()
        ).strip()
        merged_bbox = ordered_group[0]["bbox"]
        for item in ordered_group[1:]:
            merged_bbox = _union_region_bboxes(merged_bbox, item["bbox"])
        merged.append(
            {
                "bbox": merged_bbox,
                "text": merged_text,
                "direction": current_direction,
                "line_count": len(ordered_group),
            }
        )

    return merged


def _external_ocr_item_is_non_mergeable(item: dict[str, Any]) -> bool:
    text = re.sub(r"\s+", "", str(item.get("text") or ""))
    bbox = item.get("bbox")
    if not text or not isinstance(bbox, (list, tuple)) or len(bbox) != 4:
        return True
    width = max(1, int(bbox[2]) - int(bbox[0]))
    height = max(1, int(bbox[3]) - int(bbox[1]))
    if text.isascii() and len(text) <= 6:
        return True
    return len(text) <= 2 and max(width, height) >= 64


def _estimate_external_ocr_fill_color(
    image: Image.Image,
    text_bbox: tuple[int, int, int, int],
    direction: str,
) -> tuple[int, int, int]:
    sample_bbox = _expand_region_bbox(
        text_bbox,
        image.size,
        expand_x_ratio=0.22 if direction == "vertical" else 0.16,
        expand_y_ratio=0.16 if direction == "vertical" else 0.22,
        min_expand=5,
    )
    inset_x = max(1, min(12, (sample_bbox[2] - sample_bbox[0]) // 7))
    inset_y = max(1, min(12, (sample_bbox[3] - sample_bbox[1]) // 7))
    interior_bbox = _shrink_absolute_bbox(sample_bbox, inset_x, inset_y) or sample_bbox
    interior_pixels = _image_pixels(image.convert("RGB").crop(interior_bbox))
    if interior_pixels:
        high_luminance_pixels = [
            color
            for color in interior_pixels
            if _color_luminance(color) >= 176 and _color_saturation(color) <= 72
        ]
        low_luminance_pixels = [
            color
            for color in interior_pixels
            if _color_luminance(color) <= 104 and _color_saturation(color) <= 96
        ]
        minimum_count = max(16, len(interior_pixels) // 5)
        if (
            len(high_luminance_pixels) >= minimum_count
            and len(high_luminance_pixels) >= len(low_luminance_pixels) * 1.25
        ):
            return _dominant_rgb_pixels(high_luminance_pixels)
    # OCR boxes are often almost completely occupied by dark glyphs. Sample the
    # surrounding ring here; using the box interior would mistake source ink for
    # a black bubble and prevent recovery of its larger white container.
    return _sample_region_fill_color(image, sample_bbox)


def _region_strip_pixels(
    rgb_image: Image.Image,
    bbox: tuple[int, int, int, int],
    direction: str,
    step: int,
) -> Any:
    x1, y1, x2, y2 = bbox
    if direction == "left":
        crop_box = (x1, y1, min(rgb_image.size[0], x1 + step), y2)
    elif direction == "right":
        crop_box = (max(0, x2 - step), y1, x2, y2)
    elif direction == "top":
        crop_box = (x1, y1, x2, min(rgb_image.size[1], y1 + step))
    else:
        crop_box = (x1, max(0, y2 - step), x2, y2)
    crop = rgb_image.crop(crop_box)
    if np is not None:
        return np.asarray(crop, dtype=np.uint8).reshape(-1, 3)
    return _image_pixels(crop)


def _bubble_fill_matches_array(
    pixels: Any,
    seed_color: tuple[int, int, int],
    fill_color: tuple[int, int, int],
) -> Any:
    values = np.asarray(pixels, dtype=np.int16).reshape(-1, 3)
    seed = np.asarray(seed_color, dtype=np.int16)
    fill = np.asarray(fill_color, dtype=np.int16)
    fill_luminance = _color_luminance(fill_color)
    seed_luminance = _color_luminance(seed_color)
    pixel_luminance = values[:, 0] * 0.299 + values[:, 1] * 0.587 + values[:, 2] * 0.114
    distance_from_fill = np.abs(values - fill).sum(axis=1)
    distance_from_seed = np.abs(values - seed).sum(axis=1)
    luminance_delta = np.abs(pixel_luminance - seed_luminance)
    saturation = values.max(axis=1) - values.min(axis=1)
    if fill_luminance >= 185:
        return (distance_from_seed <= 72) | (
            (distance_from_fill <= 112)
            & (pixel_luminance >= max(148.0, seed_luminance - 44.0))
            & (saturation <= 100)
        )
    if fill_luminance >= 135:
        return (distance_from_seed <= 62) | (
            (distance_from_fill <= 90) & (luminance_delta <= 48.0) & (saturation <= 112)
        )
    return (distance_from_seed <= 56) | ((distance_from_fill <= 78) & (luminance_delta <= 36.0))


def _external_ocr_fill_component_bbox_vectorized(
    image: Image.Image,
    text_bbox: tuple[int, int, int, int],
    fill_color: tuple[int, int, int],
    *,
    page_size: tuple[int, int] | None = None,
    bbox_offset: tuple[int, int] = (0, 0),
    page_text_bbox: tuple[int, int, int, int] | None = None,
) -> tuple[int, int, int, int] | None:
    blurred = image.convert("RGB").filter(ImageFilter.GaussianBlur(radius=1.2))
    pixels = np.asarray(blurred, dtype=np.uint8)
    matches = _bubble_fill_matches_array(pixels.reshape(-1, 3), fill_color, fill_color).reshape(
        pixels.shape[:2]
    )
    _, labels = cv2.connectedComponents(matches.astype(np.uint8), connectivity=4)
    x1, y1, x2, y2 = text_bbox
    local_labels = labels[y1:y2, x1:x2]
    positive_labels = local_labels[local_labels > 0]
    if positive_labels.size == 0:
        return None
    local_counts = np.bincount(positive_labels)
    component_label = int(np.argmax(local_counts))
    local_area = int(local_counts[component_label])
    component = labels == component_label
    component_area = int(np.count_nonzero(component))
    coordinates = np.argwhere(component)
    if coordinates.size == 0:
        return None
    top, left = coordinates.min(axis=0)
    bottom, right = coordinates.max(axis=0) + 1
    offset_x, offset_y = bbox_offset
    component_bbox = (
        int(left) + offset_x,
        int(top) + offset_y,
        int(right) + offset_x,
        int(bottom) + offset_y,
    )
    resolved_text_bbox = page_text_bbox or (
        text_bbox[0] + offset_x,
        text_bbox[1] + offset_y,
        text_bbox[2] + offset_x,
        text_bbox[3] + offset_y,
    )
    return _validate_external_ocr_fill_component(
        page_size or image.size,
        resolved_text_bbox,
        component_bbox,
        local_area=local_area,
        component_area=component_area,
    )


def _external_ocr_fill_component_bbox_python(
    image: Image.Image,
    text_bbox: tuple[int, int, int, int],
    fill_color: tuple[int, int, int],
    *,
    page_size: tuple[int, int] | None = None,
    bbox_offset: tuple[int, int] = (0, 0),
    page_text_bbox: tuple[int, int, int, int] | None = None,
) -> tuple[int, int, int, int] | None:
    blurred = image.convert("RGB").filter(ImageFilter.GaussianBlur(radius=1.2))
    pixels = blurred.load()
    width, height = blurred.size
    x1, y1, x2, y2 = text_bbox
    step = max(1, min(x2 - x1, y2 - y1) // 18)
    visited: set[tuple[int, int]] = set()
    best: tuple[int, int, tuple[int, int, int, int]] | None = None

    for seed_y in range(y1, y2, step):
        for seed_x in range(x1, x2, step):
            if (seed_x, seed_y) in visited:
                continue
            seed_color = tuple(int(channel) for channel in pixels[seed_x, seed_y])
            if not _pixel_matches_bubble_fill(seed_color, fill_color, fill_color):
                continue
            queue: deque[tuple[int, int]] = deque([(seed_x, seed_y)])
            component_area = 0
            local_area = 0
            left = right = seed_x
            top = bottom = seed_y
            while queue:
                current_x, current_y = queue.popleft()
                if (current_x, current_y) in visited:
                    continue
                visited.add((current_x, current_y))
                if current_x < 0 or current_x >= width or current_y < 0 or current_y >= height:
                    continue
                current_color = tuple(int(channel) for channel in pixels[current_x, current_y])
                if not _pixel_matches_bubble_fill(current_color, fill_color, fill_color):
                    continue
                component_area += 1
                if x1 <= current_x < x2 and y1 <= current_y < y2:
                    local_area += 1
                left = min(left, current_x)
                top = min(top, current_y)
                right = max(right, current_x)
                bottom = max(bottom, current_y)
                queue.extend(
                    (
                        (current_x - 1, current_y),
                        (current_x + 1, current_y),
                        (current_x, current_y - 1),
                        (current_x, current_y + 1),
                    )
                )
            candidate = (left, top, right + 1, bottom + 1)
            if best is None or (local_area, component_area) > (best[0], best[1]):
                best = local_area, component_area, candidate

    if best is None:
        return None
    offset_x, offset_y = bbox_offset
    component_bbox = (
        best[2][0] + offset_x,
        best[2][1] + offset_y,
        best[2][2] + offset_x,
        best[2][3] + offset_y,
    )
    resolved_text_bbox = page_text_bbox or (
        text_bbox[0] + offset_x,
        text_bbox[1] + offset_y,
        text_bbox[2] + offset_x,
        text_bbox[3] + offset_y,
    )
    return _validate_external_ocr_fill_component(
        page_size or image.size,
        resolved_text_bbox,
        component_bbox,
        local_area=best[0],
        component_area=best[1],
    )


def _validate_external_ocr_fill_component(
    image_size: tuple[int, int],
    text_bbox: tuple[int, int, int, int],
    component_bbox: tuple[int, int, int, int],
    *,
    local_area: int,
    component_area: int,
) -> tuple[int, int, int, int] | None:
    image_area = max(1, image_size[0] * image_size[1])
    text_area = max(1, _bbox_area(text_bbox))
    component_box_area = max(1, _bbox_area(component_bbox))
    if local_area < max(12, int(round(text_area * 0.08))):
        return None
    if component_area < max(48, int(round(text_area * 0.28))):
        return None
    if component_box_area < int(round(text_area * 1.12)):
        return None
    if component_area > image_area * 0.58 or component_box_area > image_area * 0.68:
        return None
    if component_bbox[2] - component_bbox[0] < text_bbox[2] - text_bbox[0]:
        return None
    if component_bbox[3] - component_bbox[1] < text_bbox[3] - text_bbox[1]:
        return None
    if (
        component_bbox[0] <= 1
        or component_bbox[1] <= 1
        or component_bbox[2] >= image_size[0] - 1
        or component_bbox[3] >= image_size[1] - 1
    ):
        return None
    return component_bbox


def _external_ocr_fill_component_bbox(
    image: Image.Image,
    text_bbox: tuple[int, int, int, int],
    fill_color: tuple[int, int, int],
) -> tuple[int, int, int, int] | None:
    text_width = max(1, text_bbox[2] - text_bbox[0])
    text_height = max(1, text_bbox[3] - text_bbox[1])
    search_padding = min(1024, max(96, int(round(max(text_width, text_height) * 2.0))))
    search_bbox = (
        max(0, text_bbox[0] - search_padding),
        max(0, text_bbox[1] - search_padding),
        min(image.size[0], text_bbox[2] + search_padding),
        min(image.size[1], text_bbox[3] + search_padding),
    )
    search_image = image.crop(search_bbox)
    local_text_bbox = (
        text_bbox[0] - search_bbox[0],
        text_bbox[1] - search_bbox[1],
        text_bbox[2] - search_bbox[0],
        text_bbox[3] - search_bbox[1],
    )
    component_builder = (
        _external_ocr_fill_component_bbox_vectorized
        if cv2 is not None and np is not None
        else _external_ocr_fill_component_bbox_python
    )
    component_bbox = component_builder(
        search_image,
        local_text_bbox,
        fill_color,
        page_size=image.size,
        bbox_offset=(search_bbox[0], search_bbox[1]),
        page_text_bbox=text_bbox,
    )
    if component_bbox is None:
        return None

    touches_search_edge = (
        (search_bbox[0] > 0 and component_bbox[0] <= search_bbox[0] + 1)
        or (search_bbox[1] > 0 and component_bbox[1] <= search_bbox[1] + 1)
        or (search_bbox[2] < image.size[0] and component_bbox[2] >= search_bbox[2] - 1)
        or (search_bbox[3] < image.size[1] and component_bbox[3] >= search_bbox[3] - 1)
    )
    if touches_search_edge:
        return component_builder(image, text_bbox, fill_color)
    return component_bbox


def _strip_matches_fill_color(
    pixels: Any,
    fill_color: tuple[int, int, int],
) -> bool:
    if len(pixels) == 0:
        return False
    if np is not None:
        return float(np.mean(_bubble_fill_matches_array(pixels, fill_color, fill_color))) >= 0.52
    matched = sum(1 for pixel in pixels if _pixel_matches_bubble_fill(pixel, fill_color, fill_color))
    return matched / len(pixels) >= 0.52


def _estimate_external_ocr_body_bbox(
    image: Image.Image,
    text_bbox: tuple[int, int, int, int],
    direction: str,
    line_count: int,
    fill_color: tuple[int, int, int] | None = None,
) -> tuple[int, int, int, int]:
    body_bbox = _expand_region_bbox(
        text_bbox,
        image.size,
        expand_x_ratio=0.14 if direction == "vertical" else 0.10,
        expand_y_ratio=0.10 if direction == "vertical" else 0.14,
        min_expand=4,
    )
    resolved_fill_color = fill_color or _estimate_external_ocr_fill_color(image, text_bbox, direction)
    rgb_image = image.convert("RGB")
    width_limit, height_limit = image.size
    text_width = max(1, text_bbox[2] - text_bbox[0])
    text_height = max(1, text_bbox[3] - text_bbox[1])
    capped_line_count = max(1, min(4, int(line_count)))
    max_width = max(
        text_width + 24,
        int(round(text_width * (1.8 + (0.18 if direction == "vertical" else 0.08) * capped_line_count))),
    )
    max_height = max(
        text_height + 24,
        int(round(text_height * (1.8 + (0.08 if direction == "vertical" else 0.18) * capped_line_count))),
    )
    step_x = max(3, min(10, (text_bbox[2] - text_bbox[0]) // 4))
    step_y = max(3, min(10, (text_bbox[3] - text_bbox[1]) // 4))

    for _ in range(10):
        expanded = False
        x1, y1, x2, y2 = body_bbox
        if x1 > 0:
            candidate = (max(0, x1 - step_x), y1, x2, y2)
            if candidate[2] - candidate[0] <= max_width and _strip_matches_fill_color(
                _region_strip_pixels(rgb_image, candidate, "left", step_x), resolved_fill_color
            ):
                body_bbox = candidate
                expanded = True
        x1, y1, x2, y2 = body_bbox
        if x2 < width_limit:
            candidate = (x1, y1, min(width_limit, x2 + step_x), y2)
            if candidate[2] - candidate[0] <= max_width and _strip_matches_fill_color(
                _region_strip_pixels(rgb_image, candidate, "right", step_x), resolved_fill_color
            ):
                body_bbox = candidate
                expanded = True
        x1, y1, x2, y2 = body_bbox
        if y1 > 0:
            candidate = (x1, max(0, y1 - step_y), x2, y2)
            if candidate[3] - candidate[1] <= max_height and _strip_matches_fill_color(
                _region_strip_pixels(rgb_image, candidate, "top", step_y), resolved_fill_color
            ):
                body_bbox = candidate
                expanded = True
        x1, y1, x2, y2 = body_bbox
        if y2 < height_limit:
            candidate = (x1, y1, x2, min(height_limit, y2 + step_y))
            if candidate[3] - candidate[1] <= max_height and _strip_matches_fill_color(
                _region_strip_pixels(rgb_image, candidate, "bottom", step_y), resolved_fill_color
            ):
                body_bbox = candidate
                expanded = True
        if not expanded:
            break

    return body_bbox


def _infer_external_ocr_shape(
    image: Image.Image,
    body_bbox: tuple[int, int, int, int],
    fill_color: tuple[int, int, int],
    direction: str,
) -> str:
    del direction

    crop = image.crop(body_bbox).convert("RGB")
    width, height = crop.size
    patch = max(3, min(width, height) // 6)
    if patch <= 2:
        return "roundrect"

    corner_boxes = [
        (0, 0, patch, patch),
        (width - patch, 0, width, patch),
        (0, height - patch, patch, height),
        (width - patch, height - patch, width, height),
    ]
    corner_pixels: list[Any] = []
    for left, top, right, bottom in corner_boxes:
        corner = crop.crop((left, top, right, bottom))
        if np is not None:
            corner_pixels.append(np.asarray(corner, dtype=np.uint8).reshape(-1, 3))
        else:
            corner_pixels.extend(_image_pixels(corner))
    if np is not None:
        pixels = np.concatenate(corner_pixels, axis=0)
        ratio = float(np.mean(_bubble_fill_matches_array(pixels, fill_color, fill_color)))
    else:
        matches = sum(
            1 for pixel in corner_pixels if _pixel_matches_bubble_fill(pixel, fill_color, fill_color)
        )
        ratio = matches / max(len(corner_pixels), 1)
    if ratio <= 0.28:
        return "ellipse"
    if ratio <= 0.62:
        return "roundrect"
    return "rect"


def _build_external_ocr_region(
    *,
    order: int,
    text: str,
    bbox: tuple[int, int, int, int],
    image: Image.Image,
    direction: str | None = None,
    line_count: int = 1,
) -> dict[str, Any]:
    resolved_direction = direction or _external_ocr_inferred_direction(bbox)
    fill_color = _estimate_external_ocr_fill_color(image, bbox, resolved_direction)
    inferred_container_bbox = _external_ocr_fill_component_bbox(image, bbox, fill_color)
    container_inferred = inferred_container_bbox is not None
    body_bbox = inferred_container_bbox or _estimate_external_ocr_body_bbox(
        image,
        bbox,
        resolved_direction,
        line_count,
        fill_color=fill_color,
    )
    shape = _infer_external_ocr_shape(image, body_bbox, fill_color, resolved_direction)
    if shape == "rect" and resolved_direction == "horizontal" and _color_luminance(fill_color) < 228:
        compact_body = _expand_region_bbox(
            bbox,
            image.size,
            expand_x_ratio=0.05,
            expand_y_ratio=0.12,
            min_expand=2,
        )
        body_bbox = _intersect_region_bboxes(compact_body, body_bbox) or compact_body

    safe_source = _expand_region_bbox(
        bbox,
        image.size,
        expand_x_ratio=0.06 if resolved_direction == "vertical" else 0.04,
        expand_y_ratio=0.05 if resolved_direction == "vertical" else 0.05,
        min_expand=2,
    )
    body_padding_x = max(
        2, min(16, (body_bbox[2] - body_bbox[0]) // (8 if resolved_direction == "vertical" else 11))
    )
    body_padding_y = max(
        2, min(16, (body_bbox[3] - body_bbox[1]) // (10 if resolved_direction == "vertical" else 9))
    )
    body_safe = _shrink_absolute_bbox(body_bbox, body_padding_x, body_padding_y) or body_bbox
    safe_box = (
        body_safe if container_inferred else _intersect_region_bboxes(safe_source, body_safe) or body_safe
    )
    padding_ratio = 0.80 if line_count > 1 else 0.84 if resolved_direction == "horizontal" else 0.82
    return {
        "order": order,
        "bbox": list(bbox),
        "body_bbox": list(body_bbox),
        "safe_box": list(_intersect_region_bboxes(safe_box, body_bbox) or safe_box),
        "source_text": text,
        "source_direction": resolved_direction,
        "direction": resolved_direction,
        "background": "#{:02X}{:02X}{:02X}".format(*fill_color),
        "shape": shape,
        "padding_ratio": padding_ratio,
        "_container_inferred": container_inferred,
    }


def _merge_external_ocr_regions_by_container(
    regions: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], int]:
    grouped: list[list[dict[str, Any]]] = []
    group_keys: list[tuple[Any, ...] | None] = []
    for region in regions:
        container_key = (
            tuple(region.get("body_bbox") or ()),
            str(region.get("source_direction") or region.get("direction") or ""),
            str(region.get("background") or ""),
            str(region.get("shape") or ""),
        )
        if not region.get("_container_inferred"):
            container_key = None
        try:
            group_index = group_keys.index(container_key) if container_key is not None else -1
        except ValueError:
            group_index = -1
        if group_index < 0:
            grouped.append([region])
            group_keys.append(container_key)
        else:
            grouped[group_index].append(region)

    merged_regions: list[dict[str, Any]] = []
    merged_count = 0
    for group in grouped:
        direction = str(group[0].get("direction") or "horizontal")
        ordered_group = sorted(
            group,
            key=(
                (lambda item: (item["bbox"][0], item["bbox"][1]))
                if direction == "vertical"
                else (lambda item: (item["bbox"][1], item["bbox"][0]))
            ),
            reverse=direction == "vertical",
        )
        merged = dict(ordered_group[0])
        merged_bbox = tuple(ordered_group[0]["bbox"])
        for item in ordered_group[1:]:
            merged_bbox = _union_region_bboxes(merged_bbox, tuple(item["bbox"]))
        merged["bbox"] = list(merged_bbox)
        merged["source_text"] = "\n".join(
            str(item.get("source_text") or "").strip()
            for item in ordered_group
            if str(item.get("source_text") or "").strip()
        )
        merged.pop("_container_inferred", None)
        merged_regions.append(merged)
        merged_count += max(0, len(group) - 1)

    for order, region in enumerate(merged_regions, start=1):
        region["order"] = order
    return merged_regions, merged_count


def _coerce_external_service_ocr_page_payload(
    raw_payload: dict[str, Any],
    *,
    image: Image.Image,
    image_size: tuple[int, int],
    page_number: int,
) -> MangaOcrPagePayload:
    result = raw_payload.get("result")
    if not isinstance(result, dict):
        raise ValueError("OCR 服务返回缺少 result")

    ocr_results = result.get("ocrResults")
    if not isinstance(ocr_results, list):
        raise ValueError("OCR 服务返回缺少 ocrResults 数组")

    raw_items: list[dict[str, Any]] = []
    raw_line_count = 0
    for ocr_result in ocr_results:
        if not isinstance(ocr_result, dict):
            continue
        pruned_result = ocr_result.get("prunedResult")
        if not isinstance(pruned_result, dict):
            continue
        rec_texts = pruned_result.get("rec_texts")
        rec_boxes = pruned_result.get("rec_boxes")
        if not isinstance(rec_texts, list) or not isinstance(rec_boxes, list):
            continue
        for text_value, raw_box in zip(rec_texts, rec_boxes, strict=False):
            text = str(text_value or "").strip()
            bbox = _normalize_region_bbox(raw_box, image_size)
            if not text or bbox is None:
                continue
            raw_line_count += 1
            raw_items.append(
                {
                    "bbox": bbox,
                    "text": text,
                    "direction": _external_ocr_inferred_direction(bbox),
                }
            )

    merged_items = _merge_external_ocr_lines(raw_items)
    regions: list[dict[str, Any]] = []
    for item in merged_items:
        regions.append(
            _build_external_ocr_region(
                order=len(regions) + 1,
                text=str(item["text"]),
                bbox=item["bbox"],
                image=image,
                direction=str(item["direction"] or "horizontal"),
                line_count=int(item.get("line_count") or 1),
            )
        )
    regions, container_merged_region_count = _merge_external_ocr_regions_by_container(regions)

    payload = _coerce_manga_ocr_page_payload(
        {"regions": regions},
        image_size=image_size,
        page_number=page_number,
    )
    diagnostics = dict(payload.diagnostics or {})
    diagnostics["ocr_backend"] = "external_service"
    diagnostics["raw_line_count"] = raw_line_count
    diagnostics["merged_line_count"] = len(merged_items)
    diagnostics["container_merged_region_count"] = container_merged_region_count
    return payload.model_copy(update={"diagnostics": diagnostics})


# ===== Windows 内置 OCR（Windows.Media.Ocr 公开 API，经 PowerShell 调用）=====
# 在“漫画 OCR”设置中启用并把接口地址填为 windows / win / local 等哨兵值即可使用本机 OCR，
# 无需外部 OCR 服务；接口密钥字段可选填语言优先级（逗号分隔，如 ja,zh-Hans,en）。
WINDOWS_OCR_SENTINELS = {"windows", "win", "winocr", "windows-ocr", "windowsocr", "local", "system"}
DEFAULT_WINDOWS_OCR_LANGUAGES = "ja,zh-Hans,zh-Hant,en,ko"


def _is_windows_ocr_base_url(value: Any) -> bool:
    text = str(value or "").strip().lower()
    if not text:
        return False
    if "://" in text:
        text = text.split("://", 1)[0]
    return text.rstrip("/") in WINDOWS_OCR_SENTINELS


def _windows_ocr_script_path() -> Path:
    import sys

    module_dir = Path(__file__).resolve().parent
    if getattr(sys, "frozen", False):
        base = Path(getattr(sys, "_MEIPASS", module_dir))
        bundled = base / "app" / "windows_ocr.ps1"
        if bundled.exists():
            return bundled
        flat = base / "windows_ocr.ps1"
        if flat.exists():
            return flat
    return module_dir / "windows_ocr.ps1"


def _resolve_powershell_executable() -> str:
    for name in ("powershell.exe", "pwsh.exe", "powershell", "pwsh"):
        located = shutil.which(name)
        if located:
            return located
    return "powershell"


def _resolve_windows_ocr_languages(settings: TranslationSettings) -> str:
    configured = str(getattr(settings.mangaOcr, "apiKey", "") or "").strip()
    return configured or DEFAULT_WINDOWS_OCR_LANGUAGES


def _run_windows_ocr_sync(image_path: Path, languages: str, timeout_seconds: int) -> dict[str, Any]:
    script_path = _windows_ocr_script_path()
    if not script_path.exists():
        raise RuntimeError(f"Windows OCR 脚本缺失：{script_path}")
    command = [
        _resolve_powershell_executable(),
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script_path),
        "-ImagePath",
        str(image_path),
        "-Languages",
        languages,
    ]
    completed = subprocess.run(
        command,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout_seconds,
    )
    stdout = (completed.stdout or "").strip()
    json_line = ""
    for line in reversed(stdout.splitlines()):
        stripped = line.strip()
        if stripped.startswith("{"):
            json_line = stripped
            break
    if not json_line:
        message = (completed.stderr or "").strip() or "Windows OCR 未返回结果"
        raise RuntimeError(f"Windows OCR 调用失败：{message}")
    payload = json.loads(json_line)
    if not isinstance(payload, dict) or not payload.get("ok"):
        detail = payload.get("error") if isinstance(payload, dict) else "未知错误"
        raise RuntimeError(f"Windows OCR 识别失败：{detail}")
    return payload


def _build_windows_ocr_page_payload(
    raw_payload: dict[str, Any],
    *,
    image: Image.Image,
    image_size: tuple[int, int],
    page_number: int,
) -> MangaOcrPagePayload:
    raw_lines = raw_payload.get("lines")
    raw_items: list[dict[str, Any]] = []
    raw_line_count = 0
    if isinstance(raw_lines, list):
        for entry in raw_lines:
            if not isinstance(entry, dict):
                continue
            text = str(entry.get("text") or "").strip()
            bbox = _normalize_region_bbox(entry.get("bbox"), image_size)
            if not text or bbox is None:
                continue
            raw_line_count += 1
            raw_items.append(
                {
                    "bbox": bbox,
                    "text": text,
                    "direction": _external_ocr_inferred_direction(bbox),
                }
            )

    merged_items = _merge_external_ocr_lines(raw_items)
    regions: list[dict[str, Any]] = []
    for item in merged_items:
        regions.append(
            _build_external_ocr_region(
                order=len(regions) + 1,
                text=str(item["text"]),
                bbox=item["bbox"],
                image=image,
                direction=str(item["direction"] or "horizontal"),
                line_count=int(item.get("line_count") or 1),
            )
        )
    regions, container_merged_region_count = _merge_external_ocr_regions_by_container(regions)

    payload = _coerce_manga_ocr_page_payload(
        {"regions": regions},
        image_size=image_size,
        page_number=page_number,
    )
    diagnostics = dict(payload.diagnostics or {})
    diagnostics["ocr_backend"] = "windows"
    diagnostics["ocr_engine_language"] = str(raw_payload.get("engineLang") or "")
    diagnostics["raw_line_count"] = raw_line_count
    diagnostics["merged_line_count"] = len(merged_items)
    diagnostics["container_merged_region_count"] = container_merged_region_count
    return payload.model_copy(update={"diagnostics": diagnostics})


def _rapid_ocr_quad_bbox(
    raw_box: Any,
    image_size: tuple[int, int],
) -> tuple[int, int, int, int] | None:
    if raw_box is None:
        return None
    points = list(raw_box)
    coordinates: list[tuple[float, float]] = []
    for point in points:
        try:
            x_value = float(point[0])
            y_value = float(point[1])
        except (IndexError, TypeError, ValueError):
            continue
        coordinates.append((x_value, y_value))
    if len(coordinates) < 2:
        return None
    return _normalize_region_bbox(
        (
            round(min(point[0] for point in coordinates)),
            round(min(point[1] for point in coordinates)),
            round(max(point[0] for point in coordinates)),
            round(max(point[1] for point in coordinates)),
        ),
        image_size,
    )


def _build_rapid_ocr_page_payload(
    result: Any,
    *,
    image: Image.Image,
    image_size: tuple[int, int],
    page_number: int,
) -> MangaOcrPagePayload:
    raw_boxes = getattr(result, "boxes", None)
    raw_texts = getattr(result, "txts", None)
    raw_scores = getattr(result, "scores", None)
    boxes = list(raw_boxes) if raw_boxes is not None else []
    texts = list(raw_texts) if raw_texts is not None else []
    scores = list(raw_scores) if raw_scores is not None else []
    raw_items: list[dict[str, Any]] = []
    accepted_scores: list[float] = []
    rejected_low_confidence_count = 0
    for index, raw_box in enumerate(boxes):
        text = str(texts[index] if index < len(texts) else "").strip()
        try:
            confidence = float(scores[index] if index < len(scores) else 0.0)
        except (TypeError, ValueError):
            confidence = 0.0
        bbox = _rapid_ocr_quad_bbox(raw_box, image_size)
        if not text or bbox is None:
            continue
        if confidence < 0.35:
            rejected_low_confidence_count += 1
            continue
        accepted_scores.append(confidence)
        raw_items.append(
            {
                "bbox": bbox,
                "text": text,
                "direction": _external_ocr_inferred_direction(bbox),
            }
        )

    merged_items = _merge_external_ocr_lines(raw_items)
    regions = [
        _build_external_ocr_region(
            order=index,
            text=str(item["text"]),
            bbox=item["bbox"],
            image=image,
            direction=str(item["direction"] or "horizontal"),
            line_count=int(item.get("line_count") or 1),
        )
        for index, item in enumerate(merged_items, start=1)
    ]
    regions, container_merged_region_count = _merge_external_ocr_regions_by_container(regions)
    payload = _coerce_manga_ocr_page_payload(
        {"regions": regions},
        image_size=image_size,
        page_number=page_number,
    )
    diagnostics = dict(payload.diagnostics or {})
    diagnostics.update(
        {
            "ocr_backend": "rapidocr",
            "raw_line_count": len(boxes),
            "accepted_line_count": len(raw_items),
            "merged_line_count": len(merged_items),
            "container_merged_region_count": container_merged_region_count,
            "rejected_low_confidence_count": rejected_low_confidence_count,
            "average_confidence": (
                round(sum(accepted_scores) / len(accepted_scores), 5) if accepted_scores else 0.0
            ),
        }
    )
    return payload.model_copy(update={"diagnostics": diagnostics})


def _run_rapid_ocr_sync(image_path: Path) -> Any:
    global _RAPID_OCR_ENGINE
    with _RAPID_OCR_LOCK:
        if _RAPID_OCR_ENGINE is None:
            try:
                rapidocr_module = importlib.import_module("rapidocr")
                rapid_ocr_class = rapidocr_module.RapidOCR
                _RAPID_OCR_ENGINE = rapid_ocr_class(
                    params={
                        "Global.log_level": "critical",
                        "Global.text_score": 0.35,
                        "Det.limit_side_len": RAPID_OCR_DETECTION_SIDE,
                        "Det.limit_type": "min",
                    }
                )
            except Exception as error:
                raise RuntimeError(f"RapidOCR 初始化失败：{error}") from error
        # Manga pages commonly contain vertical text but RapidOCR's classifier only
        # resolves 0/180-degree rotations. Skipping it preserves recognition quality
        # while avoiding an unnecessary inference pass for every detected line.
        return _RAPID_OCR_ENGINE(image_path, use_cls=False)


async def _request_rapid_ocr_regions_payload(
    *,
    image_path: Path,
    image_size: tuple[int, int],
    page_number: int,
    **_: Any,
) -> MangaOcrPagePayload:
    result = await asyncio.to_thread(_run_rapid_ocr_sync, image_path)
    with Image.open(image_path) as source_image:
        normalized_image = source_image.convert("RGB")
    return _build_rapid_ocr_page_payload(
        result,
        image=normalized_image,
        image_size=image_size,
        page_number=page_number,
    )


async def _request_windows_ocr_regions_payload(
    *,
    settings: TranslationSettings,
    image_path: Path,
    image_size: tuple[int, int],
    timeout_seconds: int,
    page_number: int,
) -> MangaOcrPagePayload:
    languages = _resolve_windows_ocr_languages(settings)
    raw_payload = await asyncio.to_thread(
        _run_windows_ocr_sync, image_path, languages, max(20, timeout_seconds)
    )
    with Image.open(image_path) as source_image:
        normalized_image = source_image.convert("RGB")
    return _build_windows_ocr_page_payload(
        raw_payload,
        image=normalized_image,
        image_size=image_size,
        page_number=page_number,
    )


def _merge_local_manga_ocr_payloads(
    rapid_payload: MangaOcrPagePayload,
    windows_payload: MangaOcrPagePayload,
) -> MangaOcrPagePayload:
    # RapidOCR is the primary local engine. Windows OCR is useful as supporting
    # evidence, but unmatched Windows-only fragments are frequently decorative
    # marks misread under the wrong system language and must not create regions.
    merged = _merge_hybrid_manga_ocr_payloads(
        windows_payload,
        rapid_payload,
        include_unmatched_model_regions=False,
    )
    diagnostics = dict(merged.diagnostics or {})
    rapid_diagnostics = dict(rapid_payload.diagnostics or {})
    windows_diagnostics = dict(windows_payload.diagnostics or {})
    diagnostics.update(
        {
            "ocr_backend": "local_rapidocr_windows",
            "rapidocr_region_count": len(rapid_payload.regions),
            "windows_region_count": len(windows_payload.regions),
            "local_merged_region_count": diagnostics.get("hybrid_merged_region_count", 0),
            "rapidocr_average_confidence": rapid_diagnostics.get("average_confidence", 0.0),
            "windows_ocr_engine_language": windows_diagnostics.get("ocr_engine_language", ""),
        }
    )
    diagnostics.pop("model_region_count", None)
    return merged.model_copy(update={"diagnostics": diagnostics})


async def _request_local_manga_ocr_regions_payload(
    *,
    settings: TranslationSettings,
    image_path: Path,
    image_size: tuple[int, int],
    timeout_seconds: int,
    page_number: int,
) -> MangaOcrPagePayload:
    if os.name != "nt":
        return await _request_rapid_ocr_regions_payload(
            image_path=image_path,
            image_size=image_size,
            page_number=page_number,
        )

    try:
        rapid_result: MangaOcrPagePayload | Exception = await _request_rapid_ocr_regions_payload(
            image_path=image_path,
            image_size=image_size,
            page_number=page_number,
        )
    except Exception as error:
        rapid_result = error

    if isinstance(rapid_result, MangaOcrPagePayload) and rapid_result.regions:
        rapid_diagnostics = dict(rapid_result.diagnostics or {})
        average_confidence = float(rapid_diagnostics.get("average_confidence") or 0.0)
        if average_confidence >= 0.72:
            rapid_diagnostics["windows_ocr_skipped"] = "rapidocr_high_confidence"
            return rapid_result.model_copy(update={"diagnostics": rapid_diagnostics})

    try:
        windows_result: MangaOcrPagePayload | Exception = await _request_windows_ocr_regions_payload(
            settings=settings,
            image_path=image_path,
            image_size=image_size,
            timeout_seconds=timeout_seconds,
            page_number=page_number,
        )
    except Exception as error:
        windows_result = error
    rapid_payload = rapid_result if isinstance(rapid_result, MangaOcrPagePayload) else None
    windows_payload = windows_result if isinstance(windows_result, MangaOcrPagePayload) else None
    if rapid_payload is not None and windows_payload is not None:
        return _merge_local_manga_ocr_payloads(rapid_payload, windows_payload)
    if rapid_payload is not None:
        diagnostics = dict(rapid_payload.diagnostics or {})
        diagnostics["windows_ocr_fallback_error"] = str(windows_result)
        return rapid_payload.model_copy(update={"diagnostics": diagnostics})
    if windows_payload is not None:
        diagnostics = dict(windows_payload.diagnostics or {})
        diagnostics["rapidocr_fallback_error"] = str(rapid_result)
        return windows_payload.model_copy(update={"diagnostics": diagnostics})
    raise RuntimeError(f"本地漫画 OCR 失败：RapidOCR={rapid_result}；Windows OCR={windows_result}")


async def _request_openai_vision_ocr_regions_payload(
    *,
    base_url: str,
    api_key: str,
    model: str,
    image_path: Path,
    image_size: tuple[int, int],
    timeout_seconds: int,
    page_number: int,
) -> MangaOcrPagePayload:
    image_bytes = image_path.read_bytes()
    image_b64 = base64.b64encode(image_bytes).decode("ascii")
    with Image.open(image_path) as source_image:
        evidence_image = source_image.convert("RGB")
    prompt = _build_manga_ocr_prompt(image_size=image_size)
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    payload = {
        "model": model,
        "temperature": 0,
        "max_tokens": 5000,
        "messages": [
            {
                "role": "system",
                "content": "You are a precise manga OCR assistant. Output valid JSON only.",
            },
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": (
                                f"data:{mimetypes.guess_type(image_path.name)[0] or 'image/png'};"
                                f"base64,{image_b64}"
                            ),
                            "detail": "high",
                        },
                    },
                ],
            },
        ],
    }
    result: MangaOcrPagePayload | None = None
    attempt_count = 0
    async with _create_model_http_client(timeout=float(timeout_seconds)) as client:
        for attempt_count in range(1, 3):
            request_payload = json.loads(json.dumps(payload))
            if attempt_count > 1:
                request_payload["messages"][1]["content"][0]["text"] = (
                    f"{prompt} A previous inspection returned no regions. Re-scan every panel carefully, "
                    "including small, vertical, outlined, and low-contrast text."
                )
            content = await _post_translation_completion_text(
                client,
                f"{base_url}/chat/completions",
                headers=headers,
                payload=request_payload,
                feature_name="视觉 OCR 模型",
                expects_json=True,
            )
            raw_payload = _extract_json_object_from_text(content)
            result = _coerce_manga_ocr_page_payload(
                raw_payload,
                image_size=image_size,
                page_number=page_number,
            )
            result = _filter_manga_ocr_regions_by_image_evidence(result, evidence_image)
            if result.regions:
                break

    if result is None:
        raise ValueError("视觉 OCR 模型未返回可解析结果")
    diagnostics = dict(result.diagnostics or {})
    diagnostics["ocr_backend"] = "openai_vision"
    diagnostics["ocr_model"] = model
    diagnostics["vision_attempt_count"] = attempt_count
    return result.model_copy(update={"diagnostics": diagnostics})


async def _request_manga_ocr_regions_payload(
    *,
    settings: TranslationSettings,
    base_url: str,
    api_key: str,
    model: str,
    image_path: Path,
    timeout_seconds: int,
    page_number: int = 0,
) -> MangaOcrPagePayload:
    with Image.open(image_path) as image:
        image_size = image.size
    use_builtin_local = (
        not settings.mangaOcr.enabled
        or not str(settings.mangaOcr.baseUrl or "").strip()
        or _is_windows_ocr_base_url(settings.mangaOcr.baseUrl)
    )
    if use_builtin_local:
        if not settings.translationModel.supportsVision:
            return await _request_local_manga_ocr_regions_payload(
                settings=settings,
                image_path=image_path,
                image_size=image_size,
                timeout_seconds=timeout_seconds,
                page_number=page_number,
            )

        local_result, model_result = await asyncio.gather(
            _request_local_manga_ocr_regions_payload(
                settings=settings,
                image_path=image_path,
                image_size=image_size,
                timeout_seconds=timeout_seconds,
                page_number=page_number,
            ),
            _request_openai_vision_ocr_regions_payload(
                base_url=base_url,
                api_key=api_key,
                model=model,
                image_path=image_path,
                image_size=image_size,
                timeout_seconds=timeout_seconds,
                page_number=page_number,
            ),
            return_exceptions=True,
        )
        local_payload = local_result if isinstance(local_result, MangaOcrPagePayload) else None
        model_payload = model_result if isinstance(model_result, MangaOcrPagePayload) else None
        if local_payload is not None and model_payload is not None:
            needs_confirmation = any(
                not any(
                    _hybrid_region_match_score(model_region, local_region) > 0
                    and _manga_ocr_text_agrees(
                        model_region.source_text,
                        local_region.source_text,
                    )
                    for local_region in local_payload.regions
                )
                for model_region in model_payload.regions
            )
            if needs_confirmation:
                try:
                    verification_payload = await _request_openai_vision_ocr_regions_payload(
                        base_url=base_url,
                        api_key=api_key,
                        model=model,
                        image_path=image_path,
                        image_size=image_size,
                        timeout_seconds=timeout_seconds,
                        page_number=page_number,
                    )
                except Exception as error:
                    diagnostics = dict(model_payload.diagnostics or {})
                    diagnostics["vision_confirmation_error"] = str(error)
                    model_payload = model_payload.model_copy(update={"diagnostics": diagnostics})
                else:
                    model_payload = _confirm_hybrid_model_regions(
                        model_payload,
                        verification_payload,
                        local_payload,
                    )
            merged = _merge_hybrid_manga_ocr_payloads(model_payload, local_payload)
            diagnostics = dict(merged.diagnostics or {})
            diagnostics.update(
                {
                    "ocr_backend": "hybrid_local_openai",
                    "vision_region_count": len(model_payload.regions),
                    "local_region_count": len(local_payload.regions),
                }
            )
            diagnostics.pop("model_region_count", None)
            return merged.model_copy(update={"diagnostics": diagnostics})
        if model_payload is not None:
            diagnostics = dict(model_payload.diagnostics or {})
            diagnostics["local_ocr_fallback_error"] = str(local_result)
            return model_payload.model_copy(update={"diagnostics": diagnostics})
        if local_payload is not None:
            diagnostics = dict(local_payload.diagnostics or {})
            diagnostics["vision_ocr_fallback_error"] = str(model_result)
            return local_payload.model_copy(update={"diagnostics": diagnostics})
        raise RuntimeError(f"漫画 OCR 失败：本地 OCR={local_result}；OpenAI 视觉 OCR={model_result}")
    if settings.mangaOcr.enabled:
        ocr_base_url, ocr_api_key = _resolve_manga_ocr_config(
            settings,
            fallback_base_url=base_url,
            fallback_api_key=api_key,
        )
        image_bytes = image_path.read_bytes()
        request_payload: dict[str, Any] = {
            "file": base64.b64encode(image_bytes).decode("ascii"),
            "fileType": 1,
            "returnWordBox": True,
        }
        headers = {"Content-Type": "application/json"}
        if ocr_api_key:
            headers["Authorization"] = f"Bearer {ocr_api_key}"
        async with _create_model_http_client(timeout=float(timeout_seconds)) as client:
            response_payload = await _post_translation_json(
                client,
                f"{ocr_base_url}/ocr",
                headers=headers,
                payload=request_payload,
            )
        with Image.open(image_path) as source_image:
            normalized_image = source_image.convert("RGB")
        return _coerce_external_service_ocr_page_payload(
            response_payload,
            image=normalized_image,
            image_size=image_size,
            page_number=page_number,
        )

    return await _request_local_manga_ocr_regions_payload(
        settings=settings,
        image_path=image_path,
        image_size=image_size,
        timeout_seconds=timeout_seconds,
        page_number=page_number,
    )


def _build_manga_region_translation_prompt(
    *,
    target_language: str,
    chapter_title: str,
    chapter_index: int,
    page_number: int,
    total_pages: int,
    regions: list[MangaOcrRegion],
) -> str:
    source_items = [
        {
            "order": region.order,
            "source_text": region.source_text,
            "source_direction": region.source_direction,
            "direction": region.direction,
            "box_size": [
                max(
                    8,
                    (region.safe_box or region.body_bbox or region.bbox or (0, 0, 8, 8))[2]
                    - (region.safe_box or region.body_bbox or region.bbox or (0, 0, 8, 8))[0],
                ),
                max(
                    8,
                    (region.safe_box or region.body_bbox or region.bbox or (0, 0, 8, 8))[3]
                    - (region.safe_box or region.body_bbox or region.bbox or (0, 0, 8, 8))[1],
                ),
            ],
            "max_chars_hint": _estimate_manga_region_char_budget(region),
        }
        for region in regions
    ]
    return (
        "You are a manga text translator. "
        f"Translate each source_text into {target_language}. "
        "Return JSON only. Do not output markdown or explanations. "
        'JSON schema: {"translations":[{"order":1,"translation":"..."}]}. '
        "Return exactly one translation item for each input item and keep the same reading order. "
        "Use Unicode quotation marks such as ‘ ’ or “ ” inside translations; never place "
        "unescaped ASCII double quotes inside JSON strings. "
        "Translate only the text itself. Do not add notes, speaker labels, or explanations. "
        "Prefer concise, bubble-safe translations. "
        "Translate short utterances, interjections, sentence particles, and sound effects too "
        "(for example Japanese ‘ね’, ‘ねー’, ‘はぁ’, or ‘えっ’); never leave kana "
        "unchanged when the target language is different. Pure punctuation or decorative "
        "symbols may be kept unchanged. "
        "Each item includes box_size and max_chars_hint; when wording would likely overflow, compress it while keeping the original meaning, tone, and emphasis. "
        "For narrow or vertical bubbles, prefer shorter phrasing and avoid unnecessary punctuation. "
        "Keep names, tone, emphasis, and line intent natural for manga dialogue/captions. "
        f"Context: chapter_title={chapter_title}, chapter_index={chapter_index}, page={page_number}/{total_pages}. "
        f"Input regions: {json.dumps(source_items, ensure_ascii=False)}"
    )


def _build_manga_region_translation_repair_prompt(
    *,
    target_language: str,
    chapter_title: str,
    chapter_index: int,
    page_number: int,
    total_pages: int,
    regions: list[MangaTranslatedRegion],
) -> str:
    repair_items = [
        {
            "order": region.order,
            "source_text": region.source_text,
            "previous_translation": region.translation,
            "direction": region.direction or region.source_direction,
            "max_chars_hint": _estimate_manga_region_char_budget(region),
        }
        for region in regions
    ]
    return (
        "Repair only the unresolved manga translations below. "
        f"Translate every source_text into {target_language} and return JSON only. "
        'JSON schema: {"translations":[{"order":1,"translation":"..."}]}. '
        "Keep each original order and return exactly one item for every input item. "
        "The previous translation copied Japanese kana and is not acceptable. "
        "Translate short utterances and sound effects too. If an item is cropped signage, "
        "a partial sound effect, or an incomplete visible fragment, give the closest concise "
        "Chinese equivalent or readable Chinese approximation without inventing hidden text. "
        "Never copy the Japanese kana unchanged. Do not add notes or explanations. "
        f"Context: chapter_title={chapter_title}, chapter_index={chapter_index}, "
        f"page={page_number}/{total_pages}. "
        f"Unresolved regions: {json.dumps(repair_items, ensure_ascii=False)}"
    )


def _coerce_manga_translated_regions(
    raw_payload: dict[str, Any],
    regions: list[MangaOcrRegion],
    *,
    target_language: str = "",
    allow_untranslated_japanese: bool = False,
) -> list[MangaTranslatedRegion]:
    translations_value = raw_payload.get("translations")
    if not isinstance(translations_value, list):
        raise ValueError("漫画文本翻译模型返回缺少 translations 数组")

    expected_by_order: dict[int, MangaOcrRegion] = {}
    for region in regions:
        if region.order in expected_by_order:
            raise ValueError(f"漫画 OCR 区域包含重复 order：{region.order}")
        expected_by_order[region.order] = region

    translations_by_order: dict[int, str] = {}
    for item in translations_value:
        if not isinstance(item, dict):
            raise ValueError("漫画文本翻译模型的 translations 每项必须是包含 order 的对象")
        try:
            order = int(item["order"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError("漫画文本翻译模型返回了缺失或无效的 order") from exc
        if order not in expected_by_order:
            raise ValueError(f"漫画文本翻译模型返回了未知 order：{order}")
        if order in translations_by_order:
            raise ValueError(f"漫画文本翻译模型返回了重复 order：{order}")

        raw_translation = item.get("translation") if "translation" in item else item.get("text")
        if raw_translation is not None and not isinstance(raw_translation, str):
            raise ValueError(f"漫画文本翻译模型的 order={order} 译文必须是字符串")
        translation = _normalize_manga_region_translation_text(raw_translation)
        source_text = str(expected_by_order[order].source_text or "").strip()
        source_has_linguistic_content = any(char.isalnum() for char in source_text)
        if not translation and source_has_linguistic_content:
            raise ValueError(f"漫画文本翻译模型遗漏了 order={order} 的译文")
        if (
            _manga_region_translation_needs_repair(
                source_text,
                translation,
                target_language,
            )
            and not allow_untranslated_japanese
        ):
            raise ValueError(f"漫画文本翻译模型未翻译 order={order} 的日文短句")
        translations_by_order[order] = translation

    missing_orders = set(expected_by_order) - set(translations_by_order)
    if missing_orders:
        missing_text = ", ".join(str(order) for order in sorted(missing_orders))
        raise ValueError(f"漫画文本翻译模型缺少 order：{missing_text}")

    translated_regions: list[MangaTranslatedRegion] = []
    for region in regions:
        region_data = region.model_dump()
        region_data["translation"] = translations_by_order[region.order]
        translated_regions.append(MangaTranslatedRegion.model_validate(region_data))
    return translated_regions


def _build_manga_page_translation_diagnostics(
    ocr_payload: MangaOcrPagePayload,
    translated_regions: list[MangaTranslatedRegion],
    *,
    target_language: str,
) -> dict[str, Any]:
    non_empty_translation_count = sum(
        1 for region in translated_regions if str(region.translation or "").strip()
    )
    unchanged_translation_count = sum(
        1
        for region in translated_regions
        if str(region.translation or "").strip()
        and str(region.translation or "").strip() == str(region.source_text or "").strip()
    )
    vertical_region_count = sum(
        1
        for region in translated_regions
        if str(region.direction or region.source_direction or "") == "vertical"
    )
    safe_box_region_count = sum(1 for region in translated_regions if region.safe_box is not None)
    over_budget_translation_count = sum(
        1
        for region in translated_regions
        if _manga_translation_char_count(region.translation) > _estimate_manga_region_char_budget(region)
    )
    unresolved_translation_orders = [
        region.order
        for region in translated_regions
        if _manga_region_translation_needs_repair(
            region.source_text,
            region.translation,
            target_language,
        )
    ]
    return {
        **dict(ocr_payload.diagnostics or {}),
        "region_count": len(translated_regions),
        "non_empty_translation_count": non_empty_translation_count,
        "empty_translation_count": max(0, len(translated_regions) - non_empty_translation_count),
        "unchanged_translation_count": unchanged_translation_count,
        "unresolved_translation_region_count": len(unresolved_translation_orders),
        "unresolved_translation_orders": unresolved_translation_orders,
        "vertical_region_count": vertical_region_count,
        "safe_box_region_count": safe_box_region_count,
        "over_budget_translation_count": over_budget_translation_count,
        "source_char_total": sum(len(str(region.source_text or "").strip()) for region in translated_regions),
        "translation_char_total": sum(
            len(str(region.translation or "").strip()) for region in translated_regions
        ),
    }


async def _translate_manga_region_batch(
    *,
    settings: TranslationSettings,
    base_url: str,
    api_key: str,
    model: str,
    target_language: str,
    chapter_title: str,
    chapter_index: int,
    page_number: int,
    total_pages: int,
    regions: list[MangaOcrRegion],
    timeout_seconds: int,
) -> list[MangaTranslatedRegion]:
    if not regions:
        return []

    resolved_target_language = _resolve_translation_target_language(target_language)
    prompt = _build_manga_region_translation_prompt(
        target_language=resolved_target_language,
        chapter_title=chapter_title,
        chapter_index=chapter_index,
        page_number=page_number,
        total_pages=total_pages,
        regions=regions,
    )
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    payload = {
        "model": model,
        "temperature": 0.2,
        "max_tokens": 3000,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are a precise manga translator. Translate text only and output valid JSON only."
                ),
            },
            {
                "role": "user",
                "content": prompt,
            },
        ],
    }
    translated_regions: list[MangaTranslatedRegion] | None = None
    async with _create_model_http_client(timeout=float(timeout_seconds)) as client:
        for attempt in range(2):
            content = await _post_translation_completion_text(
                client,
                f"{base_url}/chat/completions",
                headers=headers,
                payload=payload,
                feature_name="漫画文本翻译模型",
                expects_json=True,
            )
            parsed_json = False
            try:
                raw_payload = _extract_json_object_from_text(content)
                parsed_json = True
                translated_regions = _coerce_manga_translated_regions(
                    raw_payload,
                    regions,
                    target_language=resolved_target_language,
                    allow_untranslated_japanese=True,
                )
                break
            except ValueError as exc:
                if attempt > 0:
                    if not parsed_json:
                        raise ValueError("漫画文本翻译模型连续两次返回了无效 JSON") from exc
                    raise ValueError(f"漫画文本翻译模型连续两次返回了不完整或无效译文：{exc}") from exc
                payload = json.loads(json.dumps(payload))
                payload["temperature"] = 0
                payload["messages"][0]["content"] += (
                    " A previous response contained invalid JSON or incomplete translations. "
                    "Return one strictly valid JSON object with exactly one translation for every input order."
                )
                payload["messages"][1]["content"] += (
                    "\nThe previous response contained invalid JSON or incomplete/invalid translations. "
                    f"Retry from the source items and return exactly {len(regions)} translation items for "
                    f"orders {[region.order for region in regions]}. Do not omit, duplicate, or invent orders. "
                    "Every source item containing text must have a non-empty translated value; translate short "
                    "utterances and kana too. Return strictly valid JSON with correctly escaped string values."
                )
        for repair_attempt in range(2):
            if translated_regions is None:
                break
            unresolved_regions = [
                region
                for region in translated_regions
                if _manga_region_translation_needs_repair(
                    region.source_text,
                    region.translation,
                    resolved_target_language,
                )
            ]
            if not unresolved_regions:
                break
            repair_payload = {
                "model": model,
                "temperature": 0,
                "max_tokens": min(2000, max(500, len(unresolved_regions) * 180)),
                "messages": [
                    {
                        "role": "system",
                        "content": (
                            "You repair unresolved manga translations one region at a time. "
                            "Output valid JSON only."
                        ),
                    },
                    {
                        "role": "user",
                        "content": _build_manga_region_translation_repair_prompt(
                            target_language=resolved_target_language,
                            chapter_title=chapter_title,
                            chapter_index=chapter_index,
                            page_number=page_number,
                            total_pages=total_pages,
                            regions=unresolved_regions,
                        )
                        + f"\nTargeted repair attempt {repair_attempt + 1} of 2.",
                    },
                ],
            }
            try:
                repair_content = await _post_translation_completion_text(
                    client,
                    f"{base_url}/chat/completions",
                    headers=headers,
                    payload=repair_payload,
                    feature_name="漫画文本区域修复模型",
                    expects_json=True,
                )
                repair_raw_payload = _extract_json_object_from_text(repair_content)
                unresolved_by_order = {region.order: region for region in unresolved_regions}
                repair_source_regions = [region for region in regions if region.order in unresolved_by_order]
                repaired_regions = _coerce_manga_translated_regions(
                    repair_raw_payload,
                    repair_source_regions,
                    target_language=resolved_target_language,
                    allow_untranslated_japanese=True,
                )
            except Exception:
                # Match manga-translator-ui's region-level recovery: a single
                # stubborn fragment must not discard the rest of a valid page.
                continue
            repaired_by_order = {region.order: region for region in repaired_regions}
            translated_regions = [
                repaired_by_order.get(region.order, region) for region in translated_regions
            ]
    if translated_regions is None:
        raise ValueError("漫画文本翻译模型未返回可解析结果")
    compaction_prompt = _build_manga_translation_compaction_prompt(
        target_language=resolved_target_language,
        source_regions=regions,
        translated_regions=translated_regions,
    )
    if not compaction_prompt:
        return translated_regions

    translated_by_order = {region.order: region for region in translated_regions}
    compact_source_regions = [
        region
        for region in regions
        if (translated_region := translated_by_order.get(region.order)) is not None
        and _manga_translation_char_count(translated_region.translation)
        > _estimate_manga_region_char_budget(region)
    ]
    compact_payload = {
        "model": model,
        "temperature": 0,
        "max_tokens": 2000,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are a precise manga dialogue editor. Output valid JSON only and obey "
                    "every per-item character limit."
                ),
            },
            {"role": "user", "content": compaction_prompt},
        ],
    }
    try:
        async with _create_model_http_client(timeout=float(timeout_seconds)) as client:
            compact_content = await _post_translation_completion_text(
                client,
                f"{base_url}/chat/completions",
                headers=headers,
                payload=compact_payload,
                feature_name="漫画气泡译文压缩模型",
                expects_json=True,
            )
        compact_raw_payload = _extract_json_object_from_text(compact_content)
        compact_regions = _coerce_manga_translated_regions(
            compact_raw_payload,
            compact_source_regions,
            target_language=resolved_target_language,
        )
    except Exception:
        return translated_regions

    compact_by_order = {
        region.order: region.translation
        for region in compact_regions
        if str(region.translation or "").strip()
    }
    resolved_regions: list[MangaTranslatedRegion] = []
    for region in translated_regions:
        compact_translation = compact_by_order.get(region.order)
        if compact_translation and _manga_translation_char_count(
            compact_translation
        ) < _manga_translation_char_count(region.translation):
            resolved_regions.append(region.model_copy(update={"translation": compact_translation}))
        else:
            resolved_regions.append(region)
    return resolved_regions


async def _build_translated_manga_page_payload(
    *,
    settings: TranslationSettings,
    base_url: str,
    api_key: str,
    model: str,
    image_path: Path,
    target_language: str,
    timeout_seconds: int,
    chapter_title: str = "",
    chapter_index: int = 0,
    page_number: int = 0,
    total_pages: int = 0,
    source_image_file: str | None = None,
    translated_image_file: str | None = None,
) -> MangaTranslatedPagePayload:
    ocr_payload = await _request_manga_ocr_regions_payload(
        settings=settings,
        base_url=base_url,
        api_key=api_key,
        model=model,
        image_path=image_path,
        timeout_seconds=timeout_seconds,
        page_number=page_number,
    )
    translated_regions = await _translate_manga_region_batch(
        settings=settings,
        base_url=base_url,
        api_key=api_key,
        model=model,
        target_language=target_language,
        chapter_title=chapter_title,
        chapter_index=chapter_index,
        page_number=page_number,
        total_pages=total_pages,
        regions=ocr_payload.regions,
        timeout_seconds=timeout_seconds,
    )
    diagnostics = _build_manga_page_translation_diagnostics(
        ocr_payload,
        translated_regions,
        target_language=target_language,
    )
    diagnostics["translation_model"] = model
    diagnostics["ocr_api_base"] = (
        str(settings.mangaOcr.baseUrl or "").strip().rstrip("/")
        if _has_custom_manga_ocr_config(settings)
        else "local"
    )
    diagnostics["vision_model_enabled"] = settings.translationModel.supportsVision
    diagnostics.setdefault(
        "ocr_backend",
        str((ocr_payload.diagnostics or {}).get("ocr_backend") or "local_rapidocr_windows"),
    )
    page_translation = (
        "\n".join(
            region.translation.strip() for region in translated_regions if region.translation.strip()
        ).strip()
        or "【本页未识别到可翻译文字】"
    )
    return MangaTranslatedPagePayload(
        page_number=page_number,
        image_size=ocr_payload.image_size,
        target_language=_resolve_translation_target_language(target_language),
        render_mode="ocr_pipeline",
        source_image_file=source_image_file,
        translated_image_file=translated_image_file,
        page_translation=page_translation,
        regions=translated_regions,
        diagnostics=diagnostics,
    )


def _manga_render_text_key(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", str(value or "")).casefold()
    return "".join(char for char in normalized if char.isalnum())


def _manga_translation_is_effectively_unchanged(source_text: str, translation: str) -> bool:
    source_key = _manga_render_text_key(source_text)
    translation_key = _manga_render_text_key(translation)
    return bool(source_key and source_key == translation_key)


def _manga_region_translation_needs_repair(
    source_text: str,
    translation: str,
    target_language: str,
) -> bool:
    return bool(
        str(translation or "").strip()
        and str(target_language or "").strip().casefold()
        in {"中文", "chinese", "zh", "zh-cn", "zh-hans", "简体中文", "繁体中文"}
        and re.search(r"[\u3040-\u30ff\u31f0-\u31ff]", str(source_text or ""))
        and _manga_translation_is_effectively_unchanged(source_text, translation)
    )


def _sanitize_manga_render_translation(value: str) -> str:
    return re.sub(r"[♪♫♬♩]+", "", str(value or "")).strip()


def _manga_region_is_likely_nonlinguistic(
    source_text: str,
    bbox: tuple[int, int, int, int],
) -> bool:
    normalized = re.sub(r"\s+", "", str(source_text or ""))
    width = max(1, bbox[2] - bbox[0])
    height = max(1, bbox[3] - bbox[1])
    if not normalized or max(width, height) < 64:
        return False
    if len(normalized) == 1:
        # A single hiragana inside a speech bubble is commonly a short
        # utterance or sentence particle (for example ね).  It must remain
        # renderable when the model supplied a translation.  Keep the guard
        # for isolated katakana/kanji artwork glyphs and punctuation.
        return re.fullmatch(r"[\u3040-\u309f]", normalized) is None
    return len(normalized) <= 2 and not any(char.isalnum() for char in normalized)


def _mask_coverage_ratio(mask: Image.Image) -> float:
    pixels = _image_pixels(mask.convert("L"))
    return sum(1 for value in pixels if value > 0) / max(1, len(pixels))


def _manga_ink_mask_is_unsafe(mask: Image.Image) -> bool:
    # Tight OCR boxes around bold glyphs can legitimately reach roughly 55%
    # coverage (notably DejaVu Sans on Ubuntu). Reserve the safety stop for
    # masks that are genuinely close to an opaque artwork-sized block.
    return _mask_coverage_ratio(mask) >= 0.72


def _render_translated_manga_page_to_image(
    image_path: Path,
    page_payload: MangaTranslatedPagePayload,
) -> tuple[bytes, str, dict[str, Any]]:
    with Image.open(image_path) as source_image:
        canvas = source_image.convert("RGBA")

    rendered_translations: list[str] = []
    rendered_region_count = 0
    skipped_empty_region_count = 0
    skipped_bbox_region_count = 0
    skipped_unchanged_region_count = 0
    skipped_nonlinguistic_region_count = 0
    skipped_unsafe_cleanup_region_count = 0
    rendered_vertical_count = 0
    rendered_horizontal_count = 0
    layout_retry_count = 0
    overflow_region_count = 0
    skipped_overflow_region_count = 0
    compressed_overflow_region_count = 0
    mask_layout_retry_count = 0
    max_overflow = 0.0
    max_masked_outside_pixels = 0
    min_overflow_scale = 1.0
    style_estimated_region_count = 0
    source_text_erased_region_count = 0
    solid_cleanup_region_count = 0
    inpaint_cleanup_region_count = 0
    tight_bbox_cleanup_fallback_region_count = 0
    source_font_size_total = 0

    for region in page_payload.regions:
        bbox = _normalize_region_bbox(region.bbox, canvas.size) if region.bbox is not None else None
        translation = str(region.translation or "").strip()
        if bbox is None:
            skipped_bbox_region_count += 1
            continue
        if not translation:
            skipped_empty_region_count += 1
            continue
        if _manga_translation_is_effectively_unchanged(region.source_text, translation):
            skipped_unchanged_region_count += 1
            continue
        if _manga_region_is_likely_nonlinguistic(region.source_text, bbox):
            skipped_nonlinguistic_region_count += 1
            continue
        translation = _sanitize_manga_render_translation(translation)
        if not translation:
            skipped_empty_region_count += 1
            continue

        region_payload = region.model_dump(exclude_none=True)
        body_bbox = _normalize_region_bbox(region.body_bbox or bbox, canvas.size)
        if body_bbox is None:
            skipped_bbox_region_count += 1
            continue
        fill_color = _sample_region_fill_color(
            canvas,
            body_bbox,
            region.background,
            body_bbox=body_bbox,
        )
        x1, y1, x2, y2 = body_bbox
        preferred_direction = region.direction
        source_direction = region.source_direction
        direction_hint = preferred_direction or source_direction
        style = _estimate_manga_text_style(
            canvas,
            bbox,
            fill_color,
            preferred_color=region.text_color,
            direction=str(source_direction or direction_hint or "horizontal"),
        )
        style_estimated_region_count += 1
        source_font_size_total += style.font_size
        if _manga_ink_mask_is_unsafe(style.ink_mask):
            # A mask covering most of its rectangle is not a credible glyph mask;
            # it usually means textured artwork was mistaken for a flat background.
            # Editing such a region creates an opaque block, so preserve the source
            # image instead of performing destructive cleanup.
            skipped_unsafe_cleanup_region_count += 1
            continue
        initial_layout = _fit_text_layout_to_box(
            translation,
            (max(8, x2 - x1), max(8, y2 - y1)),
            direction_hint,
            preferred_font_size=style.font_size,
            bold=style.bold,
        )
        resolved_direction = str(initial_layout.get("direction") or "horizontal")
        fill_shape = _resolve_region_fill_shape(region_payload, body_bbox, resolved_direction)
        bubble_outline_mask = _extract_precise_bubble_mask(canvas, body_bbox, fill_color, fill_shape)
        bubble_fill_mask = _build_region_fill_area_mask(bubble_outline_mask, fill_shape, resolved_direction)
        cleanup_limit_mask, used_tight_bbox_cleanup_fallback = _resolve_manga_cleanup_limit_mask(
            bbox,
            body_bbox,
            bubble_fill_mask,
            safe_box=(
                _normalize_region_bbox(region.safe_box, canvas.size)
                if region.safe_box is not None
                else None
            ),
            explicit_shape=region.shape,
        )
        safe_text_mask = _build_region_safe_text_mask(bubble_fill_mask, fill_shape, resolved_direction)
        content_box = _resolve_region_text_box(
            region_payload,
            image_size=canvas.size,
            body_bbox=body_bbox,
            safe_mask=safe_text_mask,
            fill_shape=fill_shape,
            direction=resolved_direction,
        )
        box_width = max(8, content_box[2] - content_box[0])
        box_height = max(8, content_box[3] - content_box[1])

        layout = _fit_text_layout_for_render(
            translation,
            (box_width, box_height),
            preferred_direction or resolved_direction,
            preferred_font_size=style.font_size,
            bold=style.bold,
        )
        if preferred_direction is None and source_direction == "vertical":
            chosen_direction = str(layout.get("direction") or "")
            if chosen_direction != "vertical" and _text_supports_vertical_layout(translation):
                vertical_layout = _fit_text_layout_for_render(
                    translation,
                    (box_width, box_height),
                    "vertical",
                    preferred_font_size=style.font_size,
                    bold=style.bold,
                )
                if _layout_score_tuple(vertical_layout, (box_width, box_height)) <= _layout_score_tuple(
                    layout, (box_width, box_height)
                ):
                    layout = vertical_layout
                    layout_retry_count += 1
        if not bool(layout.get("fits")):
            alternate_direction = (
                "horizontal"
                if str(layout.get("direction") or preferred_direction or resolved_direction) == "vertical"
                else "vertical"
            )
            alternate_layout = _fit_text_layout_for_render(
                translation,
                (box_width, box_height),
                alternate_direction,
                preferred_font_size=style.font_size,
                bold=style.bold,
            )
            if _layout_score_tuple(alternate_layout, (box_width, box_height)) < _layout_score_tuple(
                layout, (box_width, box_height)
            ):
                layout = alternate_layout
                layout_retry_count += 1
        # 当最终渲染方向与初始方向不一致时，重新计算文本框以匹配实际方向
        final_direction = str(layout.get("direction") or "horizontal")
        if final_direction != resolved_direction:
            safe_text_mask = _build_region_safe_text_mask(
                bubble_fill_mask,
                fill_shape,
                final_direction,
            )
            content_box = _resolve_region_text_box(
                region_payload,
                image_size=canvas.size,
                body_bbox=body_bbox,
                safe_mask=safe_text_mask,
                fill_shape=fill_shape,
                direction=final_direction,
            )
            box_width = max(8, content_box[2] - content_box[0])
            box_height = max(8, content_box[3] - content_box[1])
            layout = _fit_text_layout_for_render(
                translation,
                (box_width, box_height),
                final_direction,
                preferred_font_size=style.font_size,
                bold=style.bold,
            )
        overflow_value = float(layout.get("overflow") or 0.0)
        requires_compression = not bool(layout.get("fits")) or overflow_value > 0
        text_layer: Image.Image | None = None
        outside_pixel_count = 0
        if not requires_compression:
            text_layer, outside_pixel_count = _render_text_layout_to_bubble_layer(
                body_bbox,
                content_box,
                layout,
                style.text_color,
                style.stroke_color,
                style.stroke_width,
                safe_text_mask,
            )
            max_masked_outside_pixels = max(max_masked_outside_pixels, outside_pixel_count)
            for _ in range(4):
                if outside_pixel_count <= 0:
                    break
                retry_box = _shrink_absolute_bbox(
                    content_box,
                    max(2, min(10, (content_box[2] - content_box[0]) // 24)),
                    max(2, min(10, (content_box[3] - content_box[1]) // 24)),
                )
                if retry_box is None:
                    break
                content_box = retry_box
                box_width = max(8, content_box[2] - content_box[0])
                box_height = max(8, content_box[3] - content_box[1])
                layout = _fit_text_layout_for_render(
                    translation,
                    (box_width, box_height),
                    final_direction,
                    preferred_font_size=max(
                        10,
                        int(layout.get("font_size") or style.font_size) - 1,
                    ),
                    bold=style.bold,
                )
                mask_layout_retry_count += 1
                overflow_value = float(layout.get("overflow") or 0.0)
                if not bool(layout.get("fits")) or overflow_value > 0:
                    break
                text_layer, outside_pixel_count = _render_text_layout_to_bubble_layer(
                    body_bbox,
                    content_box,
                    layout,
                    style.text_color,
                    style.stroke_color,
                    style.stroke_width,
                    safe_text_mask,
                )
                max_masked_outside_pixels = max(
                    max_masked_outside_pixels,
                    outside_pixel_count,
                )
            requires_compression = (
                not bool(layout.get("fits")) or overflow_value > 0 or outside_pixel_count > 0
            )

        if requires_compression:
            overflow_region_count += 1
            max_overflow = max(max_overflow, overflow_value)
            text_layer, overflow_scale = _render_compressed_text_layout_to_bubble_layer(
                body_bbox,
                content_box,
                layout,
                style.text_color,
                style.stroke_color,
                style.stroke_width,
                safe_text_mask,
            )
            if text_layer.getchannel("A").getbbox() is None or overflow_scale <= 0:
                skipped_overflow_region_count += 1
                continue
            compressed_overflow_region_count += 1
            min_overflow_scale = min(min_overflow_scale, overflow_scale)

        erased_pixels, cleanup_method = _erase_manga_source_text(
            canvas,
            bbox,
            style,
            fill_color,
            limit_bbox=body_bbox,
            limit_mask=cleanup_limit_mask,
        )
        if erased_pixels > 0:
            source_text_erased_region_count += 1
            if used_tight_bbox_cleanup_fallback:
                tight_bbox_cleanup_fallback_region_count += 1
        if cleanup_method == "solid":
            solid_cleanup_region_count += 1
        elif cleanup_method == "inpaint":
            inpaint_cleanup_region_count += 1
        canvas.alpha_composite(text_layer, (body_bbox[0], body_bbox[1]))
        rendered_translations.append(translation)
        rendered_region_count += 1
        if str(layout.get("direction") or "horizontal") == "vertical":
            rendered_vertical_count += 1
        else:
            rendered_horizontal_count += 1

    output = BytesIO()
    canvas.save(output, format="PNG")
    page_translation = page_payload.page_translation.strip() or "\n".join(rendered_translations).strip()
    if not page_translation:
        page_translation = "【本页未识别到可翻译文字】"
    return (
        output.getvalue(),
        page_translation,
        {
            "rendered_region_count": rendered_region_count,
            "skipped_empty_region_count": skipped_empty_region_count,
            "skipped_bbox_region_count": skipped_bbox_region_count,
            "skipped_unchanged_region_count": skipped_unchanged_region_count,
            "skipped_nonlinguistic_region_count": skipped_nonlinguistic_region_count,
            "skipped_unsafe_cleanup_region_count": skipped_unsafe_cleanup_region_count,
            "rendered_vertical_count": rendered_vertical_count,
            "rendered_horizontal_count": rendered_horizontal_count,
            "layout_retry_count": layout_retry_count,
            "mask_layout_retry_count": mask_layout_retry_count,
            "overflow_region_count": overflow_region_count,
            "skipped_overflow_region_count": skipped_overflow_region_count,
            "compressed_overflow_region_count": compressed_overflow_region_count,
            "max_overflow": round(max_overflow, 3),
            "min_overflow_scale": round(min_overflow_scale, 4),
            "max_masked_outside_pixels": max_masked_outside_pixels,
            "style_estimated_region_count": style_estimated_region_count,
            "source_text_erased_region_count": source_text_erased_region_count,
            "solid_cleanup_region_count": solid_cleanup_region_count,
            "inpaint_cleanup_region_count": inpaint_cleanup_region_count,
            "tight_bbox_cleanup_fallback_region_count": tight_bbox_cleanup_fallback_region_count,
            "average_source_font_size": round(
                source_font_size_total / max(1, style_estimated_region_count),
                1,
            ),
        },
    )


def _format_manga_page_diagnostics_log(log_prefix: str, page_payload: MangaTranslatedPagePayload) -> str:
    diagnostics = dict(page_payload.diagnostics or {})
    return (
        f"{log_prefix}诊断：mode={page_payload.render_mode}, "
        f"regions={diagnostics.get('region_count', len(page_payload.regions))}, "
        f"empty={diagnostics.get('empty_translation_count', 0)}, "
        f"overflow={diagnostics.get('overflow_region_count', 0)}, "
        f"compressed={diagnostics.get('compressed_overflow_region_count', 0)}, "
        f"erased={diagnostics.get('source_text_erased_region_count', 0)}, "
        f"font={diagnostics.get('average_source_font_size', 0)}, "
        f"pipeline_ms={diagnostics.get('pipeline_ms', 0)}"
    )


async def _emit_single_image_diagnostics(
    *,
    log_callback: Callable[[str, str], Awaitable[None] | None] | None,
    page_payload: MangaTranslatedPagePayload,
    source_name: str,
    target_language: str,
    trace_id: str,
) -> None:
    if log_callback is None:
        return
    diagnostics = dict(page_payload.diagnostics or {})
    summary = {
        "trace_id": trace_id,
        "source_image": Path(source_name).name,
        "target_language": _resolve_translation_target_language(target_language),
        "render_mode": page_payload.render_mode,
        "region_count": int(diagnostics.get("region_count") or len(page_payload.regions)),
        "empty_translation_count": int(diagnostics.get("empty_translation_count") or 0),
        "overflow_region_count": int(diagnostics.get("overflow_region_count") or 0),
        "compressed_overflow_region_count": int(diagnostics.get("compressed_overflow_region_count") or 0),
        "source_text_erased_region_count": int(diagnostics.get("source_text_erased_region_count") or 0),
        "average_source_font_size": diagnostics.get("average_source_font_size"),
        "pipeline_ms": diagnostics.get("pipeline_ms"),
        "ocr_translate_ms": diagnostics.get("ocr_translate_ms"),
        "render_ms": diagnostics.get("render_ms"),
    }
    await _notify_task_log(
        log_callback,
        "info",
        f"[single-image-diagnostics]{json.dumps(summary, ensure_ascii=False, separators=(',', ':'))}",
    )


async def _translate_manga_page_with_pipeline(
    *,
    settings: TranslationSettings,
    base_url: str,
    api_key: str,
    model: str,
    image_path: Path,
    target_language: str,
    timeout_seconds: int,
    chapter_title: str = "",
    chapter_index: int = 0,
    page_number: int = 0,
    total_pages: int = 0,
    source_image_file: str | None = None,
    translated_image_file: str | None = None,
) -> tuple[bytes, str, MangaTranslatedPagePayload]:
    pipeline_started_at = time.perf_counter()
    payload_started_at = time.perf_counter()
    page_payload = await _build_translated_manga_page_payload(
        settings=settings,
        base_url=base_url,
        api_key=api_key,
        model=model,
        image_path=image_path,
        target_language=target_language,
        timeout_seconds=timeout_seconds,
        chapter_title=chapter_title,
        chapter_index=chapter_index,
        page_number=page_number,
        total_pages=total_pages,
        source_image_file=source_image_file,
        translated_image_file=translated_image_file,
    )
    ocr_translate_ms = round((time.perf_counter() - payload_started_at) * 1000, 1)
    render_started_at = time.perf_counter()
    translated_bytes, page_translation, render_diagnostics = await asyncio.to_thread(
        _render_translated_manga_page_to_image,
        image_path,
        page_payload,
    )
    render_ms = round((time.perf_counter() - render_started_at) * 1000, 1)
    finalized_diagnostics = dict(page_payload.diagnostics or {})
    finalized_diagnostics.update(render_diagnostics)
    finalized_diagnostics["ocr_translate_ms"] = ocr_translate_ms
    finalized_diagnostics["render_ms"] = render_ms
    finalized_diagnostics["pipeline_ms"] = round((time.perf_counter() - pipeline_started_at) * 1000, 1)
    finalized_payload = page_payload.model_copy(
        update={
            "page_translation": page_translation,
            "diagnostics": finalized_diagnostics,
        }
    )
    return translated_bytes, page_translation, finalized_payload


async def _translate_manga_page_with_chat_completions(
    *,
    settings: TranslationSettings,
    base_url: str,
    api_key: str,
    model: str,
    image_path: Path,
    target_language: str,
    timeout_seconds: int,
    chapter_title: str = "",
    chapter_index: int = 0,
    page_number: int = 0,
    total_pages: int = 0,
    source_image_file: str | None = None,
    translated_image_file: str | None = None,
) -> tuple[bytes, str]:
    translated_bytes, page_translation, _ = await _translate_manga_page_with_pipeline(
        settings=settings,
        base_url=base_url,
        api_key=api_key,
        model=model,
        image_path=image_path,
        target_language=target_language,
        timeout_seconds=timeout_seconds,
        chapter_title=chapter_title,
        chapter_index=chapter_index,
        page_number=page_number,
        total_pages=total_pages,
        source_image_file=source_image_file,
        translated_image_file=translated_image_file,
    )
    return translated_bytes, page_translation


def _ensure_png_image_bytes(image_bytes: bytes) -> bytes:
    if image_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
        return image_bytes

    with Image.open(BytesIO(image_bytes)) as image:
        output = BytesIO()
        image = image.convert("RGBA") if image.mode in {"RGBA", "LA", "P"} else image.convert("RGB")
        image.save(output, format="PNG")
        return output.getvalue()


async def _request_manga_image_edit_bytes(
    *,
    base_url: str,
    api_key: str,
    model: str,
    image_path: Path,
    prompt: str,
    timeout_seconds: int,
) -> bytes:
    mime_type = mimetypes.guess_type(image_path.name)[0] or "image/png"
    image_bytes = image_path.read_bytes()
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Accept": "application/json, image/png, image/*;q=0.9, */*;q=0.8",
    }
    data = {
        "model": model,
        "prompt": prompt,
        "size": "auto",
        "quality": "medium",
        "output_format": "png",
        "response_format": "b64_json",
        "n": "1",
    }
    retryable_status_codes = {408, 409, 425, 429, 500, 502, 503, 504}
    retryable_exceptions: tuple[type[Exception], ...] = (
        httpx.TransportError,
        ssl.SSLError,
    )
    last_error: Exception | None = None

    async with _create_model_http_client(timeout=float(timeout_seconds)) as client:
        for attempt in range(1, 4):
            try:
                response = await client.post(
                    f"{base_url}/images/edits",
                    headers=headers,
                    data=data,
                    files={"image": (image_path.name, image_bytes, mime_type)},
                )
                if response.status_code in retryable_status_codes and attempt < 3:
                    await asyncio.sleep(min(1.5 * attempt, 4.0))
                    continue
                if response.is_error:
                    detail = _summarize_image_api_error(response)
                    raise RuntimeError(f"漫画译图接口请求失败：HTTP {response.status_code}，{detail}")

                content_type = str(response.headers.get("Content-Type") or "").lower()
                if content_type.startswith("image/"):
                    if not response.content:
                        raise ValueError(f"漫画译图接口返回了空图片响应：{content_type}")
                    return response.content

                if response.content:
                    try:
                        with Image.open(BytesIO(response.content)):
                            return response.content
                    except UnidentifiedImageError:
                        pass

                text_body = response.text.strip()
                resolved_text_payload = _extract_image_bytes_from_text_body(text_body)
                if isinstance(resolved_text_payload, bytes):
                    return resolved_text_payload
                if isinstance(resolved_text_payload, str):
                    download_response = await client.get(resolved_text_payload)
                    download_response.raise_for_status()
                    return download_response.content

                if not text_body:
                    raise ValueError(f"漫画译图接口返回为空响应，Content-Type={content_type or 'unknown'}")

                try:
                    payload = response.json()
                except ValueError as exc:
                    preview = text_body[:240]
                    raise ValueError(
                        f"漫画译图接口返回了无法解析的响应，Content-Type={content_type or 'unknown'}，响应片段：{preview}"
                    ) from exc
                if not isinstance(payload, dict):
                    raise ValueError("漫画译图接口返回不是有效 JSON")

                resolved_image = _extract_image_bytes_from_payload(payload)
                if isinstance(resolved_image, bytes):
                    return resolved_image
                if not isinstance(resolved_image, str):
                    raise ValueError("漫画译图接口返回缺少可下载图片地址")

                download_response = await client.get(resolved_image)
                download_response.raise_for_status()
                return download_response.content
            except retryable_exceptions as exc:
                last_error = exc
                if attempt >= 3:
                    break
                await asyncio.sleep(min(1.5 * attempt, 4.0))
            except httpx.HTTPStatusError as exc:
                last_error = exc
                if attempt >= 3:
                    break
                await asyncio.sleep(min(1.5 * attempt, 4.0))
            except RuntimeError as exc:
                last_error = exc
                if attempt >= 3:
                    break
                if (
                    "HTTP 408" not in str(exc)
                    and "HTTP 409" not in str(exc)
                    and "HTTP 425" not in str(exc)
                    and "HTTP 429" not in str(exc)
                    and "HTTP 500" not in str(exc)
                    and "HTTP 502" not in str(exc)
                    and "HTTP 503" not in str(exc)
                    and "HTTP 504" not in str(exc)
                ):
                    raise
                await asyncio.sleep(min(1.5 * attempt, 4.0))

    raise last_error or ValueError("漫画译图请求失败")


async def _translate_manga_pages_with_command_detailed(
    *,
    settings: TranslationSettings,
    target_language: str,
    chapter_index: int,
    title: str,
    image_files: list[str],
    book_dir: Path,
    log_callback: Callable[[str, str], Awaitable[None] | None] | None = None,
    progress_callback: Callable[[int, int], Awaitable[None] | None] | None = None,
    checkpoint_path: Path | None = None,
) -> tuple[list[str], list[str], list[MangaTranslatedPagePayload]]:
    if not image_files:
        raise ValueError("漫画章节没有可翻译的页面图片")

    base_url, api_key, image_model = _resolve_manga_image_provider_config(settings)
    resolved_target_language = _resolve_translation_target_language(target_language)
    page_translations: list[str] = []
    translated_image_files: list[str] = []
    translated_pages: list[MangaTranslatedPagePayload] = []
    total_pages = len(image_files)
    checkpoint_pages = (
        _load_manga_translation_checkpoint(
            checkpoint_path,
            book_dir=book_dir,
            base_url=base_url,
            model=image_model,
            target_language=resolved_target_language,
            image_files=image_files,
        )
        if checkpoint_path is not None
        else []
    )

    for page_number, asset_path in enumerate(image_files, start=1):
        page_started_at = time.perf_counter()
        image_path = (book_dir / asset_path).resolve()
        if not image_path.exists():
            raise ValueError(f"漫画页面文件不存在：{asset_path}")

        translated_asset_path = build_translated_image_asset_path(asset_path)
        translated_image_path = (book_dir / translated_asset_path).resolve()
        translated_image_path.parent.mkdir(parents=True, exist_ok=True)

        log_prefix = f"[漫画译图][第 {page_number}/{total_pages} 页] "
        if page_number <= len(checkpoint_pages):
            checkpoint_page = checkpoint_pages[page_number - 1]
            page_translations.append(checkpoint_page.page_translation)
            translated_image_files.append(translated_asset_path)
            translated_pages.append(checkpoint_page)
            await _notify_task_log(
                log_callback,
                "info",
                f"{log_prefix}已从断点恢复，跳过 OCR、模型调用与图片回填",
            )
            if progress_callback is not None:
                progress_result = progress_callback(page_number, total_pages)
                if progress_result is not None:
                    await progress_result
            continue

        translated_image_path.unlink(missing_ok=True)
        await _notify_task_log(
            log_callback,
            "info",
            f"{log_prefix}开始调用模型 {image_model} 处理图片：{asset_path}",
        )

        await _notify_task_log(
            log_callback,
            "info",
            f"{log_prefix}固定流程：OCR 识别 → 分区翻译 → 原文清除 → 样式自适应回填",
        )
        translated_bytes, page_translation, page_payload = await _translate_manga_page_with_pipeline(
            settings=settings,
            base_url=base_url,
            api_key=api_key,
            model=image_model,
            image_path=image_path,
            target_language=resolved_target_language,
            timeout_seconds=BUILTIN_MANGA_IMAGE_TIMEOUT_SECONDS,
            chapter_title=title,
            chapter_index=chapter_index,
            page_number=page_number,
            total_pages=total_pages,
            source_image_file=asset_path,
            translated_image_file=translated_asset_path,
        )

        normalized_bytes = _ensure_png_image_bytes(translated_bytes)
        translated_image_path.write_bytes(normalized_bytes)
        if translated_image_path.stat().st_size <= 0:
            raise RuntimeError(f"{log_prefix}未生成有效输出图片：{translated_image_path}")

        resolved_diagnostics = dict((page_payload.diagnostics if page_payload else {}) or {})
        resolved_diagnostics.setdefault(
            "pipeline_ms", round((time.perf_counter() - page_started_at) * 1000, 1)
        )
        resolved_diagnostics["output_bytes"] = len(normalized_bytes)
        resolved_page_payload = (page_payload or MangaTranslatedPagePayload()).model_copy(
            update={
                "page_number": page_number,
                "target_language": resolved_target_language,
                "source_image_file": asset_path,
                "translated_image_file": translated_asset_path,
                "page_translation": page_translation,
                "diagnostics": resolved_diagnostics,
            }
        )
        page_translations.append(page_translation)
        translated_image_files.append(translated_asset_path)
        translated_pages.append(resolved_page_payload)
        if checkpoint_path is not None:
            await asyncio.to_thread(
                _write_manga_translation_checkpoint,
                checkpoint_path,
                book_dir=book_dir,
                base_url=base_url,
                model=image_model,
                target_language=resolved_target_language,
                image_files=image_files,
                pages=translated_pages,
            )
        await _notify_task_log(
            log_callback,
            "info",
            _format_manga_page_diagnostics_log(log_prefix, resolved_page_payload),
        )
        await _notify_task_log(
            log_callback,
            "info",
            f"{log_prefix}处理完成，输出文件：{translated_asset_path}",
        )
        if progress_callback is not None:
            progress_result = progress_callback(page_number, total_pages)
            if progress_result is not None:
                await progress_result

    return page_translations, translated_image_files, translated_pages


async def _translate_manga_pages_with_command(
    *,
    settings: TranslationSettings,
    target_language: str,
    chapter_index: int,
    title: str,
    image_files: list[str],
    book_dir: Path,
    log_callback: Callable[[str, str], Awaitable[None] | None] | None = None,
) -> tuple[list[str], list[str]]:
    page_translations, translated_image_files, _ = await _translate_manga_pages_with_command_detailed(
        settings=settings,
        target_language=target_language,
        chapter_index=chapter_index,
        title=title,
        image_files=image_files,
        book_dir=book_dir,
        log_callback=log_callback,
    )
    return page_translations, translated_image_files


def _sync_fetch_with_httpx(url: str, referer: str | None = None) -> SyncFetchResult:
    headers = dict(DEFAULT_HEADERS)
    headers["Accept-Encoding"] = "identity"
    headers["Accept-Language"] = "ja,en;q=0.9"
    if referer:
        headers["Referer"] = referer
    with httpx.Client(follow_redirects=True, timeout=30.0, headers=headers) as client:
        client.cookies.set("over18", "yes", domain=".syosetu.com")
        client.cookies.set("over18", "yes", domain=".novel18.syosetu.com")
        response = client.get(url)
        response.raise_for_status()
        return SyncFetchResult(
            text=response.text, resolved_url=str(response.url), status_code=response.status_code
        )


def _sync_fetch_with_requests(url: str, referer: str | None = None) -> SyncFetchResult:
    if requests is None:
        raise RuntimeError("requests 不可用")
    session = requests.Session()
    session.cookies.set("over18", "yes", domain=".syosetu.com")
    session.cookies.set("over18", "yes", domain=".novel18.syosetu.com")
    headers = {
        "User-Agent": DEFAULT_HEADERS["User-Agent"],
        "Accept": DEFAULT_HEADERS["Accept"],
        "Accept-Language": "ja,en;q=0.9",
        "Accept-Encoding": "identity",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
    }
    if referer:
        headers["Referer"] = referer
    response = session.get(url, headers=headers, timeout=40)
    response.raise_for_status()
    return SyncFetchResult(
        text=response.text, resolved_url=str(response.url), status_code=response.status_code
    )


def _sync_fetch_with_curl_cffi(url: str, referer: str | None = None) -> SyncFetchResult:
    if curl_requests is None:
        raise RuntimeError("curl_cffi 不可用")
    headers = {
        "Accept-Language": "ja,en;q=0.9",
        "Accept-Encoding": "identity",
    }
    if referer:
        headers["Referer"] = referer
    cookies = {"over18": "yes"} if _is_novel18_url(url) else None
    response = curl_requests.get(url, impersonate="chrome124", timeout=40, headers=headers, cookies=cookies)
    response.raise_for_status()
    return SyncFetchResult(
        text=response.text, resolved_url=str(response.url), status_code=response.status_code
    )


def _18comic_session_headers(referer: str | None = None) -> dict[str, str]:
    headers: dict[str, str] = {}
    if referer:
        headers["Referer"] = referer
    return headers


def _sync_fetch_18comic_html(url: str, referer: str | None = None) -> SyncFetchResult:
    if curl_requests is None:
        raise RuntimeError("curl_cffi 不可用，无法抓取 18Comic")
    parsed = urlparse(url)
    is_photo_page = "/photo/" in parsed.path
    warmup_url = _18comic_album_url(url if is_photo_page else referer) if (is_photo_page or referer) else None
    request_referer = url if is_photo_page else referer
    last_error: Exception | None = None
    for attempt in range(1, 4):
        session = curl_requests.Session(impersonate="chrome124")
        try:
            if warmup_url:
                session.get(warmup_url, timeout=40)
            response = session.get(url, headers=_18comic_session_headers(request_referer), timeout=40)
            response.raise_for_status()
            return SyncFetchResult(
                text=response.text, resolved_url=str(response.url), status_code=response.status_code
            )
        except Exception as exc:
            last_error = exc
            if attempt >= 3:
                break
            time.sleep(1.0 * attempt)
    raise last_error or RuntimeError(f"18Comic HTML fetch failed: {url}")


# ===== 18Comic（禁漫）数据获取：复用社区维护的 jmcomic 库 =====
# 网页端受 Cloudflare 人机校验拦截（403）。jmcomic 移动 API 客户端会自动拉取最新 API/图片域名、
# 处理 token 签名与响应解密，避免我们自行维护频繁轮换的域名；图片仍用本地反混淆（算法一致）。
JM_SCRAMBLE_ID = 220980
JM_APP_UA = (
    "Mozilla/5.0 (Linux; Android 12; SM-G991B) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Mobile Safari/537.36 okhttp/3.12.1"
)
# 仅作为读取不到 jmcomic 实时图片域名时的兜底。
JM_IMAGE_FALLBACK_DOMAINS = [
    "cdn-msp.jmapiproxy1.cc",
    "cdn-msp2.jmapiproxy2.cc",
    "cdn-msp3.jmapiproxy2.cc",
]

_jm_client_instance: Any = None


def _jm_client() -> Any:
    """惰性创建并缓存 jmcomic 客户端（创建时会联网拉取最新域名）。"""
    global _jm_client_instance
    if _jm_client_instance is None:
        from jmcomic import JmOption

        _jm_client_instance = JmOption.default().new_jm_client()
    return _jm_client_instance


def _refresh_jm_client() -> None:
    global _jm_client_instance
    _jm_client_instance = None
    with suppress(Exception):
        _jm_client()


def _jm_live_image_domains() -> list[str]:
    try:
        from jmcomic import JmModuleConfig

        domains = [
            str(item).strip() for item in (JmModuleConfig.DOMAIN_IMAGE_LIST or []) if str(item).strip()
        ]
        if domains:
            return domains
    except Exception:  # noqa: BLE001 - 读取失败时退回静态兜底域名
        pass
    return JM_IMAGE_FALLBACK_DOMAINS


def _jm_cover_url(album_id: str) -> str:
    return f"https://{_jm_live_image_domains()[0]}/media/albums/{album_id}_3x4.jpg"


def _jm_photo_id_from_image_url(url: str) -> str | None:
    match = re.search(r"/media/photos/(\d+)/", urlparse(url).path)
    return match.group(1) if match else None


def _jm_image_candidate_urls(url: str) -> list[str]:
    parsed = urlparse(url)
    candidates = [url]
    for domain in _jm_live_image_domains():
        if domain == parsed.netloc:
            continue
        candidates.append(parsed._replace(netloc=domain).geturl())
    seen: set[str] = set()
    ordered: list[str] = []
    for candidate in candidates:
        if candidate not in seen:
            seen.add(candidate)
            ordered.append(candidate)
    return ordered


def _sync_fetch_18comic_binary(url: str, referer: str) -> bytes:
    if curl_requests is None:
        raise RuntimeError("curl_cffi unavailable, cannot fetch 18Comic images")
    # 从图片 URL 推导章节(photo) id，用于按 JM 规则反混淆；网页端 scramble_id 不可得时用常量 220980。
    photo_id = _jm_photo_id_from_image_url(url)
    descramble_referer = f"https://18comic.vip/photo/{photo_id}/" if photo_id else referer
    scramble_id = _18comic_cached_scramble_id(descramble_referer) or JM_SCRAMBLE_ID
    headers = {
        "user-agent": JM_APP_UA,
        "Referer": "https://18comic.vip/",
        "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
    }
    last_error: Exception | None = None
    for attempt in range(1, 4):
        if attempt > 1:
            _refresh_jm_client()
        candidates = _jm_image_candidate_urls(url)
        for candidate in candidates:
            try:
                response = curl_requests.get(candidate, impersonate="chrome", timeout=40, headers=headers)
                response.raise_for_status()
                image_bytes = bytes(response.content)
                return _18comic_descramble_bytes(image_bytes, candidate, descramble_referer, scramble_id)
            except Exception as exc:  # noqa: BLE001 - 跨 CDN 容错
                last_error = exc
                continue
        if attempt < 3:
            time.sleep(0.8 * attempt)
    raise last_error or RuntimeError(f"18Comic image download failed: {url}")


def _raise_special_site_error(url: str, exc: Exception | None = None) -> None:
    error_text = str(exc or "")
    if _is_novelup_url(url):
        raise ValueError(
            "Novelup 当前访问被 CloudFront 拦截（403），当前环境下即使使用浏览器会话也无法直接抓取该站点。"
        ) from exc
    if _is_alphapolis_url(url):
        raise ValueError("Alphapolis 当前直连会触发 AWS WAF challenge，需要走浏览器会话兜底抓取。") from exc
    if _is_hameln_url(url):
        if "404" in error_text:
            raise ValueError("Hameln 返回 404，请确认该作品仍然公开可访问。") from exc
        raise ValueError("Hameln 当前触发 Cloudflare 挑战，无法直接抓取该章节内容。") from exc
    raise exc or ValueError(f"读取页面失败：{url}")


def _looks_like_block_page(url: str, result: SyncFetchResult) -> bool:
    text = result.text
    if _is_novelup_url(url):
        return "The request could not be satisfied" in text or "Request blocked" in text
    if _is_alphapolis_url(url):
        return (
            result.status_code == 202
            or "window.gokuProps" in text
            or "window.awsWafCookieDomainList" in text
            or "JavaScript is disabled" in text
        )
    if _is_hameln_url(url):
        return "Just a moment..." in text or "cf-challenge" in text
    return False


async def _fetch_site_html(url: str, referer: str | None = None) -> tuple[str, str]:
    fetchers = []
    if _is_hameln_url(url) or _is_novel18_url(url):
        fetchers.append(_sync_fetch_with_curl_cffi)
    fetchers.append(_sync_fetch_with_httpx)
    if _is_syosetu_url(url) or _is_novel18_url(url):
        fetchers.append(_sync_fetch_with_requests)
    if curl_requests is not None and (_is_alphapolis_url(url) or _is_novelup_url(url)):
        fetchers.append(_sync_fetch_with_curl_cffi)

    last_error: Exception | None = None
    for fetcher in fetchers:
        try:
            result = await asyncio.to_thread(fetcher, url, referer)
            if _looks_like_block_page(url, result):
                raise ValueError("目标站点返回了拦截页面")
            return result.text, result.resolved_url
        except Exception as exc:
            last_error = exc

    _raise_special_site_error(url, last_error)


def _find_browser_executable() -> Path | None:
    for candidate in BROWSER_EXECUTABLE_PATHS:
        if candidate.exists():
            return candidate
    for name in ("msedge", "msedge.exe", "chromium", "chromium-browser", "google-chrome"):
        resolved = shutil.which(name)
        if resolved:
            return Path(resolved)
    return None


def _find_edge_executable() -> Path | None:
    """向后兼容旧测试与调用；实际可返回 Edge、Chrome 或 Chromium。"""
    return _find_browser_executable()


def _reserve_local_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _list_edge_targets(port: int) -> list[dict[str, Any]]:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=1) as response:
        payload = response.read().decode("utf-8", errors="replace")
    result = json.loads(payload)
    return result if isinstance(result, list) else []


async def _wait_for_edge_page_target(port: int, timeout_seconds: float) -> str:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        try:
            targets = await asyncio.to_thread(_list_edge_targets, port)
        except Exception:
            await asyncio.sleep(0.25)
            continue
        for target in targets:
            if target.get("type") == "page" and target.get("webSocketDebuggerUrl"):
                return str(target["webSocketDebuggerUrl"])
        await asyncio.sleep(0.25)
    raise ValueError("未能连接到 Edge DevTools 页面目标")


async def _cdp_send_command(
    websocket: Any,
    method: str,
    params: dict[str, Any] | None = None,
    *,
    timeout_seconds: float = 20.0,
) -> dict[str, Any]:
    command_id = next(_CDP_COMMAND_IDS)
    await websocket.send(json.dumps({"id": command_id, "method": method, "params": params or {}}))
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        raw = await asyncio.wait_for(websocket.recv(), timeout=max(0.1, deadline - time.monotonic()))
        payload = json.loads(raw)
        if payload.get("id") == command_id:
            if "error" in payload:
                message = (
                    payload["error"].get("message")
                    if isinstance(payload.get("error"), dict)
                    else payload["error"]
                )
                raise ValueError(f"Edge DevTools 调用失败：{method} -> {message}")
            return payload
    raise TimeoutError(f"等待 Edge DevTools 返回超时：{method}")


async def _cdp_evaluate(
    websocket: Any,
    expression: str,
    *,
    await_promise: bool = False,
) -> Any:
    response = await _cdp_send_command(
        websocket,
        "Runtime.evaluate",
        {
            "expression": expression,
            "returnByValue": True,
            "awaitPromise": await_promise,
        },
    )
    result = response.get("result", {}).get("result", {})
    if "value" in result:
        return result["value"]
    if result.get("type") == "undefined":
        return None
    return result.get("description")


async def _fetch_with_edge_cdp(
    url: str,
    *,
    ready_expression: str,
    headless: bool,
    timeout_seconds: float = EDGE_CDP_PAGE_TIMEOUT_SECONDS,
    blocked_message: str | None = None,
) -> EdgeSnapshot:
    browser_path = _find_browser_executable()
    if browser_path is None:
        raise ValueError("未找到 Edge 或 Chromium，无法启用浏览器会话兜底抓取。")
    if websockets is None:
        raise ValueError("当前环境缺少 websockets 依赖，无法启用浏览器会话兜底抓取。")

    port = _reserve_local_port()
    user_data_dir = Path(tempfile.mkdtemp(prefix="qingjuan-edge-cdp-"))
    launch_args = [
        str(browser_path),
        f"--remote-debugging-port={port}",
        "--disable-gpu",
        "--disable-extensions",
        "--no-first-run",
        "--no-default-browser-check",
        f"--user-data-dir={user_data_dir}",
        "about:blank",
    ]
    if headless or os.name != "nt":
        launch_args.insert(2, "--headless=new")
    else:
        launch_args.insert(2, "--start-minimized")
    if os.name != "nt" and hasattr(os, "geteuid") and os.geteuid() == 0:
        launch_args.insert(2, "--no-sandbox")

    process = subprocess.Popen(launch_args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        ws_url = await _wait_for_edge_page_target(port, EDGE_CDP_BOOT_TIMEOUT_SECONDS)
        async with websockets.connect(ws_url, max_size=100_000_000) as websocket:
            await _cdp_send_command(websocket, "Page.enable")
            await _cdp_send_command(websocket, "Runtime.enable")
            await _cdp_send_command(websocket, "Network.enable")
            await _cdp_send_command(websocket, "Page.navigate", {"url": url})

            deadline = time.monotonic() + timeout_seconds
            last_title = ""
            last_url = url
            while time.monotonic() < deadline:
                ready = bool(await _cdp_evaluate(websocket, ready_expression))
                last_title = str(await _cdp_evaluate(websocket, "document.title || ''") or "")
                last_url = str(await _cdp_evaluate(websocket, "location.href || ''") or url)
                if ready:
                    html = str(
                        await _cdp_evaluate(websocket, "document.documentElement.outerHTML || ''") or ""
                    )
                    return EdgeSnapshot(html=html, resolved_url=last_url or url)
                await asyncio.sleep(EDGE_CDP_POLL_INTERVAL_SECONDS)

            html = str(await _cdp_evaluate(websocket, "document.documentElement.outerHTML || ''") or "")
            if "ERROR: The request could not be satisfied" in last_title or "403 ERROR" in html:
                raise ValueError(blocked_message or "浏览器会话仍然被目标站点拦截。")
            raise ValueError(f"浏览器会话抓取超时：{url}")
    finally:
        with suppress(Exception):
            process.kill()
        with suppress(Exception):
            process.wait(timeout=10)
        shutil.rmtree(user_data_dir, ignore_errors=True)


def _alphapolis_cover_data_from_html(html: str) -> dict[str, Any]:
    soup = BeautifulSoup(html, "html.parser")
    node = soup.select_one("#app-cover-data")
    if node is None:
        raise ValueError("未在 Alphapolis 页面中找到目录数据")
    try:
        payload = json.loads(node.get_text(strip=True))
    except Exception as exc:
        raise ValueError("Alphapolis 目录数据解析失败") from exc
    if not isinstance(payload, dict):
        raise ValueError("Alphapolis 目录数据格式异常")
    return payload


def _alphapolis_chapters_from_cover_data(data: dict[str, Any], base_url: str) -> list[ChapterPreview]:
    items: list[ChapterPreview] = []
    seen: set[str] = set()
    for group in data.get("chapterEpisodes") or []:
        if not isinstance(group, dict):
            continue
        group_title = str(group.get("title") or "").strip()
        episodes = group.get("episodes") or []
        if not isinstance(episodes, list):
            continue
        for episode in episodes:
            if not isinstance(episode, dict):
                continue
            if episode.get("isPublic") is False:
                continue
            episode_title = str(episode.get("mainTitle") or episode.get("title") or "").strip()
            href = str(episode.get("url") or "").strip()
            if not episode_title or not href:
                continue
            title = episode_title
            if group_title and group_title not in episode_title:
                title = f"{group_title} / {episode_title}"
            absolute_url = urljoin(base_url, href)
            if absolute_url in seen:
                continue
            seen.add(absolute_url)
            items.append(ChapterPreview(title=title[:120], url=absolute_url))
    return items


def _extract_18comic_cover(soup: BeautifulSoup, resolved_url: str) -> str | None:
    for selector in (".thumb-overlay img", ".img-responsive", "img[data-original]"):
        for image in soup.select(selector):
            for key in ("data-original", "data-src", "src"):
                value = str(image.get(key) or "").strip()
                if value and "blank.jpg" not in value and "new_logo" not in value:
                    return urljoin(resolved_url, value)
    return None


def _extract_18comic_synopsis(soup: BeautifulSoup) -> str:
    meta = soup.select_one("meta[name='description'], meta[property='og:description']")
    meta_text = meta.get("content") if meta is not None else ""
    if (
        isinstance(meta_text, str)
        and meta_text.strip()
        and meta_text.strip() not in {"免費成人H漫線上看", "免费成人H漫在线看"}
    ):
        return meta_text.strip()

    for panel in soup.select(".panel-body"):
        text = re.sub(r"\s+", " ", panel.get_text(" ", strip=True)).strip()
        if any(keyword in text for keyword in ("简介", "簡介", "描述", "敘述")):
            return text[:800]
    return ""


def _parse_18comic_page_images(html: str, current_url: str) -> list[str]:
    soup = BeautifulSoup(html, "html.parser")
    image_urls: list[str] = []
    images = []
    for selector in (
        ".row.thumb-overlay-albums .scramble-page img",
        ".panel-body .scramble-page img",
        ".scramble-page img",
    ):
        images = soup.select(selector)
        if images:
            break
    if not images:
        images = soup.select("img[data-original]")

    for image in images:
        for key in ("data-original", "data-src", "src"):
            value = str(image.get(key) or "").strip()
            if not value or value.endswith("blank.jpg"):
                continue
            absolute = urljoin(current_url, value)
            if "/media/photos/" not in urlparse(absolute).path:
                continue
            if absolute not in image_urls:
                image_urls.append(absolute)
            break
    return image_urls


def _bika_image_url(media: Any) -> str:
    if not isinstance(media, dict):
        return ""
    file_server = str(media.get("fileServer") or "").strip()
    path = str(media.get("path") or "").strip().lstrip("/")
    if not file_server or not path:
        return ""
    return f"{file_server.rstrip('/')}/static/{quote(path, safe='/')}"


def _load_runtime_settings() -> TranslationSettings:
    try:
        from .db import load_settings
    except ImportError:
        from app.db import load_settings
    return load_settings()


def _save_runtime_settings(settings: TranslationSettings) -> TranslationSettings:
    try:
        from .db import save_settings
    except ImportError:
        from app.db import save_settings
    return save_settings(settings)


def _require_bika_credentials(settings: TranslationSettings | None = None) -> tuple[str, str]:
    runtime_settings = settings or _load_runtime_settings()
    credential = runtime_settings.bika.email.strip()
    password = runtime_settings.bika.password.strip()
    if not credential and not password:
        return "", ""
    if not credential or not password:
        raise ValueError("Bika 账号和密码需同时填写，或留空后由系统自动创建。")
    return credential, password


def _bika_auth_payloads(credential: str, password: str) -> list[dict[str, str]]:
    preferred_fields = ["email", "username", "account"]
    return [{field: credential, "password": password} for field in preferred_fields]


def _bika_random_token(length: int = 10) -> str:
    return "".join(secrets.choice(BIKA_RANDOM_ALPHABET) for _ in range(max(1, length)))


def _bika_register_payload() -> tuple[str, str, dict[str, str]]:
    stamp = time.strftime("%y%m%d")
    suffix = _bika_random_token(8)
    credential = f"bw{stamp}{suffix}"[:20]
    password = f"pw{stamp}{suffix}"[:20]
    payload = {
        "name": f"web{suffix}"[:20],
        "email": credential,
        "password": password,
        "question1": f"q1{_bika_random_token(6)}",
        "answer1": f"a1{_bika_random_token(8)}",
        "question2": f"q2{_bika_random_token(6)}",
        "answer2": f"a2{_bika_random_token(8)}",
        "question3": f"q3{_bika_random_token(6)}",
        "answer3": f"a3{_bika_random_token(8)}",
        "birthday": "2000-01-01",
        "gender": "m",
    }
    return credential, password, payload


def _persist_bika_credentials(settings: TranslationSettings, credential: str, password: str) -> None:
    previous_credential = settings.bika.email.strip()
    settings.bika.email = credential
    settings.bika.password = password
    if previous_credential and previous_credential != credential:
        _BIKA_TOKEN_CACHE.pop(previous_credential, None)
    _save_runtime_settings(settings)


async def _register_bika_account(client: httpx.AsyncClient, settings: TranslationSettings) -> tuple[str, str]:
    error_messages: list[str] = []
    for _ in range(5):
        credential, password, payload = _bika_register_payload()
        try:
            await _bika_request_with_retry(
                client,
                "auth/register",
                "POST",
                json_payload=payload,
            )
        except httpx.HTTPStatusError as exc:
            error_messages.append(_bika_response_error_message(exc.response, "Bika 自动注册失败"))
            if exc.response.status_code not in {400, 409, 422}:
                raise ValueError(f"Bika 自动注册失败：{error_messages[-1]}") from exc
            continue
        except ValueError as exc:
            error_messages.append(str(exc).strip() or "Bika 自动注册失败")
            continue
        _persist_bika_credentials(settings, credential, password)
        return credential, password
    unique_messages = [message for message in dict.fromkeys(error_messages) if message]
    detail = f" 接口返回：{'；'.join(unique_messages)}" if unique_messages else ""
    raise ValueError(f"Bika 自动注册失败，已重试 5 次。{detail}".strip())


async def _ensure_bika_credentials(
    client: httpx.AsyncClient,
    settings: TranslationSettings | None = None,
) -> tuple[str, str]:
    runtime_settings = settings or _load_runtime_settings()
    credential, password = _require_bika_credentials(runtime_settings)
    if credential and password:
        return credential, password
    if multi_user_enabled():
        raise ValueError("Bika 服务凭据尚未配置，请管理员先在模型设置中填写账号与密码。")
    return await _register_bika_account(client, runtime_settings)


def _bika_response_error_message(response: httpx.Response, fallback: str) -> str:
    try:
        payload = response.json()
    except ValueError:
        payload = None
    if isinstance(payload, dict):
        for key in ("message", "detail", "error"):
            value = payload.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
            if isinstance(value, list):
                messages = [str(item).strip() for item in value if str(item).strip()]
                if messages:
                    return "；".join(messages)
            if isinstance(value, dict):
                messages = [str(item).strip() for item in value.values() if str(item).strip()]
                if messages:
                    return "；".join(messages)
    response_text = response.text.strip()
    return response_text or fallback


def _bika_signature(path: str, time_value: str, nonce: str, method: str) -> str:
    normalized_path = path.lstrip("/")
    message = f"{normalized_path}{time_value}{nonce}{method.upper()}{BIKA_SIGNATURE_SUFFIX}".lower()
    return hmac.new(BIKA_SIGNATURE_KEY.encode("utf-8"), message.encode("utf-8"), sha256).hexdigest()


def _bika_headers(path: str, method: str, token: str | None = None) -> dict[str, str]:
    time_value = str(int(time.time()))
    nonce = _bika_random_token(32)
    signature = _bika_signature(path, time_value, nonce, method)
    headers = {
        "app-channel": BIKA_APP_CHANNEL,
        "app-uuid": BIKA_APP_UUID,
        "app-version": BIKA_APP_VERSION,
        "accept": BIKA_API_ACCEPT,
        "app-platform": BIKA_APP_PLATFORM,
        "Content-Type": "application/json; charset=UTF-8",
        "time": time_value,
        "nonce": nonce,
        "image-quality": BIKA_IMAGE_QUALITY,
        "signature": signature,
        "User-Agent": DEFAULT_HEADERS["User-Agent"],
        "Accept-Language": DEFAULT_HEADERS["Accept-Language"],
        "Origin": BIKA_WEB_ORIGIN,
        "Referer": BIKA_WEB_REFERER,
    }
    if token:
        headers["authorization"] = token
    return headers


async def _bika_request(
    client: httpx.AsyncClient,
    path: str,
    method: str = "GET",
    *,
    token: str | None = None,
    json_payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    normalized_path = path.lstrip("/")
    response = await client.request(
        method.upper(),
        f"{BIKA_API_BASE_URL}/{normalized_path}",
        headers=_bika_headers(normalized_path, method, token),
        json=json_payload,
    )
    response.raise_for_status()
    payload = response.json()
    if isinstance(payload, dict) and payload.get("code") == 200:
        return payload
    if isinstance(payload, dict):
        message = str(payload.get("message") or payload.get("detail") or "Bika 接口返回异常").strip()
        raise ValueError(message or "Bika 接口返回异常")
    raise ValueError("Bika 接口返回了无法识别的数据结构")


async def _bika_request_with_retry(
    client: httpx.AsyncClient,
    path: str,
    method: str = "GET",
    *,
    token: str | None = None,
    json_payload: dict[str, Any] | None = None,
    max_retries: int = 3,
) -> dict[str, Any]:
    last_error: Exception | None = None
    for attempt in range(1, max_retries + 1):
        try:
            return await _bika_request(
                client,
                path,
                method,
                token=token,
                json_payload=json_payload,
            )
        except httpx.HTTPStatusError as exc:
            last_error = exc
            if exc.response.status_code not in MANGA_RETRYABLE_STATUS_CODES or attempt >= max_retries:
                raise
            await asyncio.sleep(_retry_wait_seconds(exc.response, attempt - 1))
        except (httpx.TransportError, ssl.SSLError) as exc:
            last_error = exc
            if attempt >= max_retries:
                break
            await asyncio.sleep(min(0.8 * attempt, 2.0))
    raise ValueError(f"Bika 请求失败：{last_error}") from last_error


async def _bika_auth_token(
    client: httpx.AsyncClient, settings: TranslationSettings | None = None, *, force: bool = False
) -> str:
    credential, password = await _ensure_bika_credentials(client, settings)
    cache_key = credential
    if not force and cache_key in _BIKA_TOKEN_CACHE:
        return _BIKA_TOKEN_CACHE[cache_key]
    error_messages: list[str] = []
    for auth_payload in _bika_auth_payloads(credential, password):
        try:
            payload = await _bika_request_with_retry(
                client,
                "auth/sign-in",
                "POST",
                json_payload=auth_payload,
            )
        except httpx.HTTPStatusError as exc:
            error_messages.append(_bika_response_error_message(exc.response, "Bika 登录失败"))
            if exc.response.status_code not in {400, 401, 422}:
                raise ValueError(error_messages[-1]) from exc
            continue
        except ValueError as exc:
            error_messages.append(str(exc).strip() or "Bika 登录失败")
            continue

        data = payload.get("data") if isinstance(payload, dict) else None
        token = ""
        if isinstance(data, dict):
            token = str(data.get("token") or data.get("authorization") or "").strip()
        if not token:
            token = str(payload.get("token") or "").strip() if isinstance(payload, dict) else ""
        if not token:
            raise ValueError("Bika 登录成功但没有返回 token")
        _BIKA_TOKEN_CACHE[cache_key] = token
        return token

    unique_messages = [message for message in dict.fromkeys(error_messages) if message]
    if unique_messages:
        raise ValueError(
            f"Bika 登录失败：已按邮箱和用户名两种方式尝试。接口返回：{'；'.join(unique_messages)}"
        )
    raise ValueError("Bika 登录失败：已按邮箱和用户名两种方式尝试，但接口没有返回可用结果")


async def _bika_authed_request(
    client: httpx.AsyncClient,
    path: str,
    method: str = "GET",
    *,
    settings: TranslationSettings | None = None,
    json_payload: dict[str, Any] | None = None,
) -> dict[str, Any]:
    token = await _bika_auth_token(client, settings)
    try:
        return await _bika_request_with_retry(client, path, method, token=token, json_payload=json_payload)
    except httpx.HTTPStatusError as exc:
        if exc.response.status_code != 401:
            raise
        token = await _bika_auth_token(client, settings, force=True)
        return await _bika_request_with_retry(client, path, method, token=token, json_payload=json_payload)


async def _bika_fetch_comic(
    client: httpx.AsyncClient, comic_id: str, settings: TranslationSettings | None = None
) -> dict[str, Any]:
    payload = await _bika_authed_request(client, f"comics/{comic_id}", settings=settings)
    data = payload.get("data") if isinstance(payload, dict) else None
    comic = data.get("comic") if isinstance(data, dict) else None
    if not isinstance(comic, dict):
        raise ValueError("Bika 漫画详情数据格式异常")
    return comic


async def _bika_fetch_episodes(
    client: httpx.AsyncClient,
    comic_id: str,
    settings: TranslationSettings | None = None,
) -> list[dict[str, Any]]:
    episodes: list[dict[str, Any]] = []
    page = 1
    while True:
        payload = await _bika_authed_request(client, f"comics/{comic_id}/eps?page={page}", settings=settings)
        data = payload.get("data") if isinstance(payload, dict) else None
        eps = data.get("eps") if isinstance(data, dict) else None
        if not isinstance(eps, dict):
            break
        docs = eps.get("docs")
        if isinstance(docs, list):
            episodes.extend(item for item in docs if isinstance(item, dict))
        current_page = int(eps.get("page") or page)
        total_pages = int(eps.get("pages") or current_page or 1)
        if current_page >= total_pages:
            break
        page = current_page + 1
    return episodes


async def _bika_fetch_pages(
    client: httpx.AsyncClient,
    comic_id: str,
    order: str,
    settings: TranslationSettings | None = None,
) -> tuple[list[str], str]:
    image_urls: list[str] = []
    chapter_title = ""
    page = 1
    while True:
        payload = await _bika_authed_request(
            client,
            f"comics/{comic_id}/order/{order}/pages?page={page}",
            settings=settings,
        )
        data = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(data, dict):
            raise ValueError("Bika 漫画页数据格式异常")
        pages = data.get("pages")
        if not isinstance(pages, dict):
            raise ValueError("Bika 漫画页列表缺失")
        docs = pages.get("docs")
        if isinstance(docs, list):
            for item in docs:
                media = item.get("media") if isinstance(item, dict) else None
                image_url = _bika_image_url(media)
                if image_url and image_url not in image_urls:
                    image_urls.append(image_url)
        episode = data.get("ep")
        if isinstance(episode, dict) and not chapter_title:
            chapter_title = str(episode.get("title") or "").strip()
        current_page = int(pages.get("page") or page)
        total_pages = int(pages.get("pages") or current_page or 1)
        if current_page >= total_pages:
            break
        page = current_page + 1
    return image_urls, chapter_title


def _jm_author_text(author_field: Any) -> str | None:
    if isinstance(author_field, list):
        joined = "、".join(str(item).strip() for item in author_field if str(item).strip())
        return joined or None
    text = str(author_field or "").strip()
    return text or None


def _build_18comic_preview_from_api(album_id: str, payload: AddBookPayload) -> PreviewResponse:
    album = _jm_client().get_album_detail(str(album_id))
    title = str(getattr(album, "title", "") or payload.title or "未命名漫画").strip()
    synopsis = str(getattr(album, "description", "") or "").strip()
    chapters: list[ChapterPreview] = []
    # episode_list 每项形如 (photo_id, sort, title)。
    for entry in getattr(album, "episode_list", []) or []:
        try:
            photo_id = str(entry[0]).strip()
            sort = str(entry[1]).strip() if len(entry) > 1 else ""
            entry_title = str(entry[2]).strip() if len(entry) > 2 else ""
        except (IndexError, TypeError):
            continue
        if not photo_id:
            continue
        chapter_title = entry_title or (f"第{sort}话" if sort else "章节")
        chapters.append(
            ChapterPreview(title=chapter_title, url=f"https://18comic.vip/photo/{photo_id}/", pageCount=0)
        )
    if not chapters:
        chapters = [ChapterPreview(title=title, url=f"https://18comic.vip/photo/{album_id}/", pageCount=0)]
    return PreviewResponse(
        title=title,
        author=_jm_author_text(getattr(album, "author", None) or getattr(album, "authors", None)),
        synopsis=synopsis,
        cover=_jm_cover_url(album_id),
        chapterCount=len(chapters),
        chapters=chapters,
    )


async def _preview_18comic(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    album_id = _18comic_album_id_from_url(source_url)
    if album_id:
        try:
            return await asyncio.to_thread(_build_18comic_preview_from_api, album_id, payload)
        except Exception as exc:  # noqa: BLE001 - API 不可用时回退网页解析
            import logging

            logging.getLogger("qingjuan.scraper").warning("18Comic 移动 API 预览失败，回退网页解析：%s", exc)
    album_url = _18comic_album_url(source_url)
    result = await asyncio.to_thread(_sync_fetch_18comic_html, album_url)
    soup = BeautifulSoup(result.text, "html.parser")
    fallback_title = payload.title or Path(urlparse(source_url).path).stem or "未命名漫画"
    title = str(
        (soup.select_one("h1") or soup.select_one("title")).get_text(" ", strip=True)
        if (soup.select_one("h1") or soup.select_one("title"))
        else fallback_title
    ).strip()
    title = _clean_title_suffix(title, (" Comics - ????", " - ????", " Comics", "|H?????? Comics - ????"))
    read_anchor = soup.select_one("a[href*='/photo/']")
    photo_url = (
        urljoin(result.resolved_url, str(read_anchor.get("href") or "").strip())
        if read_anchor is not None
        else _18comic_photo_url(album_url)
    )
    photo_result = await asyncio.to_thread(_sync_fetch_18comic_html, photo_url, album_url)
    _18comic_cache_scramble_id(source_url, photo_result.text)
    page_count = len(_parse_18comic_page_images(photo_result.text, photo_result.resolved_url))
    chapter_title = title if page_count <= 1 else f"{title} / 第1话"
    return PreviewResponse(
        title=title,
        author=None,
        synopsis=_extract_18comic_synopsis(soup),
        cover=_extract_18comic_cover(soup, result.resolved_url),
        chapterCount=1,
        chapters=[ChapterPreview(title=chapter_title, url=photo_url, pageCount=page_count)],
    )


async def _preview_bika(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    comic_id = _bika_comic_id_from_url(source_url)
    if not comic_id:
        raise ValueError("无法识别 Bika 漫画编号")
    runtime_settings = _load_runtime_settings()
    async with _create_async_http_client(timeout=40.0) as client:
        comic = await _bika_fetch_comic(client, comic_id, runtime_settings)
        episodes = await _bika_fetch_episodes(client, comic_id, runtime_settings)
    title = str(comic.get("title") or payload.title or "未命名漫画").strip()
    author = str(comic.get("author") or comic.get("chineseTeam") or "").strip() or None
    synopsis = str(comic.get("description") or "").strip()
    cover = _bika_image_url(comic.get("thumb"))
    base_origin = f"{urlparse(source_url).scheme}://{urlparse(source_url).netloc}"
    chapters: list[ChapterPreview] = []
    for item in sorted(episodes, key=lambda episode: int(episode.get("order") or 0)):
        order = str(item.get("order") or "").strip()
        if not order:
            continue
        chapter_title = str(item.get("title") or "").strip() or f"第{order}话"
        chapters.append(
            ChapterPreview(
                title=chapter_title,
                url=f"{base_origin}/comic/reader/{comic_id}/{order}",
                pageCount=0,
            )
        )
    if not chapters:
        chapters = [ChapterPreview(title=title, url=f"{base_origin}/comic/reader/{comic_id}/1", pageCount=0)]
    return PreviewResponse(
        title=title,
        author=author,
        synopsis=synopsis,
        cover=cover,
        chapterCount=len(chapters),
        chapters=chapters,
    )


async def _preview_kakuyomu(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    work_id = _kakuyomu_work_id_from_url(source_url)
    if not work_id:
        raise ValueError("无法识别 Kakuyomu 作品编号")
    async with _build_http_client() as client:
        response = await client.post(
            KAKUYOMU_GRAPHQL_ENDPOINT,
            json={
                "query": KAKUYOMU_WORK_QUERY,
                "variables": {"workId": work_id},
                "operationName": "GetQingJuanWork",
            },
            headers={
                "Accept": "application/json",
                "Content-Type": "application/json",
                "Origin": "https://kakuyomu.jp",
                "Referer": f"https://kakuyomu.jp/works/{work_id}",
                "User-Agent": DEFAULT_HEADERS["User-Agent"],
                "apollographql-client-name": "kakuyomu-web",
                "apollographql-client-version": "1.0.0",
            },
        )
        if response.status_code >= 400:
            raise ValueError(f"Kakuyomu GraphQL 请求失败：HTTP {response.status_code}")
        try:
            graphql_payload = response.json()
        except json.JSONDecodeError as exc:
            raise ValueError("Kakuyomu GraphQL 返回的不是 JSON") from exc

    work = parse_kakuyomu_work_response(graphql_payload, work_id)
    chapters = [
        ChapterPreview(
            title=episode.title,
            url=f"https://kakuyomu.jp/works/{work_id}/episodes/{episode.id}",
        )
        for episode in work.episodes
    ]
    if not chapters:
        raise ValueError("Kakuyomu GraphQL 未返回任何公开章节")

    return PreviewResponse(
        title=work.title or payload.title or "未命名小说",
        author=work.author,
        synopsis=work.synopsis,
        cover=work.cover,
        chapterCount=len(chapters),
        chapters=chapters,
    )


async def _preview_yanmaga(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    resource = yanmaga_resource_from_url(source_url)
    if resource is None:
        raise ValueError("无法识别 Yanmaga 作品链接，请使用 https://yanmaga.jp/comics/作品路径")
    book_path, _ = resource
    book_url = canonical_yanmaga_url(book_path)

    async with _build_http_client() as client:
        response = await client.get(book_url, headers=_request_headers(book_url))
        if response.status_code >= 400:
            raise ValueError(f"Yanmaga 作品页请求失败：HTTP {response.status_code}")
        book = parse_yanmaga_book_page(response.text, book_url)
        episodes = list(book.episodes)

        if book.next_path and book.next_offset is not None:
            fragment_url = urljoin(YANMAGA_ORIGIN, book.next_path)
            fragment_target = urlparse(fragment_url)
            expected_path = unquote(urlparse(book_url).path).rstrip("/") + "/episodes"
            if (
                fragment_target.scheme != "https"
                or (fragment_target.hostname or "").lower() != "yanmaga.jp"
                or unquote(fragment_target.path).rstrip("/") != expected_path
            ):
                raise ValueError("Yanmaga 章节列表返回了不可信的翻页地址")
            fragment_response = await client.get(
                fragment_url,
                params={"offset": book.next_offset, "sort": "older"},
                headers={
                    **_request_headers(fragment_url, referer=book_url),
                    "X-Requested-With": "XMLHttpRequest",
                },
            )
            if fragment_response.status_code >= 400:
                raise ValueError(f"Yanmaga 章节列表请求失败：HTTP {fragment_response.status_code}")
            episodes.extend(parse_yanmaga_episode_fragment(fragment_response.text, book_path))

    unique_episodes = []
    seen_episode_ids: set[str] = set()
    for episode in episodes:
        if episode.id in seen_episode_ids:
            continue
        seen_episode_ids.add(episode.id)
        unique_episodes.append(episode)
    if not unique_episodes:
        raise ValueError("Yanmaga 当前没有可解析的章节目录")

    chapters = [
        ChapterPreview(
            title=episode.title,
            url=episode.url,
            accessRestricted=not episode.publicly_readable,
        )
        for episode in unique_episodes
    ]
    return PreviewResponse(
        title=book.title or payload.title or "未命名漫画",
        author=book.author,
        synopsis=book.synopsis,
        cover=book.cover,
        chapterCount=len(chapters),
        chapters=chapters,
        bookKind="漫画",
    )


async def _preview_syosetu(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    html, resolved_url = await _fetch_site_html(source_url)
    soup = BeautifulSoup(html, "html.parser")
    fallback_title = payload.title or Path(urlparse(source_url).path).stem or "未命名小说"
    title = _clean_title_suffix(_extract_title(soup, fallback_title), (" - 小説家になろう",))
    synopsis_node = soup.select_one(".p-novel__summary")
    synopsis = synopsis_node.get_text(" ", strip=True) if synopsis_node else _extract_synopsis(soup)
    author = None
    for selector in ("meta[name='twitter:creator']", ".p-novel__author", ".novel_writername"):
        node = soup.select_one(selector)
        if node is None:
            continue
        author = (
            str(node.get("content") or "").strip() if node.name == "meta" else node.get_text(" ", strip=True)
        )
        if author:
            break
    cover = _extract_cover(soup, resolved_url)
    chapters = _syosetu_chapters_from_soup(soup, resolved_url)
    if not chapters:
        chapters = [ChapterPreview(title=title, url=resolved_url)]

    return PreviewResponse(
        title=title,
        author=author,
        synopsis=synopsis,
        cover=cover,
        chapterCount=len(chapters),
        chapters=chapters,
    )


def _pixiv_comic_episode_title(episode: dict[str, Any]) -> str:
    numbering_title = str(episode.get("numbering_title") or "").strip()
    sub_title = str(episode.get("sub_title") or "").strip()
    if numbering_title and sub_title and sub_title not in numbering_title:
        return f"{numbering_title} {sub_title}"
    return numbering_title or sub_title or f"章节 {episode.get('id', '')}".strip()


def _pixiv_comic_preview_from_payloads(
    work_payload: dict[str, Any],
    episodes_payload: dict[str, Any],
    source_url: str,
) -> PreviewResponse:
    work_data = work_payload.get("data")
    work = work_data.get("official_work") if isinstance(work_data, dict) else None
    if not isinstance(work, dict):
        raise ValueError("Pixiv Comic 作品接口缺少作品信息")

    episodes_data = episodes_payload.get("data")
    episode_items = episodes_data.get("episodes") if isinstance(episodes_data, dict) else None
    if not isinstance(episode_items, list):
        raise ValueError("Pixiv Comic 章节接口缺少章节列表")

    chapters: list[ChapterPreview] = []
    seen: set[str] = set()
    for item in reversed(episode_items):
        if not isinstance(item, dict):
            continue
        episode = item.get("episode")
        if not isinstance(episode, dict):
            continue
        viewer_path = str(episode.get("viewer_path") or "").strip()
        episode_id = str(episode.get("id") or "").strip()
        chapter_url = urljoin(source_url, viewer_path or f"/viewer/stories/{episode_id}")
        if not episode_id or chapter_url in seen:
            continue
        seen.add(chapter_url)
        chapters.append(
            ChapterPreview(
                title=_pixiv_comic_episode_title(episode)[:180],
                url=chapter_url,
                accessRestricted=(
                    str(item.get("state") or "readable") != "readable"
                    or str(episode.get("state") or "readable") != "readable"
                ),
            )
        )

    if not chapters:
        raise ValueError("该 Pixiv Comic 作品当前没有可解析的章节目录")

    image = work.get("image") if isinstance(work.get("image"), dict) else {}
    description_html = str(work.get("description") or "").strip()
    synopsis = BeautifulSoup(description_html, "html.parser").get_text("\n", strip=True)
    return PreviewResponse(
        title=str(work.get("name") or "未命名漫画").strip(),
        author=str(work.get("author") or "").strip() or None,
        synopsis=synopsis,
        cover=str(image.get("main_big") or image.get("main") or "").strip() or None,
        chapterCount=len(chapters),
        chapters=chapters,
        bookKind="漫画",
    )


async def _preview_pixiv_comic(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    normalized = _normalize_source_url(source_url)
    work_id = _pixiv_comic_work_id_from_url(normalized)
    if not work_id:
        raise ValueError("无法识别 Pixiv Comic 作品编号")

    async with _build_http_client() as client:
        page_response = await client.get(normalized, headers=_request_headers(normalized))
        page_response.raise_for_status()
        _raise_if_blocked(page_response.text, normalized)
        work_payload, episodes_payload = await asyncio.gather(
            _fetch_pixiv_comic_api(
                client,
                f"https://comic.pixiv.net/api/app/works/v5/{work_id}",
                normalized,
            ),
            _fetch_pixiv_comic_api(
                client,
                f"https://comic.pixiv.net/api/app/works/{work_id}/episodes/v2",
                normalized,
            ),
        )

    result = _pixiv_comic_preview_from_payloads(work_payload, episodes_payload, normalized)
    return _apply_payload_metadata_to_preview(result, payload)


async def _preview_pixiv_artwork(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    normalized = _normalize_source_url(source_url)
    artwork_id = _pixiv_artwork_id_from_url(normalized)
    if not artwork_id:
        raise ValueError("无法识别 Pixiv 作品编号")
    async with _build_http_client() as client:
        result = await _fetch_json(
            client,
            f"https://www.pixiv.net/ajax/illust/{artwork_id}",
            _pixiv_api_headers(normalized),
        )
    body = result["body"]
    if not isinstance(body, dict):
        raise ValueError("Pixiv 插画接口返回异常")
    title = str(body.get("title") or payload.title or "未命名漫画").strip()
    urls = body.get("urls") if isinstance(body.get("urls"), dict) else {}
    cover = str(urls.get("original") or urls.get("regular") or "").strip() or None
    description_html = str(body.get("description") or "").strip()
    synopsis = BeautifulSoup(description_html, "html.parser").get_text(" ", strip=True)
    page_count = max(1, int(body.get("pageCount") or 1))
    return PreviewResponse(
        title=title,
        author=str(body.get("userName") or "").strip() or None,
        synopsis=synopsis,
        cover=cover,
        chapterCount=1,
        chapters=[ChapterPreview(title=title, url=normalized, pageCount=page_count)],
    )


async def _preview_pixiv(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    normalized = _normalize_source_url(source_url)
    async with _build_http_client() as client:
        series_id = _pixiv_series_id_from_url(normalized)
        if series_id:
            series_result = await _fetch_json(
                client,
                f"https://www.pixiv.net/ajax/novel/series/{series_id}",
                _pixiv_api_headers(normalized),
            )
            titles_result = await _fetch_json(
                client,
                f"https://www.pixiv.net/ajax/novel/series/{series_id}/content_titles",
                _pixiv_api_headers(normalized),
            )
            body = series_result["body"]
            title_items = titles_result["body"]
            if not isinstance(body, dict) or not isinstance(title_items, list):
                raise ValueError("Pixiv 系列接口返回异常")
            chapters = [
                ChapterPreview(
                    title=str(item.get("title") or f"章节 {index}"),
                    url=f"https://www.pixiv.net/novel/show.php?id={item.get('id')}",
                )
                for index, item in enumerate(title_items, start=1)
                if isinstance(item, dict) and item.get("available") and str(item.get("id") or "").strip()
            ]
            return PreviewResponse(
                title=str(body.get("title") or payload.title or "未命名小说").strip(),
                author=str(body.get("userName") or "").strip() or None,
                synopsis=str(body.get("caption") or "").strip(),
                cover=(
                    str(body.get("cover", {}).get("urls", {}).get("original") or "")
                    or str(body.get("cover", {}).get("urls", {}).get("1200x1200") or "")
                    or str(body.get("firstEpisode", {}).get("url") or "")
                    or None
                ),
                chapterCount=len(chapters),
                chapters=chapters
                or [ChapterPreview(title=str(body.get("title") or "未命名小说"), url=normalized)],
            )

        novel_id = _pixiv_novel_id_from_url(normalized)
        if not novel_id:
            raise ValueError("无法识别 Pixiv 小说编号")
        novel_result = await _fetch_json(
            client,
            f"https://www.pixiv.net/ajax/novel/{novel_id}",
            _pixiv_api_headers(normalized),
        )
        body = novel_result["body"]
        if not isinstance(body, dict):
            raise ValueError("Pixiv 小说接口返回异常")
        title = str(body.get("title") or payload.title or "未命名小说").strip()
        return PreviewResponse(
            title=title,
            author=str(body.get("userName") or "").strip() or None,
            synopsis=str(body.get("description") or "").strip(),
            cover=str(body.get("coverUrl") or "").strip() or None,
            chapterCount=1,
            chapters=[ChapterPreview(title=title, url=normalized)],
        )


async def _preview_hameln(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    html, resolved_url = await _fetch_site_html(source_url)
    soup = BeautifulSoup(html, "html.parser")
    fallback_title = payload.title or Path(urlparse(source_url).path).stem or "未命名小说"
    title = _clean_title_suffix(_extract_title(soup, fallback_title), (" - ハーメルン",))
    synopsis = _extract_synopsis(soup)
    author = _hameln_author_from_soup(soup) or _extract_author(soup)
    cover = _extract_cover(soup, resolved_url)
    chapters = _hameln_chapters_from_soup(soup, resolved_url)
    if not chapters:
        chapters = [ChapterPreview(title=title, url=resolved_url)]
    return PreviewResponse(
        title=title,
        author=author,
        synopsis=synopsis,
        cover=cover,
        chapterCount=len(chapters),
        chapters=chapters,
    )


async def _preview_novelup(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    try:
        html, resolved_url = await _fetch_site_html(source_url)
    except Exception:
        try:
            snapshot = await _fetch_with_edge_cdp(
                source_url,
                headless=True,
                ready_expression="""
                    (() => {
                        const title = document.title || '';
                        const bodyText = document.body?.innerText || '';
                        return Boolean(title) && !title.includes('ERROR: The request could not be satisfied') && !bodyText.includes('403 ERROR');
                    })()
                """,
                blocked_message="Novelup 当前访问被 CloudFront 拦截（403），当前环境下即使使用浏览器会话也无法直接访问该站点。",
            )
            html, resolved_url = snapshot.html, snapshot.resolved_url
        except Exception as browser_exc:
            raise ValueError(
                "Novelup 当前访问被 CloudFront 拦截（403），当前环境下即使使用浏览器会话也无法直接访问该站点。"
            ) from browser_exc
    soup = BeautifulSoup(html, "html.parser")
    fallback_title = payload.title or Path(urlparse(source_url).path).stem or "未命名小说"
    title = _extract_title(soup, fallback_title)
    chapters = _extract_chapters(soup, resolved_url) or [ChapterPreview(title=title, url=resolved_url)]
    return PreviewResponse(
        title=title,
        author=_extract_author(soup),
        synopsis=_extract_synopsis(soup),
        cover=_extract_cover(soup, resolved_url),
        chapterCount=len(chapters),
        chapters=chapters,
    )


async def _fetch_alphapolis_preview_html(source_url: str) -> tuple[str, str]:
    snapshot = await _fetch_with_edge_cdp(
        source_url,
        headless=True,
        ready_expression="""
            (() => {
                const html = document.documentElement.outerHTML || '';
                return Boolean(document.querySelector('#app-cover-data')) && !html.includes('window.gokuProps');
            })()
        """,
        blocked_message="Alphapolis 当前浏览器会话仍被 AWS WAF 拦截，暂时无法抓取该作品目录。",
    )
    return snapshot.html, snapshot.resolved_url


async def _fetch_alphapolis_chapter_html(chapter_url: str) -> tuple[str, str]:
    snapshot = await _fetch_with_edge_cdp(
        chapter_url,
        headless=False,
        ready_expression="""
            (() => {
                const html = document.documentElement.outerHTML || '';
                if (html.includes('window.gokuProps')) return false;
                const body = document.querySelector('#novelBody');
                if (!body) return false;
                const inner = body.innerHTML || '';
                const text = body.innerText || '';
                const imageCount = body.querySelectorAll('img').length;
                const blocked = inner.includes('g-recaptcha') || inner.includes('LoadingEpisode');
                return !blocked && (text.trim().length >= 20 || imageCount > 0);
            })()
        """,
        blocked_message="Alphapolis 章节正文当前仍然触发验证码或防护，暂时无法自动抓取。",
    )
    return snapshot.html, snapshot.resolved_url


async def _preview_alphapolis(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    html, resolved_url = await _fetch_alphapolis_preview_html(source_url)
    soup = BeautifulSoup(html, "html.parser")
    cover_data = _alphapolis_cover_data_from_html(html)
    content = cover_data.get("content") if isinstance(cover_data.get("content"), dict) else {}
    fallback_title = payload.title or Path(urlparse(source_url).path).stem or "未命名小说"
    title = str(content.get("title") or "").strip() or _clean_title_suffix(
        _extract_title(soup, fallback_title),
        (" | 小説投稿サイトのアルファポリス",),
    )
    author = None
    user = content.get("user") if isinstance(content, dict) else None
    if isinstance(user, dict):
        author = str(user.get("name") or "").strip() or None
    if not author:
        author = _extract_author(soup)
    cover = str(content.get("coverImageUrl") or "").strip() if isinstance(content, dict) else ""
    cover = urljoin(resolved_url, cover) if cover else _extract_cover(soup, resolved_url)
    chapters = _alphapolis_chapters_from_cover_data(cover_data, resolved_url) or [
        ChapterPreview(title=title, url=resolved_url)
    ]
    return PreviewResponse(
        title=title,
        author=author,
        synopsis=_extract_synopsis(soup),
        cover=cover,
        chapterCount=len(chapters),
        chapters=chapters,
    )


async def _preview_fanqie(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    html, resolved_url = await _fetch_fanqie_html(source_url)
    book = parse_fanqie_book_page(html, resolved_url)
    return PreviewResponse(
        title=book.title,
        author=book.author,
        synopsis=book.synopsis,
        cover=book.cover_url,
        chapterCount=len(book.chapters),
        chapters=[
            ChapterPreview(
                title=chapter.title,
                url=chapter.url,
                accessRestricted=chapter.is_locked,
            )
            for chapter in book.chapters
        ],
    )


async def _preview_qidian(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    book_id = qidian_book_id_from_url(source_url)
    if not book_id:
        raise ValueError("起点链接缺少有效作品 ID，请使用作品页或章节页链接")
    book_info, catalog = await asyncio.gather(
        asyncio.to_thread(get_qidian_book_info, book_id),
        asyncio.to_thread(get_qidian_catalog, book_id),
    )
    chapters = [
        ChapterPreview(
            title=str(chapter.get("chapterName") or "未命名章节"),
            url=canonical_qidian_chapter_url(book_id, str(chapter["chapterId"])),
            accessRestricted=bool(chapter.get("isVip")),
        )
        for volume in catalog.get("volumes") or []
        if isinstance(volume, dict)
        for chapter in volume.get("chapters") or []
        if isinstance(chapter, dict) and str(chapter.get("chapterId") or "").isdigit()
    ]
    if not chapters:
        raise ValueError("起点作品目录为空")
    synopsis_html = str(book_info.get("desc") or "")
    synopsis = BeautifulSoup(synopsis_html, "html.parser").get_text("\n", strip=True)
    category = str(book_info.get("chanName") or "")
    book_kind = "轻小说" if "轻小说" in category else payload.bookKind
    return PreviewResponse(
        title=str(book_info.get("bookName") or catalog.get("bookName") or "未命名作品"),
        author=str(book_info.get("authorName") or "").strip() or None,
        synopsis=synopsis,
        cover=None,
        chapterCount=len(chapters),
        chapters=chapters,
        bookKind=book_kind,
    )


async def _preview_quark(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    book_id = quark_book_id_from_url(source_url)
    if not book_id:
        raise ValueError("夸克小说链接缺少有效作品 ID，请使用书旗作品页或阅读页链接")
    async with _build_http_client() as client:
        book_info, catalog_result = await asyncio.gather(
            get_quark_book_info(client, book_id),
            get_quark_catalog(client, book_id),
        )
    chapters_info, chapter_items = catalog_result
    if book_info.get("hide") is True or book_info.get("readIsOpen") is False:
        raise ValueError("该夸克小说作品当前未公开阅读")
    chapters = [
        ChapterPreview(
            title=str(chapter.get("chapterName") or "未命名章节").strip(),
            url=canonical_quark_chapter_url(book_id, str(chapter["chapterId"])),
            accessRestricted=not quark_chapter_is_public(chapter),
        )
        for chapter in chapter_items
    ]
    cover = str(book_info.get("imgUrl") or "").strip() or None
    if cover and cover.startswith("http://"):
        cover = f"https://{cover.removeprefix('http://')}"
    return PreviewResponse(
        title=str(
            book_info.get("bookName") or chapters_info.get("bookName") or payload.title or "未命名作品"
        ).strip(),
        author=str(book_info.get("authorName") or chapters_info.get("authorName") or "").strip() or None,
        synopsis=str(book_info.get("desc") or "").strip(),
        cover=cover,
        chapterCount=len(chapters),
        chapters=chapters,
        bookKind="长小说",
    )


async def _preview_biqvge(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    async with _build_http_client() as client:
        book = await get_biqvge_book(client, source_url)
    chapters = [
        ChapterPreview(
            title=str(chapter.get("title") or "未命名章节"),
            url=str(chapter["url"]),
            accessRestricted=bool(chapter.get("access_restricted")),
        )
        for chapter in book.get("chapters") or []
        if isinstance(chapter, dict) and str(chapter.get("url") or "").strip()
    ]
    if not chapters:
        raise ValueError("笔趣阁作品目录为空")
    return PreviewResponse(
        title=str(book.get("title") or payload.title or "未命名作品").strip(),
        author=str(book.get("author") or "").strip() or None,
        synopsis=str(book.get("synopsis") or "").strip(),
        cover=str(book.get("cover") or "").strip() or None,
        chapterCount=len(chapters),
        chapters=chapters,
        bookKind="长小说",
    )


async def _preview_copymanga(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    path_word = mangacopy_path_word_from_url(source_url)
    if not path_word:
        raise ValueError("无法识别拷贝漫画作品路径，请提交 /comic/{作品标识} 链接")
    async with _build_http_client() as client:
        detail = await get_mangacopy_detail(client, path_word)
        comic = detail.get("comic")
        if not isinstance(comic, dict):
            raise ValueError("拷贝漫画作品详情缺少 comic 数据")
        chapter_items = await get_mangacopy_chapters(client, path_word, detail.get("groups"))

    chapters: list[ChapterPreview] = []
    for item in chapter_items:
        chapter_id = str(item.get("uuid") or "").strip()
        title = str(item.get("name") or "未命名章节").strip()
        group_name = str(item.get("_group_name") or "").strip()
        if group_name and group_name not in {"默认", "默認", "default"}:
            title = f"{group_name} - {title}"
        try:
            page_count = max(0, int(item.get("size") or 0))
        except (TypeError, ValueError):
            page_count = 0
        chapters.append(
            ChapterPreview(
                title=title,
                url=canonical_mangacopy_chapter_url(path_word, chapter_id),
                pageCount=page_count,
            )
        )
    if not chapters:
        raise ValueError("拷贝漫画作品目录为空")

    raw_authors = comic.get("author")
    authors = (
        [
            str(author.get("name") or "").strip()
            for author in raw_authors
            if isinstance(author, dict) and str(author.get("name") or "").strip()
        ]
        if isinstance(raw_authors, list)
        else []
    )
    return PreviewResponse(
        title=str(comic.get("name") or payload.title or path_word).strip(),
        author="、".join(authors) or None,
        synopsis=str(comic.get("brief") or "").strip(),
        cover=str(comic.get("cover") or "").strip() or None,
        chapterCount=len(chapters),
        chapters=chapters,
        bookKind="漫画",
    )


async def _preview_comicores(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    book_key = comicores_book_key_from_url(source_url)
    if not book_key:
        raise ValueError("无法识别 COMICORES 作品链接")
    async with _build_http_client() as client:
        post = await get_comicores_book(client, book_key)
    title = comicores_title(post) or payload.title or book_key
    synopsis = comicores_synopsis(post)
    boundary = "解析说明：当前解析器只提供作品元数据与搜索，尚未实现章节资源解析。"
    return PreviewResponse(
        title=title,
        author="、".join(comicores_authors(post)) or None,
        synopsis=f"{synopsis}\n\n{boundary}" if synopsis else boundary,
        cover=comicores_cover(post),
        chapterCount=0,
        chapters=[],
        bookKind="漫画",
    )


async def _preview_ciweimao(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    book_id = ciweimao_book_id_from_url(source_url)
    if not book_id:
        raise ValueError("无法识别刺猬猫作品链接，请提交 /book/{id} 地址")
    async with _build_http_client() as client:
        book = await get_ciweimao_book(client, book_id)
        catalogue = await get_ciweimao_catalogue(client, book_id)
    chapters = [
        ChapterPreview(
            title=str(item["title"]),
            url=str(item["url"]),
            accessRestricted=bool(item.get("access_restricted")),
        )
        for item in catalogue
    ]
    return PreviewResponse(
        title=str(book.get("title") or payload.title or f"刺猬猫作品 {book_id}"),
        author=str(book.get("author") or "").strip() or None,
        synopsis=str(book.get("description") or "").strip(),
        cover=str(book.get("cover") or "").strip() or None,
        chapterCount=len(chapters),
        chapters=chapters,
        bookKind="轻小说",
    )


async def _preview_shaoniandream(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    book_id = shaoniandream_book_id_from_url(source_url)
    if not book_id:
        raise ValueError("无法识别少年梦作品链接，请提交 /book_detail/{id} 地址")
    async with _build_http_client() as client:
        book = await get_shaoniandream_book(client, book_id)
        catalogue = await get_shaoniandream_catalogue(client, book_id)
    chapters = [
        ChapterPreview(
            title=str(item["title"]),
            url=str(item["url"]),
            accessRestricted=bool(item.get("access_restricted")),
        )
        for item in catalogue
    ]
    return PreviewResponse(
        title=str(book.get("title") or payload.title or f"少年梦作品 {book_id}"),
        author=str(book.get("author") or "").strip() or None,
        synopsis=str(book.get("synopsis") or "").strip(),
        cover=str(book.get("cover") or "").strip() or None,
        chapterCount=len(chapters),
        chapters=chapters,
        bookKind="长小说",
    )


async def _preview_sfacg(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    novel_id = sfacg_book_id_from_url(source_url)
    if not novel_id:
        raise ValueError("无法识别 SF 轻小说作品链接，请提交 /Novel/{id} 地址")
    async with _build_http_client() as client:
        raw_book = await get_sfacg_book(client, novel_id)
        catalogue = await get_sfacg_catalogue(client, novel_id)
    book = normalize_sfacg_book(raw_book)
    chapters = [
        ChapterPreview(
            title=str(item["title"]),
            url=str(item["url"]),
            accessRestricted=bool(item.get("access_restricted")),
        )
        for item in catalogue
    ]
    return PreviewResponse(
        title=str(book.get("title") or payload.title or f"SF 轻小说 {novel_id}"),
        author=str(book.get("author") or "").strip() or None,
        synopsis=str(book.get("synopsis") or "").strip(),
        cover=str(book.get("cover") or "").strip() or None,
        chapterCount=len(chapters),
        chapters=chapters,
        bookKind="轻小说",
    )


async def _preview_ehentai(source_url: str, payload: AddBookPayload) -> PreviewResponse:
    gallery_ids = ehentai_gallery_ids_from_url(source_url)
    if not gallery_ids:
        raise ValueError("无法识别 E-Hentai 画廊链接，请提交 /g/{gid}/{token}/ 地址")
    gid, token = gallery_ids
    async with _build_http_client() as client:
        metadata = await get_ehentai_gallery_metadata(client, gid, token)
        page = await get_ehentai_gallery_page(client, source_url)
    title = str(metadata.get("title") or payload.title or f"E-Hentai Gallery {gid}")
    details = [
        str(metadata.get("category") or "").strip(),
        str(page.get("description") or "").strip(),
    ]
    tags = [str(item) for item in metadata.get("tags") or []]
    if tags:
        details.append("标签：" + "、".join(tags[:20]))
    filecount = int(metadata.get("filecount") or page.get("filecount") or 0)
    chapter = ChapterPreview(title=title, url=source_url, pageCount=filecount)
    return PreviewResponse(
        title=title,
        author=str(metadata.get("author") or page.get("uploader") or "").strip() or None,
        synopsis="\n\n".join(item for item in details if item),
        cover=str(metadata.get("cover") or "").strip() or None,
        chapterCount=1,
        chapters=[chapter],
        bookKind="漫画",
    )


async def preview_from_url(payload: AddBookPayload) -> PreviewResponse:
    source_url = _normalize_source_url(str(payload.sourceUrl))
    plugin = _require_enabled_site_plugin(source_url)
    result: PreviewResponse
    if plugin.preview_handler == "fanqie":
        result = await _preview_fanqie(source_url, payload)
        result = result.model_copy(update={"bookKind": _resolved_preview_book_kind(source_url, payload)})
        return _apply_payload_metadata_to_preview(result, payload)
    if plugin.preview_handler == "qidian":
        result = await _preview_qidian(source_url, payload)
        return _apply_payload_metadata_to_preview(result, payload)
    if plugin.preview_handler == "quark":
        result = await _preview_quark(source_url, payload)
        return _apply_payload_metadata_to_preview(result, payload)
    if plugin.preview_handler == "biqvge":
        result = await _preview_biqvge(source_url, payload)
        return _apply_payload_metadata_to_preview(result, payload)
    if plugin.preview_handler == "18comic":
        result = await _preview_18comic(source_url, payload)
        return result.model_copy(update={"bookKind": _resolved_preview_book_kind(source_url, payload)})
    if plugin.preview_handler == "bika":
        result = await _preview_bika(source_url, payload)
        return result.model_copy(update={"bookKind": _resolved_preview_book_kind(source_url, payload)})
    if plugin.preview_handler == "copymanga":
        return await _preview_copymanga(source_url, payload)
    if plugin.preview_handler == "comicores":
        return await _preview_comicores(source_url, payload)
    if plugin.preview_handler == "ciweimao":
        return await _preview_ciweimao(source_url, payload)
    if plugin.preview_handler == "shaoniandream":
        return await _preview_shaoniandream(source_url, payload)
    if plugin.preview_handler == "sfacg":
        return await _preview_sfacg(source_url, payload)
    if plugin.preview_handler == "ehentai":
        return await _preview_ehentai(source_url, payload)
    if plugin.preview_handler == "pixiv_comic":
        if not _is_pixiv_comic_work_url(source_url):
            raise ValueError("Pixiv Comic 章节链接不是作品页，请提交作品链接")
        result = await _preview_pixiv_comic(source_url, payload)
        return result.model_copy(update={"bookKind": _resolved_preview_book_kind(source_url, payload)})
    if plugin.preview_handler == "pixiv":
        if _is_pixiv_manga_url(source_url):
            result = await _preview_pixiv_artwork(source_url, payload)
        else:
            result = await _preview_pixiv(source_url, payload)
        return result.model_copy(update={"bookKind": _resolved_preview_book_kind(source_url, payload)})
    if plugin.preview_handler == "kakuyomu":
        result = await _preview_kakuyomu(source_url, payload)
        return result.model_copy(update={"bookKind": _resolved_preview_book_kind(source_url, payload)})
    if plugin.preview_handler == "yanmaga":
        result = await _preview_yanmaga(source_url, payload)
        return result.model_copy(update={"bookKind": _resolved_preview_book_kind(source_url, payload)})
    if plugin.preview_handler == "syosetu":
        result = await _preview_syosetu(source_url, payload)
        return result.model_copy(update={"bookKind": _resolved_preview_book_kind(source_url, payload)})
    if plugin.preview_handler == "hameln":
        result = await _preview_hameln(source_url, payload)
        return result.model_copy(update={"bookKind": _resolved_preview_book_kind(source_url, payload)})
    if plugin.preview_handler == "novelup":
        result = await _preview_novelup(source_url, payload)
        return result.model_copy(update={"bookKind": _resolved_preview_book_kind(source_url, payload)})
    if plugin.preview_handler == "alphapolis":
        result = await _preview_alphapolis(source_url, payload)
        return result.model_copy(update={"bookKind": _resolved_preview_book_kind(source_url, payload)})

    html, resolved_url = await _fetch_preview_html(source_url)
    json_preview = _preview_from_json_text(html, resolved_url, payload)
    if json_preview is not None:
        result = json_preview.model_copy(
            update={"bookKind": _resolved_preview_book_kind(source_url, payload)}
        )
        json_payload = _json_payload_from_text(html)
        if json_payload is not None:
            async with _build_http_client() as client:
                result = await _extend_json_preview_chapters(client, result, json_payload, resolved_url)
        return _apply_payload_metadata_to_preview(result, payload)

    soup = BeautifulSoup(html, "html.parser")
    fallback_title = payload.title or Path(urlparse(source_url).path).stem or "未命名小说"
    title = _extract_title(soup, fallback_title)
    synopsis = _extract_synopsis(soup)
    author = _extract_author(soup)
    cover = _extract_cover(soup, resolved_url)
    chapters = _extract_chapters(soup, resolved_url)

    if not chapters:
        chapters = [ChapterPreview(title=title, url=resolved_url)]

    result = PreviewResponse(
        title=title,
        author=author,
        synopsis=synopsis,
        cover=cover,
        chapterCount=len(chapters),
        chapters=chapters,
    )
    result = result.model_copy(update={"bookKind": _resolved_preview_book_kind(source_url, payload)})
    return _apply_payload_metadata_to_preview(result, payload)


async def download_book(
    payload: AddBookPayload,
    preview: PreviewResponse,
    root_dir: Path,
    *,
    qidian_cookies: dict[str, str] | None = None,
) -> DownloadResult:
    safe_title = re.sub(r'[\/:*?"<>|]', "_", preview.title).strip() or "未命名小说"
    book_dir = root_dir / payload.language / safe_title
    book_dir.mkdir(parents=True, exist_ok=True)
    chapter_manifest: list[dict[str, Any]] = []
    runtime_settings = _load_runtime_settings()
    image_download_semaphore = asyncio.Semaphore(
        _image_download_concurrency(str(payload.sourceUrl), runtime_settings.downloadConcurrency)
    )

    async with _build_http_client() as client:
        try:
            cover_file = await _download_cover_image(client, book_dir, preview.cover, str(payload.sourceUrl))
        except Exception:
            cover_file = None
        if preview.chapters and _is_linovelib_url(preview.chapters[0].url):
            await _prime_linovelib_session(client, preview.chapters[0].url)
        for index, chapter in enumerate(preview.chapters, start=1):
            safe_chapter_title = re.sub(r'[\\/:*?"<>|]', "_", chapter.title)[:80]
            filename = f"{index:04d}-{safe_chapter_title}.txt"
            result: ChapterFetchResult | None = None
            image_files: list[str] = []
            download_error: str | None = None
            try:
                if qidian_cookies is None:
                    result = await _fetch_chapter_data(client, chapter.url, chapter.title)
                else:
                    result = await _fetch_chapter_data(
                        client,
                        chapter.url,
                        chapter.title,
                        qidian_cookies=qidian_cookies,
                    )
                image_files = await _download_chapter_images(
                    client,
                    book_dir,
                    index,
                    result.image_urls,
                    chapter.url,
                    image_download_semaphore=image_download_semaphore,
                )
            except Exception as exc:
                if _is_manga_source_url(chapter.url):
                    raise RuntimeError(f"漫画章节下载失败：{chapter.title}：{exc}") from exc
                if _is_fanqie_url(chapter.url):
                    download_error = str(exc)
                    result = None
                else:
                    result = ChapterFetchResult(
                        text=f"章节抓取失败：{exc}\n原始链接：{chapter.url}",
                        image_urls=[],
                        illustration=False,
                    )

            if result is not None:
                (book_dir / filename).write_text(result.text, encoding="utf-8")
            chapter_manifest.append(
                {
                    "index": index,
                    "title": chapter.title,
                    "url": chapter.url,
                    "file_name": filename,
                    "downloaded": result is not None,
                    "translated": False,
                    "translated_file_name": None,
                    "translated_meta_file_name": None,
                    "illustration": result.illustration if result is not None else False,
                    "image_urls": result.image_urls if result is not None else [],
                    "image_files": image_files,
                    "translated_image_files": [],
                    "page_count": chapter.pageCount
                    or len(image_files)
                    or (len(result.image_urls) if result is not None else 0),
                    "images_repaired": _is_18comic_url(chapter.url),
                    "content_source": result.content_source if result is not None else None,
                    "authorization_method": (result.authorization_method if result is not None else None),
                    "access_restricted": chapter.accessRestricted,
                    "download_error": download_error,
                }
            )

    manifest = {
        "title": preview.title,
        "author": preview.author,
        "source_url": str(payload.sourceUrl),
        "book_kind": preview.bookKind,
        "language": payload.language,
        "need_translation": payload.needTranslation,
        "synopsis": preview.synopsis,
        "cover_url": preview.cover,
        "cover_file": cover_file,
        "download_mode": "all",
        "chapter_count": len(chapter_manifest),
        "chapters": chapter_manifest,
    }
    save_manifest(book_dir, manifest)

    return DownloadResult(
        title=preview.title,
        synopsis=preview.synopsis,
        cover=cover_file or preview.cover,
        chapters=preview.chapters,
        local_path=book_dir,
    )


async def create_book_manifest_only(
    payload: AddBookPayload, preview: PreviewResponse, root_dir: Path
) -> DownloadResult:
    safe_title = re.sub(r'[\/:*?"<>|]', "_", preview.title).strip() or "未命名小说"
    book_dir = root_dir / payload.language / safe_title
    book_dir.mkdir(parents=True, exist_ok=True)
    chapter_manifest: list[dict[str, Any]] = []

    async with _build_http_client() as client:
        try:
            cover_file = await _download_cover_image(client, book_dir, preview.cover, str(payload.sourceUrl))
        except Exception:
            cover_file = None

    for index, chapter in enumerate(preview.chapters, start=1):
        safe_chapter_title = re.sub(r'[\\/:*?"<>|]', "_", chapter.title)[:80]
        filename = f"{index:04d}-{safe_chapter_title}.txt"
        chapter_manifest.append(
            {
                "index": index,
                "title": chapter.title,
                "url": chapter.url,
                "file_name": filename,
                "downloaded": False,
                "translated": False,
                "translated_file_name": None,
                "translated_meta_file_name": None,
                "illustration": False,
                "image_urls": [],
                "image_files": [],
                "translated_image_files": [],
                "page_count": chapter.pageCount,
                "images_repaired": False,
                "content_source": None,
                "authorization_method": None,
                "access_restricted": chapter.accessRestricted,
                "download_error": None,
            }
        )

    manifest = {
        "title": preview.title,
        "author": preview.author,
        "source_url": str(payload.sourceUrl),
        "book_kind": preview.bookKind,
        "language": payload.language,
        "need_translation": payload.needTranslation,
        "synopsis": preview.synopsis,
        "cover_url": preview.cover,
        "cover_file": cover_file,
        "download_mode": "on_demand",
        "chapter_count": len(chapter_manifest),
        "chapters": chapter_manifest,
    }
    save_manifest(book_dir, manifest)

    return DownloadResult(
        title=preview.title,
        synopsis=preview.synopsis,
        cover=cover_file or preview.cover,
        chapters=preview.chapters,
        local_path=book_dir,
    )


def _chapter_lookup(manifest: dict) -> dict[int, dict]:
    chapters = manifest.get("chapters", [])
    if not isinstance(chapters, list):
        return {}

    lookup: dict[int, dict] = {}
    for item in chapters:
        if not isinstance(item, dict):
            continue
        chapter_index = item.get("index")
        if isinstance(chapter_index, int):
            lookup[chapter_index] = item
    return lookup


def _extract_text_from_blocks(nodes: list[BeautifulSoup]) -> str:
    blocks: list[str] = []
    for node in nodes:
        text = node.get_text("\n", strip=True)
        if not text:
            continue
        blocks.append(text)
    return "\n\n".join(block.strip() for block in blocks if block.strip()).strip()


async def _fetch_kakuyomu_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str = "",
) -> ChapterFetchResult:
    response = await _get_html_response(client, chapter_url, referer=chapter_url)
    parsed = parse_kakuyomu_episode_page(response.text)
    image_urls = [urljoin(str(response.url), source) for source in parsed.image_sources]
    text = parsed.text
    illustration = _is_illustration_chapter(chapter_title)
    if not text and image_urls:
        text = _format_illustration_text(chapter_title or "插图", image_urls)
        illustration = True
    elif image_urls and illustration:
        text = _append_image_links(text, image_urls)
    return ChapterFetchResult(text=text, image_urls=image_urls, illustration=illustration)


def _yanmaga_viewer_content_id(viewer_url: str, book_path: str, episode_id: str) -> str:
    parsed = urlparse(viewer_url)
    parts = [unquote(part) for part in parsed.path.strip("/").split("/") if part]
    if (
        parsed.scheme != "https"
        or (parsed.hostname or "").lower() != "yanmaga.jp"
        or parts != ["viewer", "comics", book_path, episode_id]
    ):
        raise ValueError("Yanmaga 章节没有跳转到同作品、同章节的官方 Viewer")
    content_id = parse_qs(parsed.query).get("cid", [""])[0].strip()
    if not content_id:
        raise ValueError("Yanmaga 章节没有返回当前解析器可用的 Viewer 内容标识")
    return content_id


def _validated_yanmaga_contents_server(value: Any) -> str:
    server = str(value or "").strip().rstrip("/")
    parsed = urlparse(server)
    if (
        parsed.scheme != "https"
        or (parsed.hostname or "").lower() not in YANMAGA_CONTENT_HOSTS
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("Yanmaga Viewer 返回了不可信的内容服务器")
    return server


async def _fetch_yanmaga_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str = "",
) -> ChapterFetchResult:
    resource = yanmaga_resource_from_url(chapter_url)
    if resource is None or resource[1] is None:
        raise ValueError("Yanmaga 章节链接格式无效")
    book_path, episode_id = resource
    canonical_url = canonical_yanmaga_url(book_path, episode_id)
    response = await client.get(
        canonical_url,
        headers=_request_headers(canonical_url),
        follow_redirects=False,
    )
    if response.status_code not in {301, 302, 303, 307, 308}:
        if response.status_code >= 400:
            raise ValueError(f"Yanmaga 章节页请求失败：HTTP {response.status_code}")
        raise ValueError("Yanmaga 章节当前未向匿名访问跳转到 Viewer")
    viewer_url = urljoin(canonical_url, str(response.headers.get("Location") or ""))
    content_id = _yanmaga_viewer_content_id(viewer_url, book_path, episode_id)

    request_time = int(time.time() * 1000)
    request_key = speedbinb_request_key(content_id, request_time)
    info_response = await client.get(
        f"{YANMAGA_VIEWER_ORIGIN}/bibGetCntntInfo",
        params={
            "random_identification": episode_id,
            "type": "comics",
            "cid": content_id,
            "k": request_key,
            "dmytime": str(request_time),
        },
        headers={
            **_request_headers(viewer_url, referer=viewer_url),
            "Accept": "application/json, text/plain, */*",
        },
    )
    if info_response.status_code >= 400:
        raise ValueError(f"Yanmaga Viewer 内容信息请求失败：HTTP {info_response.status_code}")
    try:
        info_payload = info_response.json()
    except json.JSONDecodeError as exc:
        raise ValueError("Yanmaga Viewer 内容信息不是 JSON") from exc
    if not isinstance(info_payload, dict):
        raise ValueError("Yanmaga Viewer 内容信息格式无效")
    items = info_payload.get("items")
    if info_payload.get("result") != 1 or not isinstance(items, list) or not items:
        raise ValueError("Yanmaga Viewer 未返回可解析的章节内容")
    item = items[0]
    if not isinstance(item, dict):
        raise ValueError("Yanmaga Viewer 内容信息格式无效")
    if int(item.get("ServerType") or 2) != 2:
        raise ValueError("Yanmaga Viewer 返回了当前不支持的内容服务器类型")

    content_table = decode_speedbinb_table(content_id, request_key, str(item.get("ctbl") or ""))
    position_table = decode_speedbinb_table(content_id, request_key, str(item.get("ptbl") or ""))
    contents_server = _validated_yanmaga_contents_server(item.get("ContentsServer"))
    content_response = await client.get(
        f"{contents_server}/content",
        params={"dmytime": str(item.get("ContentDate"))} if item.get("ContentDate") else None,
        headers={"Referer": viewer_url, "Origin": YANMAGA_ORIGIN, "Accept": "application/json"},
    )
    if content_response.status_code >= 400:
        raise ValueError(f"Yanmaga Viewer 页面列表请求失败：HTTP {content_response.status_code}")
    try:
        content_payload = content_response.json()
    except json.JSONDecodeError as exc:
        raise ValueError("Yanmaga Viewer 页面列表不是 JSON") from exc
    if not isinstance(content_payload, dict):
        raise ValueError("Yanmaga Viewer 页面列表格式无效")

    ttx = html.unescape(str(content_payload.get("ttx") or ""))
    image_sources = re.findall(r'<t-img[^>]*?src\s*=\s*["\']([^"\']+)["\']', ttx)
    if not image_sources:
        raise ValueError("Yanmaga Viewer 未返回漫画页面")

    content_date = str(content_payload.get("ContentDate") or item.get("ContentDate") or "").strip()
    image_base = f"{contents_server}/img/"
    image_base_path = urlparse(image_base).path
    image_urls: list[str] = []
    for source in image_sources:
        source_url = urlparse(source)
        if source_url.scheme or source_url.netloc or source.startswith("/") or ".." in source.split("/"):
            raise ValueError("Yanmaga Viewer 返回了不可信的页面图片地址")
        image_url = urljoin(image_base, source)
        image_target = urlparse(image_url)
        if (
            image_target.scheme != "https"
            or (image_target.hostname or "").lower() not in YANMAGA_CONTENT_HOSTS
            or not image_target.path.startswith(image_base_path)
        ):
            raise ValueError("Yanmaga Viewer 页面图片越出允许的内容服务器路径")
        query = {"q": "1"}
        if content_date:
            query["dmytime"] = content_date
        image_url = str(httpx.URL(image_url).copy_merge_params(query))
        position_key, content_key = speedbinb_page_keys(source, content_table, position_table)
        _YANMAGA_PAGE_KEYS[image_url] = (position_key, content_key, viewer_url)
        image_urls.append(image_url)

    title = chapter_title.strip() or str(item.get("Title") or "Yanmaga 漫画").strip()
    return ChapterFetchResult(
        text=_manga_placeholder_text(title, len(image_urls)),
        image_urls=image_urls,
        illustration=False,
        content_source="yanmaga_viewer",
        authorization_method="upstream-viewer",
        access_restricted=False,
    )


async def _fetch_syosetu_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str = "",
) -> ChapterFetchResult:
    html, resolved_url = await _fetch_site_html(chapter_url, referer=_normalize_source_url(chapter_url))
    soup = BeautifulSoup(html, "html.parser")
    blocks = soup.select(".p-novel__text")
    if not blocks:
        body = soup.select_one("#novel_honbun")
        if body is not None:
            blocks = [body]
    text = _extract_text_from_blocks(blocks)
    if not text:
        raise ValueError("未能从成为小说家吧页面提取出正文内容")
    return ChapterFetchResult(text=text, image_urls=[], illustration=False)


async def _fetch_hameln_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str = "",
) -> ChapterFetchResult:
    html, _ = await _fetch_site_html(chapter_url, referer=_normalize_source_url(chapter_url))
    soup = BeautifulSoup(html, "html.parser")
    text = _hameln_chapter_text(soup)
    if not text:
        raise ValueError("未能从 Hameln 页面提取出正文内容")
    return ChapterFetchResult(text=text, image_urls=[], illustration=False)


async def _fetch_pixiv_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str = "",
) -> ChapterFetchResult:
    novel_id = _pixiv_novel_id_from_url(chapter_url)
    if not novel_id:
        raise ValueError("无法识别 Pixiv 小说编号")
    payload = await _fetch_json(
        client, f"https://www.pixiv.net/ajax/novel/{novel_id}", _pixiv_api_headers(chapter_url)
    )
    body = payload["body"]
    if not isinstance(body, dict):
        raise ValueError("Pixiv 小说接口返回异常")
    text = _pixiv_content_to_text(str(body.get("content") or ""))
    image_urls = _extract_pixiv_image_urls(body)
    illustration = _is_illustration_chapter(chapter_title)
    if not text and image_urls:
        text = _format_illustration_text(chapter_title or str(body.get("title") or "插图"), image_urls)
        illustration = True
    elif image_urls and illustration:
        text = _append_image_links(text, image_urls)
    if not text:
        raise ValueError("未能从 Pixiv 页面提取出正文内容")
    return ChapterFetchResult(text=text, image_urls=image_urls, illustration=illustration)


def _pixiv_comic_page_props(html: str) -> dict[str, Any]:
    script = BeautifulSoup(html, "html.parser").select_one("#__NEXT_DATA__")
    if script is None or not script.string:
        raise ValueError("Pixiv Comic 阅读页缺少 __NEXT_DATA__ 数据")
    payload = json.loads(script.string)
    page_props = payload.get("props", {}).get("pageProps", {})
    if not isinstance(page_props, dict):
        raise ValueError("Pixiv Comic 阅读页数据结构异常")
    return page_props


def _pixiv_comic_read_headers(salt: str) -> dict[str, str]:
    client_time = datetime.now().astimezone().isoformat(timespec="seconds")
    client_hash = sha256(f"{client_time}{salt}".encode()).hexdigest()
    return {
        "X-Client-Time": client_time,
        "X-Client-Hash": client_hash,
    }


def _rotate_left_uint32(value: int, count: int) -> int:
    normalized_count = count % 32
    return (((value << normalized_count) & 0xFFFFFFFF) | (value >> (32 - normalized_count))) & 0xFFFFFFFF


class _PixivComicRandom:
    def __init__(self, seed: list[int]) -> None:
        if len(seed) != 4:
            raise ValueError("Pixiv Comic 图片随机数种子长度异常")
        self._state = [value & 0xFFFFFFFF for value in seed]
        if not any(self._state):
            self._state[0] = 1

    def next(self) -> int:
        state = self._state
        result = (9 * _rotate_left_uint32((5 * state[1]) & 0xFFFFFFFF, 7)) & 0xFFFFFFFF
        shifted = (state[1] << 9) & 0xFFFFFFFF
        state[2] = (state[2] ^ state[0]) & 0xFFFFFFFF
        state[3] = (state[3] ^ state[1]) & 0xFFFFFFFF
        state[1] = (state[1] ^ state[2]) & 0xFFFFFFFF
        state[0] = (state[0] ^ state[3]) & 0xFFFFFFFF
        state[2] = (state[2] ^ shifted) & 0xFFFFFFFF
        state[3] = _rotate_left_uint32(state[3], 11)
        return result


def _pixiv_comic_reverse_shuffle_tables(
    width: int,
    height: int,
    grid_size: int,
    key: str,
) -> list[list[int]]:
    seed_material = f"4wXCKprMMoxnyJ3PocJFs4CYbfnbazNe{key}".encode()
    digest = sha256(seed_material).digest()
    random = _PixivComicRandom(
        [int.from_bytes(digest[index : index + 4], "little") for index in range(0, 16, 4)]
    )
    for _ in range(100):
        random.next()

    column_count = width // grid_size
    row_count = (height + grid_size - 1) // grid_size
    tables: list[list[int]] = []
    for _ in range(row_count):
        shuffled = list(range(column_count))
        for index in range(column_count - 1, 0, -1):
            destination = random.next() % (index + 1)
            shuffled[index], shuffled[destination] = shuffled[destination], shuffled[index]
        tables.append([shuffled.index(index) for index in range(column_count)])
    return tables


def _pixiv_comic_descramble_bytes(image_bytes: bytes, key: str, grid_size: int) -> bytes:
    if not key or grid_size <= 0:
        return image_bytes
    try:
        with Image.open(BytesIO(image_bytes)) as image:
            source = image.convert("RGBA")
    except UnidentifiedImageError:
        return image_bytes

    width, height = source.size
    if width <= 0 or height <= 0 or width < grid_size:
        return image_bytes
    tables = _pixiv_comic_reverse_shuffle_tables(width, height, grid_size, key)
    column_count = width // grid_size
    restored = Image.new("RGBA", source.size)
    for row_index, table in enumerate(tables):
        top = row_index * grid_size
        bottom = min(top + grid_size, height)
        for destination, source_column in enumerate(table):
            left = source_column * grid_size
            block = source.crop((left, top, left + grid_size, bottom))
            restored.paste(block, (destination * grid_size, top))
        remainder_left = column_count * grid_size
        if remainder_left < width:
            restored.paste(
                source.crop((remainder_left, top, width, bottom)),
                (remainder_left, top),
            )

    output = BytesIO()
    restored.save(output, format="PNG")
    return output.getvalue()


async def _fetch_pixiv_comic_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str = "",
) -> ChapterFetchResult:
    story_id = _pixiv_comic_story_id_from_url(chapter_url)
    if not story_id:
        raise ValueError("无法识别 Pixiv Comic 章节编号")

    page_response = await client.get(chapter_url, headers=_request_headers(chapter_url))
    page_response.raise_for_status()
    page_props = _pixiv_comic_page_props(page_response.text)
    salt = str(page_props.get("salt") or "").strip()
    if not salt:
        raise ValueError("Pixiv Comic 阅读页缺少请求签名盐值")

    payload = await _fetch_pixiv_comic_api(
        client,
        f"https://comic.pixiv.net/api/app/episodes/{story_id}/read_v4",
        chapter_url,
        headers=_pixiv_comic_read_headers(salt),
    )
    reading_episode = payload["data"].get("reading_episode")
    if not isinstance(reading_episode, dict):
        raise ValueError("Pixiv Comic 阅读接口缺少章节信息")
    pages = reading_episode.get("pages")
    if not isinstance(pages, list):
        raise ValueError("Pixiv Comic 阅读接口缺少漫画页面")

    image_urls: list[str] = []
    for page in pages:
        if not isinstance(page, dict):
            continue
        image_url = str(page.get("url") or "").strip()
        if not image_url or image_url in image_urls:
            continue
        key = str(page.get("key") or "").strip()
        try:
            grid_size = int(page.get("gridsize") or 32)
        except (TypeError, ValueError):
            grid_size = 32
        if key:
            _PIXIV_COMIC_PAGE_KEYS[image_url] = (key, max(1, grid_size))
        image_urls.append(image_url)

    if not image_urls:
        raise ValueError("未能从 Pixiv Comic 接口提取出漫画页面")
    title = chapter_title.strip() or str(reading_episode.get("title") or "Pixiv Comic 漫画").strip()
    return ChapterFetchResult(
        text=_manga_placeholder_text(title, len(image_urls)),
        image_urls=image_urls,
        illustration=False,
        access_restricted=reading_episode.get("is_displayable") is False,
    )


async def _fetch_pixiv_manga_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str = "",
) -> ChapterFetchResult:
    artwork_id = _pixiv_artwork_id_from_url(chapter_url)
    if not artwork_id:
        raise ValueError("无法识别 Pixiv 作品编号")
    payload = await _fetch_json(
        client,
        f"https://www.pixiv.net/ajax/illust/{artwork_id}/pages",
        _pixiv_api_headers(chapter_url),
    )
    body = payload["body"]
    if not isinstance(body, list):
        raise ValueError("Pixiv 分页接口返回异常")
    image_urls: list[str] = []
    for item in body:
        if not isinstance(item, dict):
            continue
        urls = item.get("urls")
        if not isinstance(urls, dict):
            continue
        candidate = str(urls.get("original") or urls.get("regular") or "").strip()
        if candidate and candidate not in image_urls:
            image_urls.append(candidate)
    if not image_urls:
        raise ValueError("未能从 Pixiv 接口提取出漫画页面")
    title = chapter_title.strip() or "Pixiv 漫画"
    return ChapterFetchResult(
        text=_manga_placeholder_text(title, len(image_urls)),
        image_urls=image_urls,
        illustration=False,
    )


async def _fetch_generic_manga_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str = "",
) -> ChapterFetchResult:
    response = await _get_html_response(client, chapter_url)
    resolved_url = str(response.url)
    image_urls = _extract_generic_manga_image_urls(response.text, resolved_url)
    if not image_urls:
        try:
            snapshot = await _fetch_with_edge_cdp(
                chapter_url,
                headless=True,
                ready_expression="""
                    document.querySelectorAll(
                        '#_imageList img, #viewer img, .comic-contain img, .comic-container img, '
                        + '.reader-main img, .manga-reader img, .chapter-content img, [data-page] img'
                    ).length > 0
                """,
                blocked_message="漫画阅读页被目标站点的访问保护拦截。",
            )
            resolved_url = snapshot.resolved_url
            image_urls = _extract_generic_manga_image_urls(snapshot.html, resolved_url)
        except Exception as exc:
            raise ValueError("未能从漫画阅读页提取图片；页面可能需要登录或站点规则已经变化") from exc
    if not image_urls:
        raise ValueError("未能从漫画阅读页提取图片")
    title = chapter_title.strip() or "漫画章节"
    return ChapterFetchResult(
        text=_manga_placeholder_text(title, len(image_urls)),
        image_urls=image_urls,
        illustration=False,
    )


def _sync_fetch_18comic_chapter_data(chapter_url: str, chapter_title: str = "") -> ChapterFetchResult:
    photo_id = _18comic_album_id_from_url(chapter_url)
    if photo_id:
        try:
            photo = _jm_client().get_photo_detail(str(photo_id))
            image_urls = [
                str(getattr(image, "download_url", "")).strip()
                for image in photo
                if str(getattr(image, "download_url", "")).strip()
            ]
            if image_urls:
                title = chapter_title.strip() or str(getattr(photo, "title", "") or "").strip() or "漫画章节"
                return ChapterFetchResult(
                    text=_manga_placeholder_text(title, len(image_urls)),
                    image_urls=image_urls,
                    illustration=False,
                )
        except Exception as exc:  # noqa: BLE001 - API 不可用时回退网页解析
            import logging

            logging.getLogger("qingjuan.scraper").warning(
                "18Comic 移动 API 章节获取失败，回退网页解析：%s", exc
            )

    photo_url = chapter_url
    album_url = _18comic_album_url(chapter_url)
    result = _sync_fetch_18comic_html(photo_url, album_url)
    _18comic_cache_scramble_id(chapter_url, result.text)
    image_urls = _parse_18comic_page_images(result.text, result.resolved_url)
    if not image_urls:
        raise ValueError("未能从 18Comic 页面提取出漫画图片")
    title = chapter_title.strip() or "漫画章节"
    return ChapterFetchResult(
        text=_manga_placeholder_text(title, len(image_urls)), image_urls=image_urls, illustration=False
    )


async def _fetch_18comic_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str = "",
) -> ChapterFetchResult:
    return await asyncio.to_thread(_sync_fetch_18comic_chapter_data, chapter_url, chapter_title)


async def _fetch_bika_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str = "",
) -> ChapterFetchResult:
    comic_id = _bika_comic_id_from_url(chapter_url)
    order = _bika_order_from_url(chapter_url)
    if not comic_id or not order:
        raise ValueError("无法识别 Bika 章节编号")
    runtime_settings = _load_runtime_settings()
    image_urls, resolved_title = await _bika_fetch_pages(client, comic_id, order, runtime_settings)
    if not image_urls:
        raise ValueError("未能从 Bika 接口提取出漫画页面")
    title = chapter_title.strip() or resolved_title or f"第{order}话"
    return ChapterFetchResult(
        text=_manga_placeholder_text(title, len(image_urls)), image_urls=image_urls, illustration=False
    )


async def _fetch_alphapolis_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str = "",
) -> ChapterFetchResult:
    html, resolved_url = await _fetch_alphapolis_chapter_html(chapter_url)
    soup = BeautifulSoup(html, "html.parser")
    body = soup.select_one("#novelBody")
    if body is None:
        raise ValueError("未能在 Alphapolis 页面中找到正文容器")

    for selector in ("script", "style", ".dots-indicator", ".g-recaptcha", "#LoadingEpisode"):
        for node in body.select(selector):
            node.decompose()

    image_urls: list[str] = []
    for image in body.select("img"):
        for key in ("data-src", "data-original", "src"):
            value = str(image.get(key) or "").strip()
            if value:
                absolute_url = urljoin(resolved_url, value)
                if absolute_url not in image_urls:
                    image_urls.append(absolute_url)
                break

    text = body.get_text("\n", strip=True)
    illustration = _is_illustration_chapter(chapter_title)
    if not text and image_urls:
        text = _format_illustration_text(chapter_title or "插图", image_urls)
        illustration = True
    elif image_urls and illustration:
        text = _append_image_links(text, image_urls)
    if not text and not image_urls:
        raise ValueError("未能从 Alphapolis 页面提取出正文内容")
    return ChapterFetchResult(text=text, image_urls=image_urls, illustration=illustration)


async def _fetch_fanqie_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str = "",
) -> ChapterFetchResult:
    response = await _get_fanqie_html_response(client, chapter_url, referer="https://fanqienovel.com/")
    try:
        chapter = parse_fanqie_reader_page(response.text, str(response.url))
    except Exception as web_error:
        item_id = fanqie_item_id_from_url(str(response.url))
        if not item_id:
            raise
        app_client = _FANQIE_APP_CLIENTS.get(client)
        if app_client is None:
            app_client = FanqieAppClient(client)
            _FANQIE_APP_CLIENTS[client] = app_client
        try:
            app_chapter = await app_client.fetch_chapter(
                item_id,
                title=chapter_title,
                source_url=str(response.url),
                access_restricted=True,
            )
        except Exception as app_error:
            raise ValueError(f"网页正文不可用，番茄 APP 全文接口也未返回完整内容：{app_error}") from web_error
        chapter = app_chapter.chapter
    return ChapterFetchResult(
        text=chapter.text,
        image_urls=list(chapter.image_urls),
        illustration=False,
        content_source=chapter.content_source,
        authorization_method=chapter.authorization_method,
        access_restricted=chapter.access_restricted,
    )


async def _fetch_qidian_chapter_data(
    chapter_url: str,
    *,
    qidian_cookies: dict[str, str] | None = None,
) -> ChapterFetchResult:
    ids = qidian_chapter_ids_from_url(chapter_url)
    if ids is None:
        raise ValueError("起点章节链接缺少作品或章节 ID")
    book_id, chapter_id = ids
    cookies = dict(qidian_cookies or {})
    chapter = await asyncio.to_thread(
        get_qidian_chapter,
        book_id,
        chapter_id,
        cookies=cookies,
    )
    return ChapterFetchResult(
        text=str(chapter.get("text") or ""),
        image_urls=[],
        content_source="qidian-mobile-web",
        authorization_method="qidian-web-session" if cookies else "public-web",
        access_restricted=bool(chapter.get("accessRestricted")),
    )


async def _fetch_quark_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
) -> ChapterFetchResult:
    ids = quark_chapter_ids_from_url(chapter_url)
    if ids is None:
        raise ValueError("夸克小说章节链接缺少作品或章节 ID")
    book_id, chapter_id = ids
    result = await get_quark_chapter_content(client, book_id, chapter_id)
    chapter = result.get("chapter")
    return ChapterFetchResult(
        text=str(result.get("text") or ""),
        image_urls=[],
        content_source="shuqi-public-web",
        authorization_method="anonymous-public",
        access_restricted=(not quark_chapter_is_public(chapter) if isinstance(chapter, dict) else False),
    )


async def _fetch_biqvge_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
) -> ChapterFetchResult:
    chapter = await get_biqvge_chapter(client, chapter_url)
    return ChapterFetchResult(
        text=str(chapter.get("text") or ""),
        image_urls=[],
        content_source=f"biqvge-{chapter.get('site') or 'public'}-web",
        authorization_method="anonymous-public",
        access_restricted=False,
    )


async def _fetch_copymanga_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str = "",
) -> ChapterFetchResult:
    ids = mangacopy_chapter_ids_from_url(chapter_url)
    if ids is None:
        raise ValueError("拷贝漫画章节链接缺少作品标识或章节 ID")
    path_word, chapter_id = ids
    result = await get_mangacopy_chapter(client, path_word, chapter_id)
    chapter = result.get("chapter")
    if not isinstance(chapter, dict):
        raise ValueError("拷贝漫画章节响应缺少 chapter 数据")
    contents = chapter.get("contents")
    image_urls: list[str] = []
    seen: set[str] = set()
    if isinstance(contents, list):
        for item in contents:
            value = str(item.get("url") or "").strip() if isinstance(item, dict) else ""
            if not value or value in seen:
                continue
            if not is_allowed_mangacopy_image_url(value):
                raise ValueError("拷贝漫画章节返回了非 HTTPS 或非官方图片域名")
            seen.add(value)
            image_urls.append(value)
    if not image_urls:
        raise ValueError(f"拷贝漫画章节“{chapter_title or chapter_id}”没有返回可解析图片")
    return ChapterFetchResult(
        text="",
        image_urls=image_urls,
        illustration=False,
        content_source="mangacopy-public-api",
        authorization_method="public-api",
        access_restricted=any(bool(result.get(key)) for key in ("is_lock", "is_login", "is_vip")),
    )


async def _fetch_ciweimao_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
) -> ChapterFetchResult:
    chapter_id = ciweimao_chapter_id_from_url(chapter_url)
    if not chapter_id:
        raise ValueError("无法识别刺猬猫章节链接")
    text = await get_ciweimao_chapter(client, chapter_id)
    return ChapterFetchResult(
        text=text,
        image_urls=[],
        content_source="ciweimao-encrypted-web-api",
        authorization_method="anonymous-public",
        access_restricted=False,
    )


async def _fetch_shaoniandream_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
) -> ChapterFetchResult:
    chapter_id = shaoniandream_chapter_id_from_url(chapter_url)
    if not chapter_id:
        raise ValueError("无法识别少年梦章节链接")
    text = await get_shaoniandream_chapter(client, chapter_id)
    return ChapterFetchResult(
        text=text,
        image_urls=[],
        content_source="shaoniandream-encrypted-web-api",
        authorization_method="anonymous-public",
        access_restricted=False,
    )


async def _fetch_sfacg_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
) -> ChapterFetchResult:
    ids = sfacg_chapter_ids_from_url(chapter_url)
    if not ids:
        raise ValueError("无法识别 SF 轻小说章节链接")
    text = await get_sfacg_chapter(client, ids[1])
    return ChapterFetchResult(
        text=text,
        image_urls=[],
        content_source="sfacg-signed-api",
        authorization_method="upstream-access-policy",
        access_restricted=False,
    )


async def _fetch_ehentai_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str,
) -> ChapterFetchResult:
    if not ehentai_gallery_ids_from_url(chapter_url):
        raise ValueError("无法识别 E-Hentai 画廊链接")
    entries = await get_ehentai_gallery_image_entries(client, chapter_url)
    image_urls = [item["image_url"] for item in entries]
    for item in entries:
        _EHENTAI_IMAGE_REFERERS[item["image_url"]] = item["referer"]
    return ChapterFetchResult(
        text=_manga_placeholder_text(chapter_title or "E-Hentai 画廊", len(image_urls)),
        image_urls=image_urls,
        content_source="ehentai-public-gallery",
        authorization_method="anonymous-public",
        access_restricted=False,
    )


async def _fetch_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str = "",
    *,
    qidian_cookies: dict[str, str] | None = None,
) -> ChapterFetchResult:
    plugin = _require_enabled_site_plugin(chapter_url)
    if plugin.chapter_handler is None:
        raise ValueError(f"站点插件“{plugin.name}”当前只支持作品预览和搜索，尚未实现章节抓取")
    try:
        if plugin.chapter_handler == "fanqie":
            return await _fetch_fanqie_chapter_data(client, chapter_url, chapter_title)
        if plugin.chapter_handler == "qidian":
            return await _fetch_qidian_chapter_data(
                chapter_url,
                qidian_cookies=qidian_cookies,
            )
        if plugin.chapter_handler == "quark":
            return await _fetch_quark_chapter_data(client, chapter_url)
        if plugin.chapter_handler == "biqvge":
            return await _fetch_biqvge_chapter_data(client, chapter_url)
        if plugin.chapter_handler == "18comic":
            return await _fetch_18comic_chapter_data(client, chapter_url, chapter_title)
        if plugin.chapter_handler == "bika":
            return await _fetch_bika_chapter_data(client, chapter_url, chapter_title)
        if plugin.chapter_handler == "copymanga":
            return await _fetch_copymanga_chapter_data(client, chapter_url, chapter_title)
        if plugin.chapter_handler == "ciweimao":
            return await _fetch_ciweimao_chapter_data(client, chapter_url)
        if plugin.chapter_handler == "shaoniandream":
            return await _fetch_shaoniandream_chapter_data(client, chapter_url)
        if plugin.chapter_handler == "sfacg":
            return await _fetch_sfacg_chapter_data(client, chapter_url)
        if plugin.chapter_handler == "ehentai":
            return await _fetch_ehentai_chapter_data(client, chapter_url, chapter_title)
        if plugin.chapter_handler == "pixiv_comic":
            if _is_pixiv_comic_story_url(chapter_url):
                return await _fetch_pixiv_comic_chapter_data(client, chapter_url, chapter_title)
            raise ValueError("Pixiv Comic 作品页不是章节地址，请先解析作品目录")
        if plugin.chapter_handler == "pixiv":
            if _is_pixiv_manga_url(chapter_url):
                return await _fetch_pixiv_manga_data(client, chapter_url, chapter_title)
            return await _fetch_pixiv_chapter_data(client, chapter_url, chapter_title)
        if plugin.chapter_handler == "generic_manga":
            return await _fetch_generic_manga_chapter_data(client, chapter_url, chapter_title)
        if plugin.chapter_handler == "linovelib":
            return await _fetch_linovelib_chapter_data(client, chapter_url, chapter_title)
        if plugin.chapter_handler == "kakuyomu":
            return await _fetch_kakuyomu_chapter_data(client, chapter_url, chapter_title)
        if plugin.chapter_handler == "yanmaga":
            return await _fetch_yanmaga_chapter_data(client, chapter_url, chapter_title)
        if plugin.chapter_handler == "syosetu":
            return await _fetch_syosetu_chapter_data(client, chapter_url, chapter_title)
        if plugin.chapter_handler == "hameln":
            return await _fetch_hameln_chapter_data(client, chapter_url, chapter_title)
        if plugin.chapter_handler == "novelup":
            raise ValueError(
                "Novelup 当前访问被 CloudFront 拦截（403），当前环境下即使使用浏览器会话也无法直接抓取章节。"
            )
        if plugin.chapter_handler == "alphapolis":
            return await _fetch_alphapolis_chapter_data(client, chapter_url, chapter_title)

        response = await client.get(chapter_url, headers=_request_headers(chapter_url))
        response.raise_for_status()
        json_text = _chapter_text_from_json_text(response.text)
        if json_text:
            return ChapterFetchResult(text=json_text, image_urls=[], illustration=False)
        if _json_payload_from_text(response.text) is not None:
            raise ValueError("书源返回 JSON 数据，但未能从中提取章节正文，请换用包含章节正文规则的书源")
        _raise_if_blocked(response.text, chapter_url)
        soup = BeautifulSoup(response.text, "html.parser")
        text = "\n".join(
            item.get_text(" ", strip=True) for item in soup.select("p") if item.get_text(" ", strip=True)
        ).strip()
        if text:
            return ChapterFetchResult(text=text, image_urls=[], illustration=False)
        return ChapterFetchResult(
            text=soup.get_text("\n", strip=True)[:15000], image_urls=[], illustration=False
        )
    except Exception as exc:
        if (
            _is_manga_source_url(chapter_url)
            or _is_fanqie_url(chapter_url)
            or _is_quark_url(chapter_url)
            or _is_biqvge_url(chapter_url)
        ):
            raise
        return ChapterFetchResult(
            text=f"章节抓取失败：{exc}\n原始链接：{chapter_url}",
            image_urls=[],
            illustration=False,
        )


def _is_probable_linovelib_page(soup: BeautifulSoup) -> bool:
    return bool(
        soup.select_one("#volumes")
        or soup.select_one("#volume-list")
        or soup.select_one(".volume-list")
        or soup.select_one("#acontent")
        or soup.select_one("#TextContent")
        or soup.select_one("[property='og:novel:book_name']")
    )


def _request_headers(url: str, referer: str | None = None) -> dict[str, str]:
    headers = dict(DEFAULT_HEADERS)
    parsed = urlparse(url)
    headers["Referer"] = referer or f"{parsed.scheme}://{parsed.netloc}/"
    headers["Sec-Fetch-Site"] = "same-origin" if referer else "none"
    if _is_syosetu_url(url) or _is_novel18_url(url) or _is_hameln_url(url):
        headers["Accept-Encoding"] = "identity"
        headers["Accept-Language"] = "ja,en;q=0.9"
    if _is_pixiv_url(url):
        headers["Accept-Language"] = "ja,en;q=0.9"
    return headers


def _create_async_http_client(
    *,
    timeout: float,
    headers: dict[str, str] | None = None,
    follow_redirects: bool = True,
) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        follow_redirects=follow_redirects,
        timeout=timeout,
        headers=headers,
        http2=False,
        verify=ssl.create_default_context(),
    )


def _create_model_http_client(*, timeout: float) -> httpx.AsyncClient:
    return create_model_http_client(timeout=timeout)


def _build_http_client() -> httpx.AsyncClient:
    client = _create_async_http_client(timeout=20.0, headers=DEFAULT_HEADERS)
    client.cookies.set("over18", "yes", domain=".syosetu.com")
    client.cookies.set("over18", "yes", domain=".novel18.syosetu.com")
    return client


async def _throttle_linovelib_request(url: str) -> None:
    if not _is_linovelib_url(url):
        return

    host = (urlparse(url).hostname or "").lower()
    last_request_at = _HOST_LAST_REQUEST_AT.get(host)
    now = time.monotonic()
    if last_request_at is not None:
        wait_seconds = LINOVELIB_MIN_REQUEST_INTERVAL - (now - last_request_at)
        if wait_seconds > 0:
            await asyncio.sleep(wait_seconds)
    _HOST_LAST_REQUEST_AT[host] = time.monotonic()


async def _throttle_fanqie_request(url: str) -> None:
    host = (urlparse(url).hostname or "").lower()
    last_request_at = _HOST_LAST_REQUEST_AT.get(host)
    now = time.monotonic()
    if last_request_at is not None:
        wait_seconds = FANQIE_MIN_REQUEST_INTERVAL - (now - last_request_at)
        if wait_seconds > 0:
            await asyncio.sleep(wait_seconds)
    _HOST_LAST_REQUEST_AT[host] = time.monotonic()


def _retry_wait_seconds(response: httpx.Response, attempt: int) -> float:
    retry_after = response.headers.get("Retry-After", "").strip()
    if retry_after:
        try:
            return max(1.0, min(30.0, float(int(retry_after))))
        except ValueError:
            try:
                retry_after_at = parsedate_to_datetime(retry_after)
                wait_seconds = retry_after_at.timestamp() - time.time()
                if wait_seconds > 0:
                    return min(30.0, wait_seconds)
            except Exception:
                pass

    return min(12.0, 1.5 * (2**attempt))


def _fanqie_response_needs_retry(response: httpx.Response) -> bool:
    if response.status_code in FANQIE_RETRYABLE_STATUS_CODES:
        return True
    if not response.is_success:
        return False
    body = response.text
    return not body.strip() or "__INITIAL_STATE__=" not in body


def _fanqie_target_identity(url: str) -> tuple[str, str]:
    book_id = fanqie_book_id_from_url(url)
    if book_id:
        return "book", book_id
    item_id = fanqie_item_id_from_url(url)
    if item_id:
        return "reader", item_id
    raise ValueError("番茄小说链接无效：只支持作品页 /page/编号 和章节页 /reader/编号")


async def _get_fanqie_html_response(
    client: httpx.AsyncClient,
    url: str,
    referer: str | None = None,
) -> httpx.Response:
    expected_identity = _fanqie_target_identity(url)
    current_url = url
    for _ in range(FANQIE_MAX_REDIRECTS + 1):
        if _fanqie_target_identity(current_url) != expected_identity:
            raise ValueError("番茄小说重定向改变了作品或章节编号，已拒绝继续请求")

        response: httpx.Response | None = None
        last_transport_error: httpx.TransportError | None = None
        for attempt in range(FANQIE_MAX_RETRIES):
            await _throttle_fanqie_request(current_url)
            try:
                response = await client.get(
                    current_url,
                    headers=_request_headers(current_url, referer=referer),
                    follow_redirects=False,
                )
                last_transport_error = None
            except httpx.TransportError as exc:
                last_transport_error = exc
                if attempt < FANQIE_MAX_RETRIES - 1:
                    await asyncio.sleep(min(6.0, 1.5 * (2**attempt)))
                    continue
                raise

            if _fanqie_response_needs_retry(response) and attempt < FANQIE_MAX_RETRIES - 1:
                await asyncio.sleep(_retry_wait_seconds(response, attempt))
                continue
            break

        if response is None:
            if last_transport_error is not None:
                raise last_transport_error
            raise ValueError("番茄小说网络请求未返回响应")

        if response.is_redirect:
            location = response.headers.get("Location", "").strip()
            if not location:
                raise ValueError("番茄小说返回了缺少 Location 的重定向")
            candidate = urljoin(str(response.url), location)
            if not is_fanqie_url(candidate) or _fanqie_target_identity(candidate) != expected_identity:
                raise ValueError("番茄小说返回了不受信任的跨站或跨资源重定向")
            current_url = candidate
            continue

        response.raise_for_status()
        if _fanqie_target_identity(str(response.url)) != expected_identity:
            raise ValueError("番茄小说响应地址与请求资源不一致")
        return response

    raise ValueError(f"番茄小说重定向次数超过上限 {FANQIE_MAX_REDIRECTS}")


async def _fetch_fanqie_html(source_url: str) -> tuple[str, str]:
    async with _create_async_http_client(
        timeout=20.0,
        headers=DEFAULT_HEADERS,
        follow_redirects=False,
    ) as client:
        response = await _get_fanqie_html_response(client, source_url)
        return response.text, str(response.url)


async def _prime_linovelib_session(client: httpx.AsyncClient, url: str) -> None:
    if not _is_linovelib_url(url):
        return

    parsed = urlparse(url)
    origin = f"{parsed.scheme}://{parsed.netloc}/"
    try:
        await _throttle_linovelib_request(origin)
        await client.get(origin, headers=_request_headers(origin))
    except Exception:
        return


async def _get_html_response(
    client: httpx.AsyncClient,
    url: str,
    referer: str | None = None,
) -> httpx.Response:
    if not _is_linovelib_url(url):
        response = await client.get(url, headers=_request_headers(url, referer=referer))
        response.raise_for_status()
        _raise_if_blocked(response.text, str(response.url))
        return response

    last_response: httpx.Response | None = None
    for attempt in range(LINOVELIB_MAX_RETRIES):
        await _throttle_linovelib_request(url)
        response = await client.get(url, headers=_request_headers(url, referer=referer))
        last_response = response

        if response.status_code == 403:
            await _prime_linovelib_session(client, url)

        if response.status_code in LINOVELIB_RETRYABLE_STATUS_CODES and attempt < LINOVELIB_MAX_RETRIES - 1:
            await asyncio.sleep(_retry_wait_seconds(response, attempt))
            continue

        response.raise_for_status()
        _raise_if_blocked(response.text, str(response.url))
        return response

    if last_response is not None:
        last_response.raise_for_status()
    raise ValueError(f"请求失败：{url}")


async def _get_binary_response(
    client: httpx.AsyncClient,
    url: str,
    referer: str | None = None,
) -> httpx.Response:
    if not _is_linovelib_url(url):
        response = await client.get(url, headers=_image_request_headers(url, referer or url))
        response.raise_for_status()
        return response

    last_response: httpx.Response | None = None
    for attempt in range(LINOVELIB_MAX_RETRIES):
        await _throttle_linovelib_request(url)
        response = await client.get(url, headers=_image_request_headers(url, referer or url))
        last_response = response

        if response.status_code in LINOVELIB_RETRYABLE_STATUS_CODES and attempt < LINOVELIB_MAX_RETRIES - 1:
            await asyncio.sleep(_retry_wait_seconds(response, attempt))
            continue

        response.raise_for_status()
        return response

    if last_response is not None:
        last_response.raise_for_status()
    raise ValueError(f"资源请求失败：{url}")


def _raise_if_blocked(html: str, url: str) -> None:
    if any(marker in html for marker in LINOVELIB_BLOCK_MARKERS):
        raise ValueError(
            "目标站点启用了 Cloudflare 防护，当前请求被拦截。"
            f"链接：{url}。建议先在浏览器中确认该页面可访问，或改用可直接访问的目录页。"
        )


async def _fetch_preview_html(source_url: str) -> tuple[str, str]:
    candidates = _linovelib_candidate_urls(source_url) if _is_linovelib_url(source_url) else [source_url]
    last_error: Exception | None = None

    async with _build_http_client() as client:
        for candidate in candidates:
            try:
                response = await _get_html_response(client, candidate)
                return response.text, str(response.url)
            except Exception as exc:
                last_error = exc

    if last_error is not None:
        raise last_error
    raise ValueError(f"无法读取目录页：{source_url}")


async def _fetch_linovelib_chapter_data(
    client: httpx.AsyncClient,
    chapter_url: str,
    chapter_title: str = "",
) -> ChapterFetchResult:
    page_url = chapter_url
    parts: list[str] = []
    image_urls: list[str] = []
    visited: set[str] = set()

    while page_url and page_url not in visited:
        visited.add(page_url)
        response = await _get_html_response(client, page_url, referer=chapter_url)
        soup = BeautifulSoup(response.text, "html.parser")
        text = _extract_linovelib_page_text(soup)
        if text:
            parts.append(text)
        for image_url in _extract_linovelib_image_urls(soup, str(response.url)):
            if image_url not in image_urls:
                image_urls.append(image_url)

        next_page = _extract_linovelib_next_page(response.text, str(response.url))
        if not next_page or not _same_linovelib_chapter(chapter_url, next_page):
            break
        page_url = next_page

    merged = "\n\n".join(part for part in parts if part.strip()).strip()
    illustration = _is_illustration_chapter(chapter_title)
    if not merged and image_urls:
        merged = _format_illustration_text(chapter_title or "插图", image_urls)
        illustration = True
    elif image_urls and illustration:
        merged = _append_image_links(merged, image_urls)

    if merged:
        return ChapterFetchResult(text=merged, image_urls=image_urls, illustration=illustration)

    raise ValueError("未能从轻小说页面提取出正文内容")


def _extract_linovelib_page_text(soup: BeautifulSoup) -> str:
    content_node = soup.select_one("#acontent, #TextContent, .read-content")
    if content_node is None:
        return ""

    for selector in (".cgo", "script", "style", "#footlink", ".mlfy_page"):
        for node in content_node.select(selector):
            node.decompose()

    text = content_node.get_text("\n", strip=True)
    lines = []
    for raw_line in text.splitlines():
        line = re.sub(r"\s+", " ", raw_line).strip()
        if not line:
            continue
        if any(marker in line for marker in NOISE_LINE_MARKERS):
            continue
        lines.append(line)

    return "\n".join(lines).strip()


def _extract_linovelib_image_urls(soup: BeautifulSoup, current_url: str) -> list[str]:
    content_node = soup.select_one("#acontent, #TextContent, .read-content")
    if content_node is None:
        return []

    urls: list[str] = []
    for image in content_node.select("img"):
        for key in ("data-src", "data-original", "src"):
            value = image.get(key)
            if not isinstance(value, str):
                continue
            normalized = value.strip()
            if not normalized or normalized.endswith("sloading.svg"):
                continue
            absolute_url = urljoin(current_url, normalized)
            if absolute_url not in urls:
                urls.append(absolute_url)
            break
    return urls


def _extract_linovelib_next_page(html: str, current_url: str) -> str | None:
    soup = BeautifulSoup(html, "html.parser")
    for anchor in soup.select(".mlfy_page a[href], #footlink a[href]"):
        label = anchor.get_text(" ", strip=True)
        href = str(anchor.get("href", "")).strip()
        if not href:
            continue
        if label in {"下一页", "下一頁", "下一话", "下一話"}:
            return urljoin(current_url, href)

    match = re.search(r"url_next\s*[:=]\s*'([^']+)'", html)
    if not match:
        match = re.search(r'url_next\s*[:=]\s*"([^"]+)"', html)
    if not match:
        return None

    candidate = match.group(1).strip()
    if not candidate:
        return None
    return urljoin(current_url, candidate)


def _same_linovelib_chapter(source_url: str, candidate_url: str) -> bool:
    source_match = LINOVELIB_CHAPTER_PATH_PATTERN.match(urlparse(source_url).path)
    candidate_match = LINOVELIB_CHAPTER_PATH_PATTERN.match(urlparse(candidate_url).path)
    if not source_match or not candidate_match:
        return False

    return source_match.group("book_id") == candidate_match.group("book_id") and source_match.group(
        "chapter_id"
    ) == candidate_match.group("chapter_id")


def _is_illustration_chapter(chapter_title: str) -> bool:
    normalized = chapter_title.strip().lower()
    return any(keyword in normalized for keyword in ("插图", "插圖", "illustration"))


def _format_illustration_text(chapter_title: str, image_urls: list[str]) -> str:
    lines = [f"{chapter_title}（插图章节）", "", f"共收集到 {len(image_urls)} 张图片链接：", ""]
    lines.extend(image_urls)
    return "\n".join(lines).strip()


def _append_image_links(text: str, image_urls: list[str]) -> str:
    if not image_urls:
        return text
    if not text.strip():
        return "插图链接：\n" + "\n".join(image_urls)
    return f"{text.rstrip()}\n\n插图链接：\n" + "\n".join(image_urls)


async def _download_binary_bytes(
    client: httpx.AsyncClient,
    url: str,
    referer: str,
) -> bytes:
    if _is_18comic_url(url) or _is_18comic_url(referer):
        return await asyncio.to_thread(_sync_fetch_18comic_binary, url, referer)
    if _is_linovelib_url(url):
        response = await _get_binary_response(client, url, referer=referer)
        return response.content
    pixiv_comic_page = _PIXIV_COMIC_PAGE_KEYS.get(url)
    yanmaga_page = _YANMAGA_PAGE_KEYS.get(url)
    headers = _image_request_headers(url, referer)
    if ehentai_referer := _EHENTAI_IMAGE_REFERERS.get(url):
        headers["Referer"] = ehentai_referer
    if pixiv_comic_page:
        headers["X-Cobalt-Thumber-Parameter-GridShuffle-Key"] = pixiv_comic_page[0]
    if yanmaga_page:
        headers["Referer"] = yanmaga_page[2]
        headers["Origin"] = YANMAGA_ORIGIN
    image_bytes = await fetch_image_with_retry(
        client,
        url,
        headers=headers,
    )
    if pixiv_comic_page:
        key, grid_size = pixiv_comic_page
        return await asyncio.to_thread(_pixiv_comic_descramble_bytes, image_bytes, key, grid_size)
    if yanmaga_page:
        position_key, content_key, _ = yanmaga_page
        return await asyncio.to_thread(
            descramble_yanmaga_image,
            image_bytes,
            position_key,
            content_key,
        )
    return image_bytes


def _image_download_concurrency(source_url: str, concurrency: int) -> int:
    normalized = max(1, min(concurrency, 8))
    if _is_18comic_url(source_url) or _is_bikawebapp_url(source_url):
        return min(8, max(2, normalized * 2))
    return normalized


async def _download_chapter_images(
    client: httpx.AsyncClient,
    book_dir: Path,
    chapter_index: int,
    image_urls: list[str],
    referer: str,
    *,
    image_download_semaphore: asyncio.Semaphore | None = None,
) -> list[str]:
    if not image_urls:
        return []

    images_dir = book_dir / "images"
    images_dir.mkdir(parents=True, exist_ok=True)

    async def download_single_image(image_number: int, image_url: str) -> str:
        extension = ".png" if image_url in _PIXIV_COMIC_PAGE_KEYS else _image_extension_from_url(image_url)
        file_hash = md5(image_url.encode("utf-8")).hexdigest()[:10]
        filename = f"{chapter_index:04d}-{image_number:02d}-{file_hash}{extension}"
        target_path = images_dir / filename
        if await asyncio.to_thread(is_valid_image_file, target_path):
            return f"images/{filename}"

        async def fetch_and_write() -> None:
            content = await _download_binary_bytes(client, image_url, referer)
            await asyncio.to_thread(write_image_atomic, target_path, content)

        if image_download_semaphore is None:
            await fetch_and_write()
        else:
            async with image_download_semaphore:
                if not await asyncio.to_thread(is_valid_image_file, target_path):
                    await fetch_and_write()
        return f"images/{filename}"

    return await asyncio.gather(
        *(
            download_single_image(image_number, image_url)
            for image_number, image_url in enumerate(image_urls, start=1)
        )
    )


async def _download_cover_image(
    client: httpx.AsyncClient,
    book_dir: Path,
    cover_url: str | None,
    referer: str,
) -> str | None:
    if not cover_url:
        return None

    covers_dir = book_dir / "covers"
    covers_dir.mkdir(parents=True, exist_ok=True)
    image_bytes = await _download_binary_bytes(client, cover_url, referer)
    extension = _image_extension_from_bytes(image_bytes, _image_extension_from_url(cover_url))
    filename = f"cover{extension}"
    target_path = covers_dir / filename
    if not await asyncio.to_thread(is_valid_image_file, target_path):
        await asyncio.to_thread(write_image_atomic, target_path, image_bytes)
    return f"covers/{filename}"


def _image_extension_from_url(url: str) -> str:
    suffix = Path(urlparse(url).path).suffix.lower()
    if suffix in {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"}:
        return suffix
    return ".jpg"


def _image_extension_from_bytes(image_bytes: bytes, fallback: str = ".jpg") -> str:
    if image_bytes.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if image_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if image_bytes[:6] in {b"GIF87a", b"GIF89a"}:
        return ".gif"
    if image_bytes.startswith(b"BM"):
        return ".bmp"
    if image_bytes[:4] == b"RIFF" and image_bytes[8:12] == b"WEBP":
        return ".webp"

    try:
        with Image.open(BytesIO(image_bytes)) as image:
            format_name = (image.format or "").upper()
    except UnidentifiedImageError:
        return fallback

    return {
        "JPEG": ".jpg",
        "PNG": ".png",
        "WEBP": ".webp",
        "GIF": ".gif",
        "BMP": ".bmp",
    }.get(format_name, fallback)


def _image_request_headers(url: str, referer: str) -> dict[str, str]:
    headers = _request_headers(url, referer=referer)
    headers["Accept"] = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
    return headers


async def _translate_text(
    client: httpx.AsyncClient,
    settings: TranslationSettings,
    target_language: str,
    title: str,
    content: str,
) -> str:
    base_url, api_key, model = _resolve_openai_compatible_model_config(
        settings,
        feature_name="翻译",
    )
    resolved_target_language = _resolve_translation_target_language(target_language)
    prompt = (
        f"章节标题：{title}\n"
        f"目标语言：{resolved_target_language}\n"
        f"请将以下章节内容翻译为{resolved_target_language}；如果原文已经是{resolved_target_language}，请保持原意并输出自然流畅的{resolved_target_language}版本。\n\n"
        f"{content}"
    )

    content = await _post_translation_completion_text(
        client,
        f"{base_url}/chat/completions",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        payload={
            "model": model,
            "temperature": 0.2,
            "messages": [
                {"role": "system", "content": settings.systemPrompt},
                {"role": "user", "content": prompt},
            ],
        },
        feature_name="翻译模型",
    )
    return content


def _media_type_for_path(path: Path) -> str:
    return {
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".webp": "image/webp",
        ".gif": "image/gif",
    }.get(path.suffix.lower(), "image/jpeg")


def _normalize_translation_result(content_value: Any) -> str:
    if content_value is None:
        content_value = ""
    if isinstance(content_value, list):
        parts = [item.get("text", "") for item in content_value if isinstance(item, dict)]
        content_value = "\n".join(part for part in parts if part)
    text = str(content_value).strip()
    if not text:
        raise ValueError("翻译服务返回了空翻译结果")
    return text


def _is_deepseek_v4_model(model: str) -> bool:
    return "deepseek-v4" in model.strip().lower()


def _translation_completion_request_payload(
    payload: dict[str, Any],
    *,
    expects_json: bool,
) -> dict[str, Any]:
    request_payload = json.loads(json.dumps(payload))
    model = str(request_payload.get("model") or "")
    if _is_deepseek_v4_model(model):
        # DeepSeek V4 默认开启思考模式。翻译是确定性转换任务，关闭思考可避免
        # reasoning_content 占满 max_tokens 后没有剩余额度生成最终 content。
        request_payload["thinking"] = {"type": "disabled"}
        if expects_json:
            request_payload["response_format"] = {"type": "json_object"}
    return request_payload


def _chat_completion_choice(payload: dict[str, Any], feature_name: str) -> dict[str, Any]:
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        raise ValueError(f"{feature_name}未返回任何候选结果")
    return choices[0]


def _reasoning_exhausted_completion(choice: dict[str, Any]) -> bool:
    message = choice.get("message")
    if not isinstance(message, dict):
        return False
    reasoning_content = message.get("reasoning_content")
    return choice.get("finish_reason") == "length" and bool(str(reasoning_content or "").strip())


async def _post_translation_completion_text(
    client: httpx.AsyncClient,
    url: str,
    *,
    headers: dict[str, str],
    payload: dict[str, Any],
    feature_name: str,
    expects_json: bool = False,
) -> str:
    request_payload = _translation_completion_request_payload(payload, expects_json=expects_json)
    last_choice: dict[str, Any] | None = None

    for attempt in range(2):
        response_payload = await _post_translation_json(
            client,
            url,
            headers=headers,
            payload=request_payload,
        )
        choice = _chat_completion_choice(response_payload, feature_name)
        last_choice = choice
        message = choice.get("message")
        content_value = message.get("content") if isinstance(message, dict) else ""
        try:
            return _normalize_translation_result(content_value)
        except ValueError:
            if not _reasoning_exhausted_completion(choice) or attempt > 0:
                break
            configured_budget = request_payload.get("max_tokens")
            current_budget = int(configured_budget) if isinstance(configured_budget, int) else 3000
            request_payload = json.loads(json.dumps(request_payload))
            request_payload["max_tokens"] = min(16000, max(8000, current_budget * 3))

    if last_choice is not None and _reasoning_exhausted_completion(last_choice):
        raise ValueError(
            f"{feature_name}未生成最终内容：模型推理过程耗尽输出额度"
            "（finish_reason=length）。请改用非思考模式或提高输出上限。"
        )
    finish_reason = last_choice.get("finish_reason") if last_choice is not None else None
    raise ValueError(f"{feature_name}返回了空内容（finish_reason={finish_reason or 'unknown'}）")


def _redact_translation_error_text(value: str) -> str:
    normalized = re.sub(r"\s+", " ", value).strip()
    normalized = re.sub(
        r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+",
        "Bearer ***",
        normalized,
    )
    normalized = re.sub(r"\bsk-[A-Za-z0-9_-]{8,}\b", "sk-***", normalized)
    if len(normalized) > 240:
        return f"{normalized[:237].rstrip()}..."
    return normalized


def _translation_response_excerpt(response: httpx.Response) -> str:
    response_text = response.text.strip()
    if not response_text:
        return ""
    content_type = response.headers.get("content-type", "").lower()
    if "html" in content_type or response_text.lstrip().lower().startswith(("<!doctype", "<html")):
        response_text = BeautifulSoup(response_text, "html.parser").get_text(" ", strip=True)
    return _redact_translation_error_text(response_text)


def _translation_service_error_message(payload: dict[str, Any]) -> str:
    error = payload.get("error")
    candidates: list[Any] = []
    if isinstance(error, dict):
        candidates.extend((error.get("message"), error.get("detail"), error.get("code")))
    else:
        candidates.append(error)
    candidates.extend((payload.get("message"), payload.get("detail")))
    for candidate in candidates:
        if isinstance(candidate, str) and candidate.strip():
            return _redact_translation_error_text(candidate)
    return ""


def _decode_translation_json_response(response: httpx.Response) -> dict[str, Any]:
    status_code = response.status_code
    content_type = response.headers.get("content-type", "").split(";", 1)[0].strip() or "未知"
    response_text = response.text.strip()
    if not response_text:
        if response.is_error:
            raise ValueError(
                f"翻译服务请求失败（HTTP {status_code}）：服务未返回错误详情。"
                "请检查 API 地址、API 密钥和模型名称。"
            )
        raise ValueError(
            f"翻译服务返回空响应（HTTP {status_code}）。"
            "请检查 API 地址是否为 OpenAI 兼容服务的 /v1；程序会调用 /v1/chat/completions。"
        )

    try:
        data = response.json()
    except ValueError as exc:
        excerpt = _translation_response_excerpt(response)
        detail = f" 服务响应：{excerpt}" if excerpt else ""
        raise ValueError(
            f"翻译服务返回了非 JSON 响应（HTTP {status_code}，Content-Type: {content_type}）。"
            f"请检查 API 地址或反向代理配置。{detail}"
        ) from exc

    if not isinstance(data, dict):
        raise ValueError(f"翻译服务返回了无法识别的数据结构（HTTP {status_code}，应为 JSON 对象）")

    service_error = _translation_service_error_message(data)
    if response.is_error or data.get("error"):
        detail = service_error or "服务未提供错误详情"
        raise ValueError(f"翻译服务请求失败（HTTP {status_code}）：{detail}")
    return data


async def _post_translation_json(
    client: httpx.AsyncClient,
    url: str,
    *,
    headers: dict[str, str],
    payload: dict[str, Any],
    max_retries: int = 3,
) -> dict[str, Any]:
    last_error: Exception | None = None
    retryable_status_codes = {408, 409, 425, 429, 500, 502, 503, 504}
    retryable_exceptions: tuple[type[Exception], ...] = (
        httpx.TransportError,
        ssl.SSLError,
    )

    for attempt in range(1, max_retries + 1):
        try:
            response = await client.post(url, headers=headers, json=payload)
            if response.status_code in retryable_status_codes and attempt < max_retries:
                await asyncio.sleep(min(1.2 * attempt, 4.0))
                continue
            return _decode_translation_json_response(response)
        except httpx.HTTPStatusError as exc:
            last_error = exc
            if exc.response.status_code not in retryable_status_codes or attempt >= max_retries:
                raise
            await asyncio.sleep(min(1.2 * attempt, 4.0))
        except retryable_exceptions as exc:
            last_error = exc
            if attempt >= max_retries:
                break
            await asyncio.sleep(min(1.2 * attempt, 4.0))

    raise last_error or ValueError(f"翻译请求失败：{url}")


def _merge_page_translations(title: str, page_translations: list[str]) -> str:
    lines = [title, ""]
    for index, page_text in enumerate(page_translations, start=1):
        lines.append(f"【第 {index} 页】")
        lines.append(page_text.strip() or "【本页无对白】")
        lines.append("")
    return "\n".join(lines).strip()
