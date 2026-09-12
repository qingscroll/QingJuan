"""Owner-scoped reading positions with optimistic writes and durable receipts."""

from __future__ import annotations

import hashlib
import json
import sqlite3

from .models import ReadingProgressRecord
from .multi_user import DEFAULT_ADMIN_USER_ID

_FIELDS = {
    "lastChapterIndex": "last_chapter_index",
    "lastScrollRatio": "last_scroll_ratio",
    "lastAnchorType": "last_anchor_type",
    "lastAnchorIndex": "last_anchor_index",
    "lastAnchorOffsetRatio": "last_anchor_offset_ratio",
    "lastReadAt": "last_read_at",
    "lastPageIndex": "last_page_index",
    "lastPageCount": "last_page_count",
    "lastLayoutKey": "last_layout_key",
    "lastContentMode": "last_content_mode",
    "lastCharacterOffset": "last_character_offset",
}


def ensure_reading_progress_schema(conn: sqlite3.Connection) -> None:
    columns = {row[1] for row in conn.execute("PRAGMA table_info(reading_progress)")}
    if "revision" not in columns:
        conn.execute("ALTER TABLE reading_progress ADD COLUMN revision INTEGER NOT NULL DEFAULT 0")
    if "versioned" not in columns:
        conn.execute("ALTER TABLE reading_progress ADD COLUMN versioned INTEGER NOT NULL DEFAULT 0")
    conn.execute("""CREATE TABLE IF NOT EXISTS reading_progress_receipts (
        owner_id TEXT NOT NULL, book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
        operation_id TEXT NOT NULL, payload_hash TEXT NOT NULL, result_json TEXT NOT NULL,
        revision INTEGER NOT NULL, PRIMARY KEY(owner_id,book_id,operation_id))""")
    conn.execute("""CREATE INDEX IF NOT EXISTS idx_reading_receipt_revision
        ON reading_progress_receipts(owner_id,book_id,revision DESC)""")


def _connection():
    from .db import get_connection

    return get_connection()


def _load(conn, book_id, owner_id=None) -> ReadingProgressRecord:
    fields = ",".join(_FIELDS.values())
    row = conn.execute(
        f"SELECT owner_id,{fields},revision FROM reading_progress WHERE book_id=?"
        + (" AND owner_id=?" if owner_id is not None else ""),
        (book_id, owner_id) if owner_id is not None else (book_id,),
    ).fetchone()
    if row is None:
        return ReadingProgressRecord(ownerId=owner_id or DEFAULT_ADMIN_USER_ID, bookId=book_id, revision=0)
    values = dict(zip(_FIELDS, row[1:-1], strict=True))
    return ReadingProgressRecord(ownerId=row[0], bookId=book_id, revision=row[-1], **values)


def load_progress(book_id: str, owner_id: str | None = None) -> ReadingProgressRecord:
    with _connection() as conn:
        return _load(conn, book_id, owner_id)


class ProgressConflict(ValueError):
    def __init__(self, current: ReadingProgressRecord, code: str = "reading_progress_conflict"):
        message = {
            "reading_progress_conflict": "其他设备已更新阅读进度，请选择保留哪个位置",
            "reading_progress_upgrade_required": "阅读进度已启用版本保护，请升级客户端后继续同步",
            "reading_progress_operation_reused": "阅读进度操作标识已被使用，请重新确认同步位置",
        }.get(code, "阅读进度同步冲突")
        super().__init__(message)
        self.current = current
        self.code = code


def _write(conn, progress, *, revision, versioned):
    columns = ["owner_id", "book_id", *_FIELDS.values(), "revision", "versioned"]
    values = [
        progress.ownerId,
        progress.bookId,
        *(getattr(progress, field) for field in _FIELDS),
        revision,
        versioned,
    ]
    assignments = ",".join(f"{column}=excluded.{column}" for column in columns if column != "book_id")
    conn.execute(
        f"INSERT INTO reading_progress({','.join(columns)}) VALUES({','.join('?' for _ in columns)}) "
        f"ON CONFLICT(book_id) DO UPDATE SET {assignments}",
        values,
    )
    return progress.model_copy(update={"revision": revision})


