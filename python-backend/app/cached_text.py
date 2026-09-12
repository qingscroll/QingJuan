"""Bounded, read-only search over cached chapter text, using reader UTF-16 anchors."""

import base64
import json
import re
from hashlib import sha256
from pathlib import Path

from . import db
from .annotations_models import AnnotationPosition, CachedTextHit, CachedTextQuery, CachedTextResults
from .models import BookRecord

MAX_MANIFEST_BYTES = 16 * 1024 * 1024
MAX_CHAPTER_BYTES = 2 * 1024 * 1024
MAX_SCAN_BYTES = 8 * 1024 * 1024
MAX_SCAN_CHAPTERS = 100


class ScanBudgetReached(ValueError):
    pass


def cached_manifest(book: BookRecord) -> tuple[Path, dict]:
    root = db.DATA_DIR.resolve()
    raw = str(book.localPath or "").strip()
    if raw:
        folder = Path(raw)
        folder = folder if folder.is_absolute() else root / folder
    else:
        title = re.sub(r'[\\/:*?"<>|]', "_", book.title).strip() or "未命名作品"
        folder = root / "library" / f"{title}-{book.id[:8]}"
    folder = folder.resolve()
    path = (folder / "manifest.json").resolve()
    if not folder.is_relative_to(root) or not path.is_relative_to(folder) or not path.is_file():
        raise ValueError("作品没有可用的缓存目录")
    with path.open("rb") as file:
        data = file.read(MAX_MANIFEST_BYTES + 1)
    if len(data) > MAX_MANIFEST_BYTES:
        raise ValueError("目录超过扫描限制，请缩小作品规模后重试")
    try:
        manifest = json.loads(data)
    except (ValueError, UnicodeError) as error:
        raise ValueError("缓存目录无法读取") from error
    if not isinstance(manifest, dict) or not isinstance(manifest.get("chapters"), list):
        raise ValueError("缓存目录格式无效")
    return folder, manifest


def chapter_path(folder: Path, chapter: dict, mode: str) -> Path | None:
    filename = chapter.get("file_name") if mode == "original" else chapter.get("translated_file_name")
    if mode == "translated" and not filename:
        original = chapter.get("file_name")
        if isinstance(original, str) and original.endswith(".txt"):
            filename = original[:-4] + ".translated.txt"
    if not isinstance(filename, str) or not filename:
        return None
    path = (folder / filename).resolve()
    return path if path.is_relative_to(folder) and path.is_file() else None


def reader_text(raw: str) -> str:
    paragraphs = []
    for line in raw.replace("\r\n", "\n").splitlines():
        body = line.strip()
        while body.startswith("\ue000"):
            body = body[1:].lstrip()
        while body.startswith("\u3164\u3164"):
            body = body[2:].lstrip()
        if body:
            paragraphs.append("\ue000" + body)
    return "\n\n".join(paragraphs)


def utf16_length(text: str) -> int:
    return len(text.encode("utf-16-le")) // 2


def read_cached_text(
    folder: Path, chapter: dict, mode: str, *, budget: list[int] | None = None
) -> tuple[str, int] | None:
    path = chapter_path(folder, chapter, mode)
    if path is None:
        return None
    with path.open("rb") as file:
        # Check the opened file, so atomic chapter replacement cannot make the
        # stat refer to a different file. Bad encodings also consume this budget.
        file.seek(0, 2)
        size = file.tell()
        file.seek(0)
        if size > MAX_CHAPTER_BYTES:
            raise ValueError("章节超过扫描限制")
        if budget is not None and size > budget[0]:
            raise ScanBudgetReached()
        read_limit = min(MAX_CHAPTER_BYTES + 1, budget[0]) if budget is not None else MAX_CHAPTER_BYTES + 1
        data = file.read(read_limit)
        if budget is not None:
            budget[0] -= len(data)
        # Writers normally replace files atomically. Refuse an in-place growth
        # race instead of reporting a hash for silently truncated content.
        file.seek(0, 2)
        if file.tell() > len(data):
            raise ValueError("章节正在变化，请稍后重新搜索")
    if len(data) > MAX_CHAPTER_BYTES:
        raise ValueError("章节超过扫描限制")
    try:
        return reader_text(data.decode("utf-8")), len(data)
    except UnicodeError as error:
        raise ValueError("章节编码无法读取") from error


