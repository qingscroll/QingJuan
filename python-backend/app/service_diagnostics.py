from __future__ import annotations

import os
import platform
import shutil
import threading
import time
from collections import deque
from datetime import UTC, datetime
from math import ceil
from typing import Literal

from fastapi import FastAPI
from pydantic import BaseModel, Field

from . import db
from .runtime_logs import (
    RuntimeLogReadError,
    read_runtime_logs,
    redact_runtime_log_message,
    runtime_log_file_path,
    runtime_log_storage_bytes,
)

DiagnosticStatus = Literal["healthy", "warning", "error"]


class RequestMetricsView(BaseModel):
    total: int = 0
    successful: int = 0
    clientErrors: int = 0
    serverErrors: int = 0
    averageDurationMs: float = 0
    p95DurationMs: float = 0
    sampleSize: int = 0


class DiagnosticRuntime(BaseModel):
    pythonVersion: str
    operatingSystem: str
    architecture: str


class DiagnosticStorage(BaseModel):
    totalBytes: int = 0
    usedBytes: int = 0
    freeBytes: int = 0
    databaseBytes: int = 0
    runtimeLogsBytes: int = 0


class DiagnosticWorkload(BaseModel):
    books: int = 0
    tasks: int = 0
    queuedTasks: int = 0
    runningTasks: int = 0
    failedTasks: int = 0
    pendingQueueItems: int = 0
    devices: int = 0
    onlineDevices: int = 0


class DiagnosticCheck(BaseModel):
    key: str
    label: str
    status: DiagnosticStatus
    detail: str


class DiagnosticIssue(BaseModel):
    timestamp: str
    level: Literal["warning", "error", "critical"]
    source: str
    message: str


class ServiceDiagnosticsResponse(BaseModel):
    schemaVersion: int = 1
    status: DiagnosticStatus
    generatedAt: str
    startedAt: str
    uptimeSeconds: int
    runtime: DiagnosticRuntime
    requests: RequestMetricsView
    storage: DiagnosticStorage
    workload: DiagnosticWorkload
    checks: list[DiagnosticCheck] = Field(default_factory=list)
    recentIssues: list[DiagnosticIssue] = Field(default_factory=list)


class RequestMetrics:
    """Application-local request counters with a bounded latency sample."""

    def __init__(self, *, sample_limit: int = 500) -> None:
        self._lock = threading.Lock()
        self._durations_ms: deque[float] = deque(maxlen=max(1, sample_limit))
        self._total = 0
        self._client_errors = 0
        self._server_errors = 0
        self._started_at = datetime.now(UTC)
        self._started_monotonic = time.monotonic()

    @property
    def started_at(self) -> datetime:
        return self._started_at

    def uptime_seconds(self) -> int:
        return max(0, int(time.monotonic() - self._started_monotonic))

    def record(self, status_code: int, duration_ms: float) -> None:
        with self._lock:
            self._total += 1
            if 400 <= status_code < 500:
                self._client_errors += 1
            elif status_code >= 500:
                self._server_errors += 1
            self._durations_ms.append(max(0.0, float(duration_ms)))

    def snapshot(self) -> RequestMetricsView:
        with self._lock:
            durations = list(self._durations_ms)
            total = self._total
            client_errors = self._client_errors
            server_errors = self._server_errors
        if durations:
            ordered = sorted(durations)
            p95_index = max(0, ceil(len(ordered) * 0.95) - 1)
            average_ms = sum(ordered) / len(ordered)
            p95_ms = ordered[p95_index]
        else:
            average_ms = 0.0
            p95_ms = 0.0
        return RequestMetricsView(
            total=total,
            successful=max(0, total - client_errors - server_errors),
            clientErrors=client_errors,
            serverErrors=server_errors,
            averageDurationMs=round(average_ms, 2),
            p95DurationMs=round(p95_ms, 2),
            sampleSize=len(durations),
        )


def should_track_request(path: str) -> bool:
    if path in {"/health", "/healthz", "/admin", "/admin/"}:
        return False
    return not path.startswith("/admin/assets/")


def get_request_metrics(application: FastAPI) -> RequestMetrics:
    metrics = getattr(application.state, "request_metrics", None)
    if isinstance(metrics, RequestMetrics):
        return metrics
    metrics = RequestMetrics()
    application.state.request_metrics = metrics
    return metrics


def build_service_diagnostics(application: FastAPI) -> ServiceDiagnosticsResponse:
    metrics = get_request_metrics(application)
    checks: list[DiagnosticCheck] = []

    workload, database_check = _read_workload(application)
    checks.append(database_check)

    storage, data_check, disk_check = _read_storage()
    checks.extend((data_check, disk_check))

    checks.append(_task_worker_check(application))
    recent_issues, log_check = _read_recent_issues(storage.runtimeLogsBytes)
    checks.append(log_check)

    if any(check.status == "error" for check in checks):
        overall_status: DiagnosticStatus = "error"
    elif any(check.status == "warning" for check in checks):
        overall_status = "warning"
    else:
        overall_status = "healthy"

    return ServiceDiagnosticsResponse(
        status=overall_status,
        generatedAt=_utc_now(),
        startedAt=metrics.started_at.isoformat().replace("+00:00", "Z"),
        uptimeSeconds=metrics.uptime_seconds(),
        runtime=DiagnosticRuntime(
            pythonVersion=platform.python_version(),
            operatingSystem=platform.system() or "Unknown",
            architecture=platform.machine() or "Unknown",
        ),
        requests=metrics.snapshot(),
        storage=storage,
        workload=workload,
        checks=checks,
        recentIssues=recent_issues,
    )