def save_progress(
    progress: ReadingProgressRecord, *, expected_revision: int | None = None, operation_id: str | None = None
) -> ReadingProgressRecord:
    if (expected_revision is None) != (operation_id is None):
        raise ValueError("进度版本与操作标识必须同时提供")
    if expected_revision is not None and (expected_revision < 0 or not 16 <= len(operation_id or "") <= 128):
        raise ValueError("进度版本或操作标识无效")
    with _connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        if not conn.execute(
            "SELECT 1 FROM books WHERE id=? AND owner_id=?", (progress.bookId, progress.ownerId)
        ).fetchone():
            raise KeyError("书籍不存在")
        current = _load(conn, progress.bookId, progress.ownerId)
        payload_hash = hashlib.sha256(
            json.dumps(
                {
                    "expectedRevision": expected_revision,
                    **{field: getattr(progress, field) for field in _FIELDS if field != "lastReadAt"},
                },
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            ).encode()
        ).hexdigest()
        if operation_id is not None:
            receipt = conn.execute(
                """SELECT payload_hash,result_json FROM reading_progress_receipts
                WHERE owner_id=? AND book_id=? AND operation_id=?""",
                (progress.ownerId, progress.bookId, operation_id),
            ).fetchone()
            if receipt:
                if receipt[0] != payload_hash:
                    raise ProgressConflict(current, "reading_progress_operation_reused")
                result = ReadingProgressRecord.model_validate_json(receipt[1])
                return result.model_copy(update={"ownerId": progress.ownerId})
        protected = conn.execute(
            "SELECT versioned FROM reading_progress WHERE book_id=?", (progress.bookId,)
        ).fetchone()
        if expected_revision is None and protected and protected[0]:
            raise ProgressConflict(current, "reading_progress_upgrade_required")
        if expected_revision is not None and current.revision != expected_revision:
            raise ProgressConflict(current)
        result = _write(
            conn, progress, revision=current.revision + 1, versioned=int(expected_revision is not None)
        )
        if operation_id is not None:
            conn.execute(
                "INSERT INTO reading_progress_receipts VALUES(?,?,?,?,?,?)",
                (
                    progress.ownerId,
                    progress.bookId,
                    operation_id,
                    payload_hash,
                    result.model_dump_json(),
                    result.revision,
                ),
            )
            # Very old offline receipts can become conflicts, but can never overwrite newer state.
            conn.execute(
                """DELETE FROM reading_progress_receipts WHERE owner_id=? AND book_id=?
                AND revision < (SELECT MIN(revision) FROM (
                    SELECT revision FROM reading_progress_receipts WHERE owner_id=? AND book_id=?
                    ORDER BY revision DESC LIMIT 256))""",
                (progress.ownerId, progress.bookId, progress.ownerId, progress.bookId),
            )
        return result


def save_progress_internal(progress: ReadingProgressRecord) -> ReadingProgressRecord:
    """Server-owned corrections are new revisions and cannot disable CAS protection."""
    with _connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        book = conn.execute("SELECT owner_id FROM books WHERE id=?", (progress.bookId,)).fetchone()
        if book is not None and book[0] != progress.ownerId:
            raise KeyError("书籍归属与阅读进度不一致")
        current = _load(conn, progress.bookId)
        protected = conn.execute(
            "SELECT versioned FROM reading_progress WHERE book_id=?", (progress.bookId,)
        ).fetchone()
        if protected is not None and current.ownerId != progress.ownerId:
            raise KeyError("书籍归属与阅读进度不一致")
        return _write(
            conn, progress, revision=current.revision + 1, versioned=int(bool(protected and protected[0]))
        )
