"""Owner-scoped notes/bookmarks with revision checks and durable creation receipts."""

import json
import sqlite3
from contextlib import contextmanager
from datetime import UTC, datetime
from hashlib import sha256
from uuid import uuid4

from . import db
from .annotations_models import AnnotationCreate, AnnotationPatch, ReadingAnnotation


class AnnotationConflict(ValueError):
    pass


def ensure_annotations_schema(conn: sqlite3.Connection) -> None:
    conn.execute("""CREATE TABLE IF NOT EXISTS reading_annotations (
        id TEXT PRIMARY KEY,
        book_id TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
        owner_id TEXT NOT NULL,
        client_key TEXT NOT NULL,
        creation_hash TEXT NOT NULL,
        kind TEXT NOT NULL,
        label TEXT NOT NULL DEFAULT '',
        quote TEXT NOT NULL DEFAULT '',
        note TEXT NOT NULL DEFAULT '',
        position_json TEXT NOT NULL,
        content_hash TEXT,
        revision INTEGER NOT NULL DEFAULT 1,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(book_id,owner_id,client_key)
    )""")
    columns = {row[1] for row in conn.execute("PRAGMA table_info(reading_annotations)")}
    if "deleted_at" not in columns:
        conn.execute("ALTER TABLE reading_annotations ADD COLUMN deleted_at TEXT")
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_reading_annotations_owner_book ON reading_annotations(owner_id,book_id,updated_at)"
    )


def _now():
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _owned(conn, book_id: str, owner_id: str):
    if not conn.execute("SELECT 1 FROM books WHERE id=? AND owner_id=?", (book_id, owner_id)).fetchone():
        raise KeyError("未找到书籍")


def _record(row) -> ReadingAnnotation:
    return ReadingAnnotation(
        id=row["id"],
        bookId=row["book_id"],
        kind=row["kind"],
        label=row["label"],
        quote=row["quote"],
        note=row["note"],
        position=json.loads(row["position_json"]),
        contentHash=row["content_hash"],
        revision=row["revision"],
        createdAt=row["created_at"],
        updatedAt=row["updated_at"],
    )


@contextmanager
def _connection():
    with db.get_connection() as conn:
        conn.row_factory = sqlite3.Row
        yield conn


def list_annotations(
    book_id: str,
    owner_id: str,
    *,
    limit: int = 50,
    offset: int = 0,
    kind: str | None = None,
    chapter_index: int | None = None,
    mode: str | None = None,
) -> list[ReadingAnnotation]:
    with _connection() as conn:
        _owned(conn, book_id, owner_id)
        rows = conn.execute(
            "SELECT * FROM reading_annotations WHERE book_id=? AND owner_id=? AND deleted_at IS NULL"
            + (" AND kind=?" if kind else "")
            + (" AND json_extract(position_json,'$.chapterIndex')=?" if chapter_index is not None else "")
            + (" AND COALESCE(json_extract(position_json,'$.contentMode'),'original')=?" if mode else "")
            + " ORDER BY updated_at DESC,id DESC LIMIT ? OFFSET ?",
            (
                book_id,
                owner_id,
                *([kind] if kind else []),
                *([chapter_index] if chapter_index is not None else []),
                *([mode] if mode else []),
                limit,
                offset,
            ),
        ).fetchall()
        return [_record(row) for row in rows]


def get_annotation(book_id: str, owner_id: str, annotation_id: str) -> ReadingAnnotation:
    with _connection() as conn:
        row = conn.execute(
            "SELECT * FROM reading_annotations WHERE id=? AND book_id=? AND owner_id=? AND deleted_at IS NULL",
            (annotation_id, book_id, owner_id),
        ).fetchone()
        if row is None:
            raise KeyError("未找到书签或笔记")
        return _record(row)


def create_annotation(
    book_id: str, owner_id: str, payload: AnnotationCreate, content_hash: str | None
) -> ReadingAnnotation:
    fingerprint = sha256(_json(payload.model_dump()).encode()).hexdigest()
    with _connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        _owned(conn, book_id, owner_id)
        existing = conn.execute(
            "SELECT * FROM reading_annotations WHERE book_id=? AND owner_id=? AND client_key=?",
            (book_id, owner_id, payload.clientKey),
        ).fetchone()
        if existing:
            if existing["deleted_at"] is not None:
                raise AnnotationConflict("这条保存请求对应的记录已经删除，请重新创建")
            if existing["creation_hash"] != fingerprint:
                raise AnnotationConflict("此保存请求已用于另一份内容，请重新保存")
            return _record(existing)
        now = _now()
        annotation_id = "annotation-" + uuid4().hex
        conn.execute(
            """INSERT INTO reading_annotations(id,book_id,owner_id,client_key,creation_hash,kind,label,quote,note,position_json,content_hash,created_at,updated_at)
                        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                annotation_id,
                book_id,
                owner_id,
                payload.clientKey,
                fingerprint,
                payload.kind,
                payload.label,
                payload.quote,
                payload.note,
                _json(payload.position.model_dump()),
                content_hash,
                now,
                now,
            ),
        )
        row = conn.execute("SELECT * FROM reading_annotations WHERE id=?", (annotation_id,)).fetchone()
        return _record(row)


def update_annotation(
    book_id: str, owner_id: str, annotation_id: str, patch: AnnotationPatch, content_hash: str | None
) -> ReadingAnnotation:
    with _connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        _owned(conn, book_id, owner_id)
        row = conn.execute(
            "SELECT * FROM reading_annotations WHERE id=? AND book_id=? AND owner_id=? AND deleted_at IS NULL",
            (annotation_id, book_id, owner_id),
        ).fetchone()
        if row is None:
            raise KeyError("未找到书签或笔记")
        if row["revision"] != patch.expectedRevision:
            raise AnnotationConflict("其他设备已修改这条记录，请重新加载后再保存")
        changes = patch.model_dump(exclude_unset=True, exclude={"expectedRevision"})
        values = {name: changes.get(name, row[name]) for name in ("label", "quote", "note")}
        position_json = _json(changes["position"]) if "position" in changes else row["position_json"]
        updated_hash = content_hash if "position" in changes or "quote" in changes else row["content_hash"]
        if (
            all(values[name] == row[name] for name in values)
            and position_json == row["position_json"]
            and updated_hash == row["content_hash"]
        ):
            return _record(row)
        conn.execute(
            """UPDATE reading_annotations SET label=?,quote=?,note=?,position_json=?,content_hash=?,revision=revision+1,updated_at=? WHERE id=?""",
            (
                values["label"],
                values["quote"],
                values["note"],
                position_json,
                updated_hash,
                _now(),
                annotation_id,
            ),
        )
        return _record(
            conn.execute("SELECT * FROM reading_annotations WHERE id=?", (annotation_id,)).fetchone()
        )


def delete_annotation(book_id: str, owner_id: str, annotation_id: str, expected_revision: int) -> None:
    with _connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            "SELECT revision FROM reading_annotations WHERE id=? AND book_id=? AND owner_id=? AND deleted_at IS NULL",
            (annotation_id, book_id, owner_id),
        ).fetchone()
        if row is None:
            raise KeyError("未找到书签或笔记")
        if row["revision"] != expected_revision:
            raise AnnotationConflict("其他设备已修改这条记录，请重新加载后再删除")
        conn.execute(
            """UPDATE reading_annotations SET deleted_at=?,label='',quote='',note='',position_json='{}',
                content_hash=NULL,revision=revision+1 WHERE id=? AND book_id=? AND owner_id=?""",
            (_now(), annotation_id, book_id, owner_id),
        )