def _read_workload(application: FastAPI) -> tuple[DiagnosticWorkload, DiagnosticCheck]:
    try:
        with db.get_connection() as connection:
            connection.execute("SELECT 1").fetchone()
        books = db.list_books()
        tasks = db.list_tasks()
        devices = db.list_devices()
    except Exception:
        return (
            DiagnosticWorkload(),
            DiagnosticCheck(
                key="database",
                label="SQLite 数据库",
                status="error",
                detail="数据库或统计信息暂时无法读取",
            ),
        )

    queue = getattr(application.state, "task_queue", None)
    queue_size = 0
    qsize = getattr(queue, "qsize", None)
    if callable(qsize):
        try:
            queue_size = max(0, int(qsize()))
        except (TypeError, ValueError):
            queue_size = 0

    return (
        DiagnosticWorkload(
            books=len(books),
            tasks=len(tasks),
            queuedTasks=sum(task.status == "queued" for task in tasks),
            runningTasks=sum(task.status in {"running", "pause_requested", "cancel_requested"} for task in tasks),
            failedTasks=sum(task.status == "failed" for task in tasks),
            pendingQueueItems=queue_size,
            devices=len(devices),
            onlineDevices=sum(device.online for device in devices),
        ),
        DiagnosticCheck(
            key="database",
            label="SQLite 数据库",
            status="healthy",
            detail="数据库连接与业务统计读取正常",
        ),
    )


def _read_storage() -> tuple[DiagnosticStorage, DiagnosticCheck, DiagnosticCheck]:
    data_dir = db.DATA_DIR
    exists = data_dir.is_dir()
    writable = exists and os.access(data_dir, os.W_OK)
    data_check = DiagnosticCheck(
        key="data-directory",
        label="数据目录",
        status="healthy" if writable else "error",
        detail="数据目录存在且可写" if writable else "数据目录不存在或当前服务不可写",
    )

    total_bytes = used_bytes = free_bytes = 0
    if exists:
        try:
            disk = shutil.disk_usage(data_dir)
            total_bytes = disk.total
            used_bytes = disk.used
            free_bytes = disk.free
        except OSError:
            pass

    if total_bytes <= 0:
        disk_status: DiagnosticStatus = "error"
        disk_detail = "无法读取数据卷容量"
    else:
        free_ratio = free_bytes / total_bytes
        if free_bytes < 256 * 1024 * 1024 or free_ratio < 0.01:
            disk_status = "error"
            disk_detail = f"数据卷空间严重不足，仅剩 {_format_bytes(free_bytes)}"
        elif free_bytes < 1024 * 1024 * 1024 or free_ratio < 0.05:
            disk_status = "warning"
            disk_detail = f"数据卷空间偏低，剩余 {_format_bytes(free_bytes)}"
        else:
            disk_status = "healthy"
            disk_detail = f"数据卷剩余 {_format_bytes(free_bytes)}"

    try:
        database_bytes = db.DB_PATH.stat().st_size if db.DB_PATH.is_file() else 0
    except OSError:
        database_bytes = 0
    try:
        logs_bytes = runtime_log_storage_bytes()
    except RuntimeLogReadError:
        logs_bytes = 0

    return (
        DiagnosticStorage(
            totalBytes=total_bytes,
            usedBytes=used_bytes,
            freeBytes=free_bytes,
            databaseBytes=database_bytes,
            runtimeLogsBytes=logs_bytes,
        ),
        data_check,
        DiagnosticCheck(
            key="disk-space",
            label="数据卷空间",
            status=disk_status,
            detail=disk_detail,
        ),
    )


def _task_worker_check(application: FastAPI) -> DiagnosticCheck:
    worker = getattr(application.state, "queue_worker", None)
    if worker is None:
        return DiagnosticCheck(
            key="task-worker",
            label="任务执行器",
            status="warning",
            detail="任务执行器尚未进入运行状态",
        )
    done = getattr(worker, "done", None)
    if callable(done) and done():
        return DiagnosticCheck(
            key="task-worker",
            label="任务执行器",
            status="error",
            detail="任务执行器已停止，需要检查运行日志",
        )
    return DiagnosticCheck(
        key="task-worker",
        label="任务执行器",
        status="healthy",
        detail="任务执行器正在运行",
    )


def _read_recent_issues(log_bytes: int) -> tuple[list[DiagnosticIssue], DiagnosticCheck]:
    log_path = runtime_log_file_path()
    log_parent_ready = log_path.parent.is_dir() and os.access(log_path.parent, os.W_OK)
    try:
        batch = read_runtime_logs(limit=500)
    except RuntimeLogReadError:
        return (
            [],
            DiagnosticCheck(
                key="runtime-logs",
                label="运行日志",
                status="error",
                detail="运行日志暂时无法读取",
            ),
        )

    issues = [
        DiagnosticIssue(
            timestamp=record.timestamp,
            level=record.level,
            source=record.source,
            message=_issue_summary(record.message),
        )
        for record in batch.items
        if record.level in {"warning", "error", "critical"}
    ][-8:]
    issues.reverse()
    if log_parent_ready:
        return (
            issues,
            DiagnosticCheck(
                key="runtime-logs",
                label="运行日志",
                status="healthy",
                detail=f"结构化日志可读，当前占用 {_format_bytes(log_bytes)}",
            ),
        )
    return (
        issues,
        DiagnosticCheck(
            key="runtime-logs",
            label="运行日志",
            status="warning",
            detail="运行日志可读，但目录写入状态异常",
        ),
    )


def _issue_summary(message: str) -> str:
    summary = redact_runtime_log_message(message).splitlines()[0].strip()
    if len(summary) > 600:
        return f"{summary[:600]}…"
    return summary


def _format_bytes(value: int) -> str:
    size = float(max(0, value))
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return "0 B"


def _utc_now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")
