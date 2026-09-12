"""Durable per-owner serial tracking preferences and check receipts."""

from __future__ import annotations

import sqlite3
from datetime import UTC, datetime, timedelta

from . import db


def timestamp(value: datetime | None = None) -> str:
    return (value or datetime.now(UTC)).isoformat().replace("+00:00", "Z")


def ensure_book_updates_schema(conn: sqlite3.Connection) -> None:
    conn.execute("""CREATE TABLE IF NOT EXISTS book_updates (
        book_id TEXT PRIMARY KEY REFERENCES books(id) ON DELETE CASCADE,
        owner_id TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 0,
        interval_hours INTEGER NOT NULL DEFAULT 6,
        auto_download INTEGER NOT NULL DEFAULT 0,
        acknowledged_index INTEGER NOT NULL DEFAULT 0,
        last_attempt_at TEXT,
        last_checked_at TEXT,
        next_check_at TEXT,
        last_error TEXT,
        revision INTEGER NOT NULL DEFAULT 0
    )""")
    columns = {row[1] for row in conn.execute("PRAGMA table_info(book_updates)")}
    for name, declaration in {
        "source_status": "TEXT NOT NULL DEFAULT 'unknown'",
        "source_status_evidence": "TEXT",
        "source_status_checked_at": "TEXT",
        "supported": "INTEGER NOT NULL DEFAULT 0",
        "unsupported_reason": "TEXT",
    }.items():
        if name not in columns:
            conn.execute(f"ALTER TABLE book_updates ADD COLUMN {name} {declaration}")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_book_updates_due ON book_updates(enabled,next_check_at)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_book_updates_owner ON book_updates(owner_id,book_id)")


class UpdateConflict(ValueError):
    pass


class CheckThrottled(UpdateConflict):
    pass


def _owned(conn, book_id, owner_id):
    if not conn.execute("SELECT 1 FROM books WHERE id=? AND owner_id=?", (book_id, owner_id)).fetchone():
        raise KeyError("未找到书籍")


def _row(conn, book_id, owner_id):
    cursor = conn.execute("SELECT * FROM book_updates WHERE book_id=? AND owner_id=?", (book_id, owner_id))
    row = cursor.fetchone()
    return dict(zip((column[0] for column in cursor.description), row, strict=True)) if row else None


def get_tracking(book_id: str, owner_id: str) -> dict | None:
    with db.get_connection() as conn:
        return _row(conn, book_id, owner_id)


def list_tracking(owner_id: str | None = None) -> list[dict]:
    with db.get_connection() as conn:
        cursor = conn.execute(
            "SELECT * FROM book_updates" + (" WHERE owner_id=?" if owner_id else ""),
            (owner_id,) if owner_id else (),
        )
        columns = [column[0] for column in cursor.description]
        return [dict(zip(columns, row, strict=True)) for row in cursor.fetchall()]


def _ensure(conn, book_id: str, owner_id: str, current_index: int):
    _owned(conn, book_id, owner_id)
    conn.execute(
        """INSERT OR IGNORE INTO book_updates(book_id,owner_id,acknowledged_index)
                    VALUES(?,?,?)""",
        (book_id, owner_id, current_index),
    )


def check_interval_hours(source_status: str, interval_hours: int) -> int:
    # Unknown is a metadata confirmation, not evidence that a book is ongoing.
    return max(24, interval_hours) if source_status == "unknown" else interval_hours


def sync_automatic(
    book_id: str,
    owner_id: str,
    *,
    current_index: int,
    source_status: str,
    evidence: str | None,
    checked_at: str | None,
    supported: bool,
    unsupported_reason: str | None,
    now: datetime,
) -> dict:
    with db.get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        existed = _row(conn, book_id, owner_id) is not None
        _ensure(conn, book_id, owner_id, current_index)
        row = _row(conn, book_id, owner_id)
        enabled = supported and source_status != "completed"
        next_check = row["next_check_at"]
        if not enabled:
            next_check = None
        elif not row["enabled"] or next_check is None:
            if not existed and checked_at:
                observed = datetime.fromisoformat(checked_at.replace("Z", "+00:00"))
                next_check = timestamp(
                    observed + timedelta(hours=check_interval_hours(source_status, row["interval_hours"]))
                )
            else:
                next_check = timestamp(now)
        values = (
            source_status,
            evidence,
            checked_at,
            int(supported),
            unsupported_reason,
            int(enabled),
            next_check,
        )
        previous = tuple(
            row[key]
            for key in (
                "source_status",
                "source_status_evidence",
                "source_status_checked_at",
                "supported",
                "unsupported_reason",
                "enabled",
                "next_check_at",
            )
        )
        if values != previous:
            conn.execute(
                """UPDATE book_updates SET source_status=?,source_status_evidence=?,
                source_status_checked_at=?,supported=?,unsupported_reason=?,enabled=?,next_check_at=?
                WHERE book_id=? AND owner_id=?""",
                (*values, book_id, owner_id),
            )
        return _row(conn, book_id, owner_id)


