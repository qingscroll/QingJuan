"""SQLite adapter for the link-job state machine; no credentials are accepted."""

from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager

from . import db
from .link_jobs import LinkJobStore, _StoredLinkJob
from .models import AddBookPayload, LinkJobRecord
from .multi_user import DEFAULT_ADMIN_USER_ID


def create_schema(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS link_jobs (
            id TEXT PRIMARY KEY,
            owner_id TEXT NOT NULL,
            operation_key TEXT,
            payload TEXT NOT NULL,
            record TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            UNIQUE (owner_id, operation_key)
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_link_jobs_owner_created ON link_jobs(owner_id, created_at DESC, id DESC)")


class PersistentLinkJobStore:
    """Each mutation applies the existing state machine inside one SQLite transaction."""

    def create_or_get(self, mode, payload, owner_id=DEFAULT_ADMIN_USER_ID, idempotency_key=None):
        with db.get_connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            if idempotency_key is not None:
                row = conn.execute(
                    "SELECT id, payload, record FROM link_jobs WHERE owner_id = ? AND operation_key = ?",
                    (owner_id, idempotency_key),
                ).fetchone()
                if row is not None:
                    record = LinkJobRecord.model_validate_json(row[2])
                    if record.mode != mode or AddBookPayload.model_validate_json(row[1]) != payload:
                        raise ValueError("Idempotency-Key 已用于不同的链接任务，请为新操作生成新的键。")
                    return record, False
            record = LinkJobStore().create(mode, payload, owner_id)
            conn.execute("""
                INSERT INTO link_jobs (id, owner_id, operation_key, payload, record, status, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, (record.id, owner_id, idempotency_key, payload.model_dump_json(),
                  record.model_dump_json(), record.status, record.createdAt))
        return record, True

    def create(self, mode, payload, owner_id=DEFAULT_ADMIN_USER_ID):
        return self.create_or_get(mode, payload, owner_id)[0]

    def _read(self, conn, job_id, owner_id=None) -> _StoredLinkJob:
        row = conn.execute("SELECT owner_id, payload, record FROM link_jobs WHERE id = ?", (job_id,)).fetchone()
        if row is None or (owner_id is not None and row[0] != owner_id):
            raise KeyError("未找到链接任务")
        record = LinkJobRecord.model_validate_json(row[2])
        if record.book is not None:
            record.book.ownerId = row[0]
        return _StoredLinkJob(row[0], AddBookPayload.model_validate_json(row[1]), record,
                              max((log.sequence for log in record.logs), default=0) + 1)

    @contextmanager
    def _mutate(self, job_id, owner_id=None) -> Iterator[LinkJobStore]:
        with db.get_connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            stored = self._read(conn, job_id, owner_id)
            machine = LinkJobStore()
            machine._jobs[job_id] = stored
            yield machine
            stored.record.logs = stored.record.logs[-500:]
            conn.execute("UPDATE link_jobs SET record = ?, status = ? WHERE id = ?",
                         (stored.record.model_dump_json(), stored.record.status, job_id))

    def get(self, job_id, owner_id=None) -> LinkJobRecord:
        with db.get_connection() as conn:
            return self._read(conn, job_id, owner_id).record

    def payload_for(self, job_id, owner_id=None) -> AddBookPayload:
        with db.get_connection() as conn:
            return self._read(conn, job_id, owner_id).payload

    def owner_for(self, job_id) -> str:
        with db.get_connection() as conn:
            return self._read(conn, job_id).owner_id

    def start(self, job_id, message):
        with self._mutate(job_id) as machine:
            return machine.start(job_id, message)

    def append_log(self, job_id, level, message, *, progress=None):
        with self._mutate(job_id) as machine:
            return machine.append_log(job_id, level, message, progress=progress)

    def complete(self, job_id, message, *, preview=None, book=None):
        with self._mutate(job_id) as machine:
            return machine.complete(job_id, message, preview=preview, book=book)

    def fail(self, job_id, error):
        with self._mutate(job_id) as machine:
            return machine.fail(job_id, error)

    def defer(self, job_id):
        with self._mutate(job_id) as machine:
            return machine.defer(job_id)

    def retry(self, job_id, owner_id=None):
        with self._mutate(job_id, owner_id) as machine:
            return machine.retry(job_id, owner_id)

    def logs_after(self, job_id, sequence):
        return [item for item in self.get(job_id).logs if item.sequence > max(0, sequence)]

    def list(self, owner_id=None, *, limit=50, offset=0, active_only=False) -> list[LinkJobRecord]:
        with db.get_connection() as conn:
            query = "SELECT record FROM link_jobs"
            values = []
            conditions = []
            if owner_id is not None:
                conditions.append("owner_id = ?")
                values.append(owner_id)
            if active_only:
                conditions.append("status IN ('queued', 'running')")
            if conditions:
                query += " WHERE " + " AND ".join(conditions)
            query += " ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?"
            rows = conn.execute(query, (*values, max(1, min(limit, 100)), max(0, offset))).fetchall()
        return [LinkJobRecord.model_validate_json(row[0]) for row in rows]

    def recover(self) -> list[LinkJobRecord]:
        with db.get_connection() as conn:
            rows = conn.execute("SELECT id, status FROM link_jobs WHERE status IN ('queued', 'running') ORDER BY created_at, id").fetchall()
        return [self.defer(row[0]) if row[1] == "running" else self.get(row[0]) for row in rows]
