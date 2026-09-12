"""Bounded chapter I/O and recoverable publication of SQLite-backed revisions."""

from __future__ import annotations

import hashlib
import json
import os
import re
import threading
from dataclasses import dataclass
from pathlib import Path
from tempfile import NamedTemporaryFile

from . import db
from .storage_quota import quota_write_text
from .translation_quality_models import MAX_TEXT_BYTES, MAX_TEXT_CHARS, TranslationQualityError

WRITE_LOCK = threading.RLock()


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def safe_child(directory: Path, name: str) -> Path:
    if not name or name in {".", ".."} or any(char in name for char in "/\\:\x00"):
        raise TranslationQualityError("章节存储记录无效")
    target = directory / name
    if target.is_symlink() or getattr(target, "is_junction", lambda: False)():
        raise TranslationQualityError("章节不能使用符号链接")
    if target.resolve().parent != directory.resolve():
        raise TranslationQualityError("章节存储记录无效")
    return target


def book_directory(book) -> Path:
    library = (db.DATA_DIR / "library").resolve()
    raw = Path(book.localPath or "")
    directory = raw if raw.is_absolute() else db.DATA_DIR / raw
    resolved = directory.resolve()
    if resolved == library or not resolved.is_relative_to(library) or not resolved.is_dir():
        raise TranslationQualityError("书籍目录不可用，请重新加载书库", 409)
    current = directory
    while current != db.DATA_DIR and current != current.parent:
        if current.is_symlink() or getattr(current, "is_junction", lambda: False)():
            raise TranslationQualityError("书籍目录不能使用符号链接")
        current = current.parent
    return resolved


def read_text(path: Path, *, optional=False) -> str:
    if optional and not path.exists():
        return ""
    if not path.is_file():
        raise TranslationQualityError("章节尚未下载，请先下载正文", 409)
    if path.stat().st_size > MAX_TEXT_BYTES:
        raise TranslationQualityError("校对只支持 1 MiB 以内的小说章节", 413)
    try:
        value = path.read_text(encoding="utf-8")
    except UnicodeError:
        raise TranslationQualityError("章节文本编码无效") from None
    if len(value) > MAX_TEXT_CHARS or "\x00" in value:
        raise TranslationQualityError("校对只支持 20 万字符以内的有效小说文本", 413)
    return value


@dataclass(frozen=True)
class ChapterFiles:
    directory: Path
    source: Path
    translated: Path
    journal: Path
    title: str
    source_text: str
    translated_text: str


def chapter_files(book, index: int) -> ChapterFiles:
    if book.bookKind == "漫画":
        raise TranslationQualityError("译文校对仅适用于已下载的小说章节")
    directory = book_directory(book)
    manifest_path = safe_child(directory, "manifest.json")
    if not manifest_path.is_file() or manifest_path.stat().st_size > 32 * 1024 * 1024:
        raise TranslationQualityError("小说章节清单不可用", 409)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        chapter = next(item for item in manifest["chapters"] if item.get("index") == index)
        source = safe_child(directory, chapter["file_name"])
    except (ValueError, KeyError, TypeError, StopIteration, AttributeError):
        raise TranslationQualityError("未找到有效的小说章节", 404) from None
    translated = safe_child(directory, f"{source.stem}.translated.txt")
    journal = safe_child(directory, f".translation-quality-{index}.json")
    if journal.exists():
        recover_journal(journal)
    return ChapterFiles(
        directory,
        source,
        translated,
        journal,
        str(chapter.get("title", f"第{index}章")),
        read_text(source),
        read_text(translated, optional=True),
    )


def atomic_write(path: Path, content: str, *, connection=None, owner_id=None) -> None:
    quota_write_text(path, content, connection=connection, owner_id=owner_id)


def _restore_write(path: Path, content: str) -> None:
    """Recovery must retain the old committed bytes even after limits were reduced."""
    temporary = None
    try:
        with NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="",
            dir=path.parent,
            prefix=".quality-",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def prepare_journal(files, book, index, revision, text, *, connection=None):
    atomic_write(
        files.journal,
        json.dumps(
            {
                "bookId": book.id,
                "ownerId": book.ownerId,
                "chapterIndex": index,
                "revision": revision,
                "fileName": files.translated.name,
                "oldText": files.translated.read_bytes().decode("utf-8")
                if files.translated.exists()
                else None,
                "newHash": digest(text),
                "oldHash": digest(files.translated_text),
            },
            ensure_ascii=False,
        ),
        connection=connection,
        owner_id=book.ownerId,
    )


def recover_journal(journal: Path) -> None:
    if journal.is_symlink() or journal.stat().st_size > MAX_TEXT_BYTES * 7:
        raise TranslationQualityError("译文恢复记录无效，请检查书库", 503)
    try:
        item = json.loads(journal.read_text(encoding="utf-8"))
        book = db.get_book(item["bookId"], item["ownerId"])
        if book is None or book_directory(book) != journal.parent.resolve():
            raise ValueError
        if (
            not isinstance(item["chapterIndex"], int)
            or journal.name != f".translation-quality-{item['chapterIndex']}.json"
        ):
            raise ValueError
        if not isinstance(item["revision"], int) or item["revision"] < 1:
            raise ValueError
        if any(
            not isinstance(item[key], str) or not re.fullmatch(r"[0-9a-f]{64}", item[key])
            for key in ("oldHash", "newHash")
        ):
            raise ValueError
        manifest_path = safe_child(journal.parent, "manifest.json")
        if manifest_path.stat().st_size > 32 * 1024 * 1024:
            raise ValueError
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        chapter = next(
            chapter for chapter in manifest["chapters"] if chapter.get("index") == item["chapterIndex"]
        )
        source = safe_child(journal.parent, chapter["file_name"])
        if item["fileName"] != f"{source.stem}.translated.txt":
            raise ValueError
        target = safe_child(journal.parent, item["fileName"])
        old = item["oldText"]
        if old is not None and (not isinstance(old, str) or len(old.encode("utf-8")) > MAX_TEXT_BYTES):
            raise ValueError
        if digest((old or "").replace("\r\n", "\n").replace("\r", "\n")) != item["oldHash"]:
            raise ValueError
        with db.get_connection() as conn:
            row = conn.execute(
                """SELECT revision,translation_hash FROM translation_quality_state
                WHERE book_id=? AND owner_id=? AND chapter_index=?""",
                (book.id, book.ownerId, item["chapterIndex"]),
            ).fetchone()
        actual = digest(read_text(target, optional=True))
        if actual not in {item["oldHash"], item["newHash"]}:
            raise ValueError
        committed = row and row[0] == item["revision"] and row[1] == item["newHash"]
        if committed:
            if actual != item["newHash"]:
                raise ValueError
        elif old is None:
            target.unlink(missing_ok=True)
        else:
            _restore_write(target, old)
        journal.unlink()
    except (ValueError, KeyError, TypeError, OSError, StopIteration, AttributeError):
        raise TranslationQualityError("译文恢复未完成，请检查存储后重新启动后端", 503) from None


def recover_translation_quality_writes(data_dir: Path) -> None:
    library = data_dir / "library"
    with WRITE_LOCK:
        if library.exists():
            for journal in library.rglob(".translation-quality-*.json"):
                if not journal.resolve().is_relative_to(library.resolve()):
                    raise TranslationQualityError("译文恢复目录无效", 503)
                recover_journal(journal)
        with db.get_connection() as conn:
            conn.execute("UPDATE translation_quality_requests SET status='failed' WHERE status='running'")
