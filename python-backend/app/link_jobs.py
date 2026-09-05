from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from threading import Lock
from uuid import uuid4

from .models import (
    AddBookPayload,
    BookRecord,
    LinkJobLogRecord,
    LinkJobMode,
    LinkJobRecord,
    PreviewResponse,
    TaskLogLevel,
)
from .multi_user import DEFAULT_ADMIN_USER_ID


def _now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


@dataclass
class _StoredLinkJob:
    owner_id: str
    payload: AddBookPayload
    record: LinkJobRecord
    next_sequence: int = 1


class LinkJobStore:
    """保存当前桌面会话中的链接解析/导入任务状态。"""

    def __init__(self) -> None:
        self._jobs: dict[str, _StoredLinkJob] = {}
        self._idempotency_keys: dict[tuple[str, str], str] = {}
        self._creation_lock = Lock()

    def create_or_get(
        self,
        mode: LinkJobMode,
        payload: AddBookPayload,
        owner_id: str = DEFAULT_ADMIN_USER_ID,
        idempotency_key: str | None = None,
    ) -> tuple[LinkJobRecord, bool]:
        """Deduplicate one client operation for the lifetime of its stored job."""
        with self._creation_lock:
            key = (owner_id, idempotency_key) if idempotency_key is not None else None
            if key is not None and key in self._idempotency_keys:
                existing = self._require(self._idempotency_keys[key])
                if existing.record.mode != mode or existing.payload != payload:
                    raise ValueError("Idempotency-Key 已用于不同的链接任务，请为新操作生成新的键。")
                return existing.record.model_copy(deep=True), False
            job = self.create(mode, payload, owner_id)
            if key is not None:
                self._idempotency_keys[key] = job.id
            return job, True

    def create(
        self,
        mode: LinkJobMode,
        payload: AddBookPayload,
        owner_id: str = DEFAULT_ADMIN_USER_ID,
    ) -> LinkJobRecord:
        timestamp = _now()
        record = LinkJobRecord(
            id=f"link-{uuid4()}",
            mode=mode,
            status="queued",
            progress=0,
            message="等待解析",
            createdAt=timestamp,
            updatedAt=timestamp,
        )
        self._jobs[record.id] = _StoredLinkJob(
            owner_id=owner_id,
            payload=payload.model_copy(deep=True),
            record=record,
        )
        return record.model_copy(deep=True)

    def get(self, job_id: str, owner_id: str | None = None) -> LinkJobRecord:
        stored = self._require(job_id)
        self._check_owner(stored, job_id, owner_id)
        return stored.record.model_copy(deep=True)

    def payload_for(self, job_id: str, owner_id: str | None = None) -> AddBookPayload:
        stored = self._require(job_id)
        self._check_owner(stored, job_id, owner_id)
        return stored.payload.model_copy(deep=True)

    def owner_for(self, job_id: str) -> str:
        return self._require(job_id).owner_id

    def start(self, job_id: str, message: str) -> LinkJobRecord:
        stored = self._require(job_id)
        stored.record.status = "running"
        stored.record.message = message.strip()
        stored.record.updatedAt = _now()
        return stored.record.model_copy(deep=True)

    def append_log(
        self,
        job_id: str,
        level: TaskLogLevel,
        message: str,
        *,
        progress: float | None = None,
    ) -> LinkJobLogRecord:
        stored = self._require(job_id)
        timestamp = _now()
        log = LinkJobLogRecord(
            sequence=stored.next_sequence,
            level=level,
            message=message.strip(),
            createdAt=timestamp,
        )
        stored.next_sequence += 1
        stored.record.logs.append(log)
        stored.record.message = log.message
        if progress is not None:
            stored.record.progress = max(0, min(100, progress))
        stored.record.updatedAt = timestamp
        return log.model_copy(deep=True)

    def complete(
        self,
        job_id: str,
        message: str,
        *,
        preview: PreviewResponse | None = None,
        book: BookRecord | None = None,
    ) -> LinkJobRecord:
        stored = self._require(job_id)
        stored.record.status = "completed"
        stored.record.progress = 100
        stored.record.message = message.strip()
        stored.record.preview = preview.model_copy(deep=True) if preview is not None else None
        stored.record.book = book.model_copy(deep=True) if book is not None else None
        stored.record.error = None
        stored.record.updatedAt = _now()
        self.append_log(job_id, "info", message, progress=100)
        return stored.record.model_copy(deep=True)

    def fail(self, job_id: str, error: Exception | str) -> LinkJobRecord:
        stored = self._require(job_id)
        message = str(error).strip() or "链接任务执行失败"
        stored.record.status = "failed"
        stored.record.error = message
        stored.record.updatedAt = _now()
        self.append_log(job_id, "error", message)
        return stored.record.model_copy(deep=True)

    def logs_after(self, job_id: str, sequence: int) -> list[LinkJobLogRecord]:
        stored = self._require(job_id)
        return [item.model_copy(deep=True) for item in stored.record.logs if item.sequence > max(0, sequence)]

    def _require(self, job_id: str) -> _StoredLinkJob:
        try:
            return self._jobs[job_id]
        except KeyError as exc:
            raise KeyError(f"未找到链接任务：{job_id}") from exc

    @staticmethod
    def _check_owner(stored: _StoredLinkJob, job_id: str, owner_id: str | None) -> None:
        if owner_id is not None and stored.owner_id != owner_id:
            raise KeyError(f"未找到链接任务：{job_id}")
