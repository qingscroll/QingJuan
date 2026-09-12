"""Read source chapters without creating a library record, task, or progress.

Image references are kept briefly in memory and bound to the requesting owner.
Only assets discovered in the server-resolved chapter can be fetched.
"""

from __future__ import annotations

import asyncio
import secrets
import time
from collections import OrderedDict
from dataclasses import dataclass
from io import BytesIO
from typing import Any

from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel, ConfigDict, Field

from . import scraper
from .models import AddBookPayload, ChapterContentResponse, PublicChapterRecord
from .security import API_PREFIX


class PreviewChapterRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    book: AddBookPayload
    chapterIndex: int = Field(strict=True, ge=1)
    expectedChapterUrl: str | None = Field(default=None, max_length=8192)


class PreviewReadingError(ValueError):
    def __init__(self, message: str, status_code: int = 400):
        super().__init__(message)
        self.status_code = status_code


@dataclass
class _ImageSession:
    owner_id: str
    source_url: str
    chapter_url: str
    image_urls: tuple[str, ...]
    expires_at: float


class PreviewReadingService:
    def __init__(self, runtime: Any, *, now=None, ttl_seconds: float = 900):
        self.runtime = runtime
        self.now = now or time.monotonic
        self.ttl_seconds = ttl_seconds
        self._sessions: OrderedDict[str, _ImageSession] = OrderedDict()
        self._images: OrderedDict[tuple[str, int], tuple[bytes, str]] = OrderedDict()
        self._image_bytes = 0
        self._slots = asyncio.Semaphore(4)
        self._generation = 0

    def clear(self) -> None:
        self._generation += 1
        self._sessions.clear()
        self._images.clear()
        self._image_bytes = 0

    def _remove_session(self, token: str) -> None:
        self._sessions.pop(token, None)
        for key in [key for key in self._images if key[0] == token]:
            self._image_bytes -= len(self._images.pop(key)[0])

    def _prune(self) -> None:
        now = self.now()
        for token, session in list(self._sessions.items()):
            if session.expires_at <= now:
                self._remove_session(token)

    async def read(self, owner_id: str, payload: PreviewChapterRequest) -> ChapterContentResponse:
        generation = self._generation
        async with self._slots:
            try:
                async with asyncio.timeout(90):
                    # Resolve the catalog again on the backend. A caller cannot submit
                    # an arbitrary chapter URL or rewrite the directory in the request.
                    preview = await self.runtime.preview_from_url(payload.book)
                    if payload.chapterIndex > len(preview.chapters):
                        raise PreviewReadingError("章节不存在，请刷新作品目录后重试", 404)
                    chapter = preview.chapters[payload.chapterIndex - 1]
                    if payload.expectedChapterUrl and chapter.url != payload.expectedChapterUrl:
                        raise PreviewReadingError("书源目录已变化，请返回预览页重新加载目录", 409)
                    # Match bookshelf downloads: accessRestricted describes the
                    # source catalog, not the current account's effective access.
                    # Let the shared source reader resolve public/app content or
                    # use saved credentials, and preserve actual source errors.
                    async with scraper._build_http_client() as client:
                        result = await scraper._fetch_chapter_data(
                            client,
                            chapter.url,
                            chapter.title,
                            **self.runtime._site_account_download_kwargs(
                                owner_id, str(payload.book.sourceUrl)
                            ),
                        )
            except TimeoutError as error:
                raise PreviewReadingError("试读加载超时，请稍后重试", 504) from error
        if generation != self._generation:
            raise PreviewReadingError("服务已重新加载，请重新打开试读", 409)
        if not result.text.strip() and not result.image_urls:
            raise PreviewReadingError("来源未返回可试读内容")

        image_sources: list[str] = []
        if result.image_urls:
            self._prune()
            owned = [token for token, item in self._sessions.items() if item.owner_id == owner_id]
            while len(owned) >= 8:
                self._remove_session(owned.pop(0))
            while len(self._sessions) >= 64:
                self._remove_session(next(iter(self._sessions)))
            token = secrets.token_urlsafe(24)
            self._sessions[token] = _ImageSession(
                owner_id,
                str(payload.book.sourceUrl),
                chapter.url,
                tuple(result.image_urls),
                self.now() + self.ttl_seconds,
            )
            image_sources = [
                f"{API_PREFIX}/books/preview/assets/{token}/{index}"
                for index in range(len(result.image_urls))
            ]
        return ChapterContentResponse(
            bookId="",
            chapter=PublicChapterRecord(
                id=f"preview-{payload.chapterIndex}",
                index=payload.chapterIndex,
                title=chapter.title,
                wordCount=len(result.text),
                downloaded=False,
                imageCount=len(image_sources),
                pageCount=len(image_sources),
                illustration=result.illustration,
            ),
            content=result.text,
            paragraphs=self.runtime._split_paragraphs(result.text),
            mode="original",
            translatedAvailable=False,
            imageSources=image_sources,
        )

    def _session(self, owner_id: str, token: str, index: int) -> _ImageSession:
        self._prune()
        session = self._sessions.get(token)
        if session is None or session.owner_id != owner_id or not 0 <= index < len(session.image_urls):
            raise PreviewReadingError("试读图片已过期或不存在，请重新加载章节", 404)
        return session

    async def image(self, owner_id: str, token: str, index: int) -> tuple[bytes, str]:
        session = self._session(owner_id, token, index)
        scraper._require_enabled_site_plugin(session.source_url)
        key = (token, index)
        if key in self._images:
            self._images.move_to_end(key)
            return self._images[key]
        async with self._slots:
            try:
                async with asyncio.timeout(60):
                    async with scraper._build_http_client() as client:
                        data = await scraper._download_binary_bytes(
                            client,
                            session.image_urls[index],
                            session.chapter_url,
                        )
            except TimeoutError as error:
                raise PreviewReadingError("试读图片加载超时，请重试", 504) from error
        self._session(owner_id, token, index)  # Expiry/maintenance may happen during a fetch.
        if len(data) > 32 * 1024 * 1024:
            raise PreviewReadingError("此页图片过大，请加入书架后阅读", 413)
        try:
            with Image.open(BytesIO(data)) as image:
                mime = Image.MIME.get(image.format or "")
        except (UnidentifiedImageError, OSError) as error:
            raise PreviewReadingError("来源返回的试读图片无效") from error
        if not mime:
            raise PreviewReadingError("来源返回的试读图片格式不支持")
        while self._images and self._image_bytes + len(data) > 64 * 1024 * 1024:
            _, (old, _) = self._images.popitem(last=False)
            self._image_bytes -= len(old)
        # A concurrent request may have populated the same image while fetching.
        previous = self._images.pop(key, None)
        if previous:
            self._image_bytes -= len(previous[0])
        self._images[key] = (data, mime)
        self._image_bytes += len(data)
        return data, mime
