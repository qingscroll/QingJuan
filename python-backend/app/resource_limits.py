"""Per-account limits and durable, atomic daily provider-request reservations."""

from __future__ import annotations

from contextlib import contextmanager
from contextvars import ContextVar
from datetime import UTC, datetime, timedelta

from pydantic import BaseModel, ConfigDict, Field

from . import db


class ResourceLimitError(RuntimeError):
    def __init__(self, message: str, status_code: int = 429):
        super().__init__(message)
        self.status_code = status_code


class ResourceLimitView(BaseModel):
    storageBytes: int | None = None
    dailyModelRequests: int | None = None
    revision: int = 0


class ResourceLimitPatch(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    expectedRevision: int = Field(ge=0)
    storageBytes: int | None = Field(default=None, ge=0, le=1_000_000_000_000_000)
    dailyModelRequests: int | None = Field(default=None, ge=0, le=10_000_000)


class ResourceUsage(BaseModel):
    limits: ResourceLimitView
    modelRequests: int
    day: str
    resetsAt: str
    storageUsedBytes: int


ACTOR: ContextVar[str | None] = ContextVar("resource_actor", default=None)


@contextmanager
def resource_actor(owner_id: str):
    token = ACTOR.set(owner_id)
    try:
        yield
    finally:
        ACTOR.reset(token)


def ensure_resource_limits_schema(conn):
    conn.execute("""CREATE TABLE IF NOT EXISTS resource_limits (
        owner_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        storage_bytes INTEGER CHECK (storage_bytes >= 0),
        daily_model_requests INTEGER CHECK (daily_model_requests >= 0),
        revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0))""")
    conn.execute("""CREATE TABLE IF NOT EXISTS daily_resource_usage (
        owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        day TEXT NOT NULL,
        model_requests INTEGER NOT NULL DEFAULT 0 CHECK (model_requests >= 0),
        PRIMARY KEY (owner_id, day))""")


def _assert_owner(conn, owner_id: str):
    if not conn.execute("SELECT 1 FROM users WHERE id=?", (owner_id,)).fetchone():
        raise ResourceLimitError("用户不存在", 404)


def _limit(conn, owner_id: str) -> ResourceLimitView:
    _assert_owner(conn, owner_id)
    row = conn.execute(
        "SELECT storage_bytes,daily_model_requests,revision FROM resource_limits WHERE owner_id=?",
        (owner_id,),
    ).fetchone()
    return ResourceLimitView(storageBytes=row[0], dailyModelRequests=row[1], revision=row[2]) if row else ResourceLimitView()


def get_limit(owner_id: str) -> ResourceLimitView:
    with db.get_connection() as conn:
        return _limit(conn, owner_id)


def update_limit(owner_id: str, payload: ResourceLimitPatch) -> ResourceLimitView:
    with db.get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        current = _limit(conn, owner_id)
        if current.revision != payload.expectedRevision:
            raise ResourceLimitError("资源限制已变化，请刷新后重试", 409)
        result = ResourceLimitView(storageBytes=payload.storageBytes,
            dailyModelRequests=payload.dailyModelRequests, revision=current.revision + 1)
        conn.execute("""INSERT INTO resource_limits VALUES(?,?,?,?)
            ON CONFLICT(owner_id) DO UPDATE SET storage_bytes=excluded.storage_bytes,
            daily_model_requests=excluded.daily_model_requests,revision=excluded.revision""",
            (owner_id, result.storageBytes, result.dailyModelRequests, result.revision))
        return result


def _utc(instant: datetime | None) -> datetime:
    return (instant or datetime.now(UTC)).astimezone(UTC)


def get_usage(owner_id: str, *, instant: datetime | None = None) -> ResourceUsage:
    from .storage_meter import measure_owner_storage

    today = _utc(instant).date()
    with db.get_connection() as conn:
        limits = _limit(conn, owner_id)
        row = conn.execute("SELECT model_requests FROM daily_resource_usage WHERE owner_id=? AND day=?",
            (owner_id, today.isoformat())).fetchone()
    return ResourceUsage(limits=limits, modelRequests=row[0] if row else 0,
        day=today.isoformat(), resetsAt=f"{today + timedelta(days=1)}T00:00:00Z",
        storageUsedBytes=measure_owner_storage(owner_id))


def reserve_model_request(owner_id: str, *, instant: datetime | None = None) -> None:
    """Count attempted requests before I/O; retries and uncertain failures consume budget."""
    today = _utc(instant).date()
    with db.get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        limit = _limit(conn, owner_id).dailyModelRequests
        row = conn.execute("SELECT model_requests FROM daily_resource_usage WHERE owner_id=? AND day=?",
            (owner_id, today.isoformat())).fetchone()
        used = row[0] if row else 0
        if limit is not None and used >= limit:
            raise ResourceLimitError("今日模型请求次数已达上限，UTC 次日 00:00 重置；可联系管理员调整限制")
        conn.execute("""INSERT INTO daily_resource_usage VALUES(?,?,1)
            ON CONFLICT(owner_id,day) DO UPDATE SET model_requests=model_requests+1""",
            (owner_id, today.isoformat()))
        conn.execute("DELETE FROM daily_resource_usage WHERE owner_id=? AND day<?",
            (owner_id, (today - timedelta(days=90)).isoformat()))


def reserve_current_model_request() -> None:
    from .translation_quality_usage import CURRENT

    quality = CURRENT.get()
    owner_id = quality.book.ownerId if quality is not None else ACTOR.get()
    if owner_id is not None:
        reserve_model_request(owner_id)