def text_hash(text: str) -> str:
    return sha256(text.encode("utf-8")).hexdigest()


def anchor_hash(book: BookRecord, position: AnnotationPosition) -> str | None:
    try:
        folder, manifest = cached_manifest(book)
        chapter = next(
            (
                item
                for item in manifest["chapters"]
                if isinstance(item, dict) and item.get("index") == position.chapterIndex
            ),
            None,
        )
        content = read_cached_text(folder, chapter, position.contentMode or "original") if chapter else None
        return text_hash(content[0]) if content else None
    except (OSError, ValueError):
        return None


def validate_position(book: BookRecord, position: AnnotationPosition) -> None:
    _, manifest = cached_manifest(book)
    if not any(
        isinstance(chapter, dict) and chapter.get("index") == position.chapterIndex
        for chapter in manifest["chapters"]
    ):
        raise ValueError("阅读位置不在作品目录中，请刷新后重试")


def _cursor(index: int, offset: int, fingerprint: str) -> str:
    return base64.urlsafe_b64encode(json.dumps([index, offset, fingerprint]).encode()).decode()


def search_cached_text(book: BookRecord, query: CachedTextQuery) -> CachedTextResults:
    folder, manifest = cached_manifest(book)
    fingerprint = text_hash(json.dumps([query.query, query.mode, query.chapterIndex], ensure_ascii=False))[
        :20
    ]
    start_index, start_offset = 0, 0
    if query.cursor:
        try:
            start_index, start_offset, expected = json.loads(base64.urlsafe_b64decode(query.cursor))
            if (
                type(start_index) is not int
                or type(start_offset) is not int
                or start_index < 0
                or start_offset < 0
                or expected != fingerprint
            ):
                raise ValueError()
        except (ValueError, TypeError, UnicodeError) as error:
            raise ValueError("搜索游标已失效，请重新搜索") from error
    chapters = sorted(
        (
            item
            for item in manifest["chapters"]
            if isinstance(item, dict)
            and type(item.get("index")) is int
            and item["index"] >= start_index
            and (query.chapterIndex is None or item["index"] == query.chapterIndex)
        ),
        key=lambda item: item["index"],
    )
    response = CachedTextResults(results=[])
    budget = [MAX_SCAN_BYTES]
    pattern = re.compile(re.escape(query.query), re.IGNORECASE)
    for chapter in chapters:
        index = chapter["index"]
        if response.scannedChapters >= MAX_SCAN_CHAPTERS or budget[0] <= 0:
            response.nextCursor = _cursor(index, 0, fingerprint)
            response.truncated = True
            break
        response.scannedChapters += 1
        try:
            content = read_cached_text(folder, chapter, query.mode, budget=budget)
        except ScanBudgetReached:
            response.scannedChapters -= 1
            response.nextCursor = _cursor(index, 0, fingerprint)
            response.truncated = True
            break
        except (ValueError, OSError):
            response.skippedChapters += 1
            response.truncated = True
            continue
        if content is None:
            response.uncachedChapters += 1
            continue
        text, _ = content
        content_hash = text_hash(text)
        for match in pattern.finditer(text, start_offset if index == start_index else 0):
            offset = match.start()
            snippet = text[max(0, offset - 60) : min(len(text), match.end() + 120)].replace("\ue000", "")
            response.results.append(
                CachedTextHit(
                    chapterTitle=str(chapter.get("title") or f"第{index}章"),
                    snippet=snippet,
                    position=AnnotationPosition(
                        chapterIndex=index,
                        contentMode=query.mode,
                        anchorType="top",
                        characterOffset=utf16_length(text[:offset]),
                        layoutKey="search-utf16-v1:" + content_hash,
                    ),
                    contentHash=content_hash,
                )
            )
            if len(response.results) >= query.limit:
                response.nextCursor = _cursor(index, match.end(), fingerprint)
                response.truncated = True
                return response
    return response
