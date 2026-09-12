"""Owner-scoped metadata overlays. Source records and chapter manifests stay untouched."""

from __future__ import annotations

import json
import sqlite3
from datetime import UTC, datetime


def ensure_library_metadata_schema(conn: sqlite3.Connection) -> None:
    conn.execute("""CREATE TABLE IF NOT EXISTS book_metadata (
        book_id TEXT PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
        owner_id TEXT NOT NULL,
        metadata_json TEXT NOT NULL DEFAULT '{}',
        revision INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
    )""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_book_metadata_owner ON book_metadata(owner_id,book_id)")


def _connection():
    from .db import get_connection

    return get_connection()


def _load(conn, book_id: str, owner_id: str) -> tuple[dict, int, str | None]:
    row = conn.execute(
        "SELECT metadata_json,revision,updated_at FROM book_metadata WHERE book_id=? AND owner_id=?",
        (book_id, owner_id),
    ).fetchone()
    if row is None:
        return {}, 0, None
    return json.loads(row[0]), row[1], row[2]


def load_metadata(book_id: str, owner_id: str) -> tuple[dict, int, str | None]:
    with _connection() as conn:
        return _load(conn, book_id, owner_id)


class MetadataConflict(ValueError):
    def __init__(self, revision: int):
        super().__init__("其他设备已修改作品信息，请重新加载后再保存")
        self.revision = revision


def update_metadata(book_id: str, owner_id: str, changes: dict, *, expected_revision: int):
    with _connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        if not conn.execute("SELECT 1 FROM books WHERE id=? AND owner_id=?", (book_id, owner_id)).fetchone():
            raise KeyError("未找到书籍")
        current, revision, updated_at = _load(conn, book_id, owner_id)
        if expected_revision != revision:
            raise MetadataConflict(revision)
        next_values = {**current}
        for key, value in changes.items():
            if value is None:
                next_values.pop(key, None)
            else:
                next_values[key] = value
        if next_values == current:
            return current, revision, updated_at
        revision += 1
        updated_at = datetime.now(UTC).isoformat().replace("+00:00", "Z")
        conn.execute(
            """INSERT INTO book_metadata(book_id,owner_id,metadata_json,revision,updated_at)
            VALUES(?,?,?,?,?) ON CONFLICT(book_id) DO UPDATE SET
            metadata_json=excluded.metadata_json,revision=excluded.revision,updated_at=excluded.updated_at""",
            (book_id, owner_id, json.dumps(next_values, ensure_ascii=False), revision, updated_at),
        )
        return next_values, revision, updated_at