def configure(
    book_id: str,
    owner_id: str,
    *,
    current_index: int,
    expected_revision: int,
    enabled: bool,
    interval_hours: int,
    auto_download: bool,
) -> dict:
    with db.get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        _ensure(conn, book_id, owner_id, current_index)
        row = _row(conn, book_id, owner_id)
        if row["revision"] != expected_revision:
            raise UpdateConflict("其他设备已修改追更设置，请重新加载")
        changed = (bool(row["enabled"]), row["interval_hours"], bool(row["auto_download"])) != (
            enabled,
            interval_hours,
            auto_download,
        )
        if changed:
            next_check = timestamp() if enabled else None
            conn.execute(
                """UPDATE book_updates SET enabled=?, interval_hours=?, auto_download=?,
                            next_check_at=?,revision=revision+1 WHERE book_id=? AND owner_id=?""",
                (int(enabled), interval_hours, int(auto_download), next_check, book_id, owner_id),
            )
        return _row(conn, book_id, owner_id)


def claim_check(
    book_id: str, owner_id: str, *, current_index: int, now: datetime, minimum_interval: int = 30
) -> dict:
    with db.get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        _ensure(conn, book_id, owner_id, current_index)
        row = _row(conn, book_id, owner_id)
        previous = row["last_attempt_at"]
        if (
            previous
            and (now - datetime.fromisoformat(previous.replace("Z", "+00:00"))).total_seconds()
            < minimum_interval
        ):
            raise CheckThrottled("检查过于频繁，请稍后再试")
        # A crash after manifest publication will be retried, without resetting the acknowledgement.
        conn.execute(
            """UPDATE book_updates SET last_attempt_at=?,next_check_at=?
                        WHERE book_id=? AND owner_id=?""",
            (timestamp(now), timestamp(now + timedelta(minutes=5)), book_id, owner_id),
        )
        return _row(conn, book_id, owner_id)


def complete_check(book_id: str, owner_id: str, *, chapters: list[dict], now: datetime) -> None:
    with db.get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        _owned(conn, book_id, owner_id)
        row = _row(conn, book_id, owner_id)
        if row is None:
            raise KeyError("追更记录已移除")
        translated_count = sum(bool(chapter.get("translated")) for chapter in chapters)
        downloaded_count = sum(bool(chapter.get("downloaded")) for chapter in chapters)
        count = len(chapters)
        status = (
            "已完成"
            if count and translated_count == count
            else "已下载"
            if count and downloaded_count == count
            else "解析中"
            if downloaded_count
            else "待处理"
        )
        # Only counters change here: never write back an old BookRecord snapshot.
        conn.execute(
            """UPDATE books SET chapter_count=?,translated=?,status=?,updated_at=?
                        WHERE id=? AND owner_id=? AND (chapter_count!=? OR translated!=? OR status!=?)""",
            (
                count,
                int(translated_count > 0),
                status,
                timestamp(now),
                book_id,
                owner_id,
                count,
                int(translated_count > 0),
                status,
            ),
        )
        conn.execute(
            """UPDATE book_updates SET last_checked_at=?,last_error=NULL,next_check_at=?
                        WHERE book_id=? AND owner_id=?""",
            (
                timestamp(now),
                timestamp(
                    now + timedelta(hours=check_interval_hours(row["source_status"], row["interval_hours"]))
                )
                if row["enabled"]
                else None,
                book_id,
                owner_id,
            ),
        )


def record_failure(book_id: str, owner_id: str, error: str, now: datetime) -> None:
    with db.get_connection() as conn:
        conn.execute(
            """UPDATE book_updates SET last_error=?,next_check_at=CASE WHEN enabled=1 THEN ? ELSE NULL END
                        WHERE book_id=? AND owner_id=?""",
            (error[:2000], timestamp(now + timedelta(minutes=5)), book_id, owner_id),
        )


def acknowledge(book_id: str, owner_id: str, *, through_index: int, current_index: int) -> dict:
    if through_index > current_index:
        raise ValueError("确认位置超出当前目录，请刷新后重试")
    with db.get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        _ensure(conn, book_id, owner_id, current_index)
        conn.execute(
            """UPDATE book_updates SET acknowledged_index=MAX(acknowledged_index,?)
                        WHERE book_id=? AND owner_id=?""",
            (through_index, book_id, owner_id),
        )
        return _row(conn, book_id, owner_id)


def has_running_task(book_id: str) -> bool:
    with db.get_connection() as conn:
        return (
            conn.execute(
                "SELECT 1 FROM tasks WHERE book_id=? AND status IN ('running','pause_requested','cancel_requested') LIMIT 1",
                (book_id,),
            ).fetchone()
            is not None
        )
