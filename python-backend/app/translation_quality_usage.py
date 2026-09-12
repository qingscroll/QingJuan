"""Only structured provider usage is persisted; prompts and errors are never logged."""

from __future__ import annotations

import json
import sqlite3
import uuid
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass, field
from pathlib import Path

from . import db
from .translation_quality_models import TranslationUsage
from .translation_quality_repository import now


@dataclass
class QualityContext:
    book: object
    index: int
    operation: str
    entries: list[dict] = field(default_factory=list)
    usage: TranslationUsage | None = None


CURRENT: ContextVar[QualityContext | None] = ContextVar("translation_quality_context", default=None)


def find_book(directory: Path):
    if not db.DB_PATH.is_file():
        return None
    try:
        key = directory.resolve().relative_to(db.DATA_DIR.resolve()).as_posix()
    except ValueError:
        return None
    with db.get_connection() as conn:
        row = conn.execute(
            "SELECT id FROM books WHERE local_path IN (?,?)", (key, str(directory.resolve()))
        ).fetchone()
    return db.get_book(row[0]) if row else None


@contextmanager
def translation_context(book, index, operation="translate"):
    from .translation_quality_service import get_glossary

    context = QualityContext(
        book, index, operation, [entry.model_dump() for entry in get_glossary(book).entries]
    )
    token = CURRENT.set(context)
    try:
        yield context
    finally:
        CURRENT.reset(token)


@contextmanager
def book_translation_context(directory: Path, index: int):
    book = find_book(directory)
    if book is None or book.bookKind == "漫画":
        yield None
    else:
        with translation_context(book, index) as context:
            yield context


def glossary_instruction(content: str) -> str:
    context = CURRENT.get()
    entries = (
        [entry for entry in context.entries if entry["source"].casefold() in content.casefold()]
        if context
        else []
    )
    if not entries:
        return ""
    return (
        "\n术语表数据（source 为原文，target 为统一译名；kind=name 为人名）：\n"
        + json.dumps(entries, ensure_ascii=False)
        + "\n"
    )


def record_model_usage(model: str, response: dict | None, status: str, duration_ms: int):
    context = CURRENT.get()
    if context is None:
        return
    raw = response.get("usage", {}) if isinstance(response, dict) else {}
    raw = raw if isinstance(raw, dict) else {}

    def count(*names):
        for name in names:
            value = raw.get(name)
            if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 1_000_000_000:
                return value
        return None

    usage = TranslationUsage(
        id=uuid.uuid4().hex,
        chapterIndex=context.index,
        operation=context.operation,
        model=str(model)[:120],
        inputTokens=count("prompt_tokens", "input_tokens"),
        outputTokens=count("completion_tokens", "output_tokens"),
        totalTokens=count("total_tokens"),
        durationMs=max(0, duration_ms),
        status=status,
        createdAt=now(),
    )
    context.usage = usage
    try:
        with db.get_connection() as conn:
            if not conn.execute(
                "SELECT 1 FROM books WHERE id=? AND owner_id=?", (context.book.id, context.book.ownerId)
            ).fetchone():
                return
            conn.execute(
                "INSERT INTO translation_quality_usage VALUES(?,?,?,?,?,?)",
                (
                    usage.id,
                    context.book.id,
                    context.book.ownerId,
                    context.index,
                    usage.model_dump_json(),
                    usage.createdAt,
                ),
            )
            conn.execute(
                """DELETE FROM translation_quality_usage WHERE book_id=? AND id NOT IN
                (SELECT id FROM translation_quality_usage WHERE book_id=? ORDER BY created_at DESC,id DESC LIMIT 1000)""",
                (context.book.id, context.book.id),
            )
    except sqlite3.Error:
        # Recording cannot trigger another paid request or discard a valid model result.
        context.usage = None


def list_usage(book):
    with db.get_connection() as conn:
        rows = conn.execute(
            """SELECT record_json FROM translation_quality_usage WHERE book_id=? AND owner_id=?
            ORDER BY created_at DESC,id DESC LIMIT 100""",
            (book.id, book.ownerId),
        ).fetchall()
    return [TranslationUsage.model_validate_json(row[0]) for row in rows]
