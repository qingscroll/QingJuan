from __future__ import annotations

import json
import sqlite3
import uuid
from datetime import UTC, datetime

from .translation_quality_models import TranslationHistoryItem, TranslationQualityError, TranslationRevision


def now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def ensure_translation_quality_schema(conn: sqlite3.Connection) -> None:
    conn.execute("""CREATE TABLE IF NOT EXISTS book_glossaries (
        book_id TEXT PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
        owner_id TEXT NOT NULL, entries_json TEXT NOT NULL, revision INTEGER NOT NULL, updated_at TEXT NOT NULL
    )""")
    conn.execute("""CREATE TABLE IF NOT EXISTS translation_quality_state (
        book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE, chapter_index INTEGER NOT NULL,
        owner_id TEXT NOT NULL, revision INTEGER NOT NULL, source_hash TEXT NOT NULL,
        translation_hash TEXT NOT NULL, PRIMARY KEY(book_id, chapter_index)
    )""")
    conn.execute("""CREATE TABLE IF NOT EXISTS translation_quality_history (
        id TEXT PRIMARY KEY, book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
        owner_id TEXT NOT NULL, chapter_index INTEGER NOT NULL, revision INTEGER NOT NULL,
        kind TEXT NOT NULL, source_hash TEXT NOT NULL, translation_hash TEXT NOT NULL,
        content TEXT NOT NULL, created_at TEXT NOT NULL, UNIQUE(book_id,chapter_index,revision)
    )""")
    conn.execute("""CREATE TABLE IF NOT EXISTS translation_quality_usage (
        id TEXT PRIMARY KEY, book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
        owner_id TEXT NOT NULL, chapter_index INTEGER NOT NULL, record_json TEXT NOT NULL, created_at TEXT NOT NULL
    )""")
    conn.execute("""CREATE TABLE IF NOT EXISTS translation_quality_requests (
        book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE, owner_id TEXT NOT NULL,
        chapter_index INTEGER NOT NULL, operation_id TEXT NOT NULL, payload_hash TEXT NOT NULL,
        status TEXT NOT NULL, result_json TEXT, created_at TEXT NOT NULL,
        PRIMARY KEY(owner_id, operation_id)
    )""")
    for table in ("translation_quality_history", "translation_quality_usage", "translation_quality_requests"):
        conn.execute(f"CREATE INDEX IF NOT EXISTS idx_{table}_owner ON {table}(owner_id,book_id,created_at)")


def assert_owned(conn, book) -> None:
    if not conn.execute("SELECT 1 FROM books WHERE id=? AND owner_id=?", (book.id, book.ownerId)).fetchone():
        raise TranslationQualityError("未找到书籍", 404)


def assert_idle(conn, book) -> None:
    if conn.execute(
        """SELECT 1 FROM tasks WHERE book_id=? AND status IN
        ('running','pause_requested','cancel_requested') LIMIT 1""",
        (book.id,),
    ).fetchone():
        raise TranslationQualityError("书籍仍有任务正在执行，请先暂停并等待当前章节完成", 409)


def state(conn, book, index: int):
    return conn.execute(
        """SELECT revision,source_hash,translation_hash FROM translation_quality_state
        WHERE book_id=? AND owner_id=? AND chapter_index=?""",
        (book.id, book.ownerId, index),
    ).fetchone()


def _history(row, *, with_text=False):
    values = dict(
        id=row[0], revision=row[1], kind=row[2], createdAt=row[3], sourceHash=row[4], translationHash=row[5]
    )
    return TranslationRevision(**values, text=row[6]) if with_text else TranslationHistoryItem(**values)


def history(conn, book, index: int):
    rows = conn.execute(
        """SELECT id,revision,kind,created_at,source_hash,translation_hash
        FROM translation_quality_history WHERE book_id=? AND owner_id=? AND chapter_index=?
        ORDER BY revision DESC LIMIT 100""",
        (book.id, book.ownerId, index),
    ).fetchall()
    return [_history(row) for row in rows]


def history_item(conn, book, index: int, item_id: str):
    row = conn.execute(
        """SELECT id,revision,kind,created_at,source_hash,translation_hash,content
        FROM translation_quality_history WHERE id=? AND book_id=? AND owner_id=? AND chapter_index=?""",
        (item_id, book.id, book.ownerId, index),
    ).fetchone()
    if row is None:
        raise TranslationQualityError("未找到译文历史版本", 404)
    return _history(row, with_text=True)


def insert_history(conn, book, index, revision, kind, source_hash, translated_hash, text):
    conn.execute(
        """INSERT INTO translation_quality_history VALUES(?,?,?,?,?,?,?,?,?,?)""",
        (
            uuid.uuid4().hex,
            book.id,
            book.ownerId,
            index,
            revision,
            kind,
            source_hash,
            translated_hash,
            text,
            now(),
        ),
    )
    conn.execute(
        """DELETE FROM translation_quality_history WHERE book_id=? AND chapter_index=?
        AND id NOT IN (SELECT id FROM translation_quality_history WHERE book_id=? AND chapter_index=?
        ORDER BY revision DESC LIMIT 100)""",
        (book.id, index, book.id, index),
    )


def glossary(conn, book):
    row = conn.execute(
        "SELECT entries_json,revision,updated_at FROM book_glossaries WHERE book_id=? AND owner_id=?",
        (book.id, book.ownerId),
    ).fetchone()
    return (json.loads(row[0]), row[1], row[2]) if row else ([], 0, None)
