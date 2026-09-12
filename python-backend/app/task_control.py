"""Persisted task transitions and per-operation chapter checkpoints."""

import sqlite3
from datetime import UTC, datetime
from typing import Literal

from . import db
from .models import TaskRecord

TaskAction = Literal["pause", "resume", "cancel"]
PENDING_STOPS = {"pause_requested", "cancel_requested"}


class TaskConflict(ValueError):
    pass


def create_schema(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS task_checkpoints (
            task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            chapter_index INTEGER NOT NULL,
            PRIMARY KEY (task_id, chapter_index)
        )
    """)


def change_task(task_id: str, owner_id: str | None, action: TaskAction) -> tuple[TaskRecord, bool]:
    """Atomically record intent; only a paused -> queued transition enqueues work."""
    with db.get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute("SELECT status, owner_id FROM tasks WHERE id = ?", (task_id,)).fetchone()
        if row is None or (owner_id is not None and row[1] != owner_id):
            raise KeyError("未找到任务")
        current = row[0]
        transitions = {
            "pause": {"queued": "paused", "running": "pause_requested", "paused": "paused",
                      "pause_requested": "pause_requested"},
            "resume": {"paused": "queued", "queued": "queued", "running": "running"},
            "cancel": {"queued": "cancelled", "paused": "cancelled", "running": "cancel_requested",
                       "pause_requested": "cancel_requested", "cancel_requested": "cancel_requested",
                       "cancelled": "cancelled", "failed": "cancelled"},
        }
        target = transitions[action].get(current)
        if target is None:
            raise TaskConflict("当前任务状态不支持此操作，请刷新任务列表")
        changed = target != current
        if changed:
            message = {
                "paused": "任务已暂停，已完成内容已保留", "queued": "等待继续处理",
                "pause_requested": "正在暂停，等待当前章节或页面保存",
                "cancel_requested": "正在取消，等待当前章节或页面保存",
                "cancelled": "任务已取消，已完成内容已保留",
            }[target]
            now = datetime.now(UTC).isoformat().replace("+00:00", "Z")
            conn.execute("UPDATE tasks SET status = ?, message = ?, updated_at = ? WHERE id = ?",
                         (target, message, now, task_id))
            conn.execute("INSERT INTO task_logs (task_id, level, message, created_at) VALUES (?, 'info', ?, ?)",
                         (task_id, message, now))
    return db.get_task(task_id, owner_id), changed and target == "queued"


def stop_requested(task_id: str) -> bool:
    task = db.get_task(task_id)
    return task is None or task.status in PENDING_STOPS | {"paused", "cancelled"}


def completed_chapters(task_id: str) -> set[int]:
    with db.get_connection() as conn:
        return {row[0] for row in conn.execute(
            "SELECT chapter_index FROM task_checkpoints WHERE task_id = ?", (task_id,),
        )}


def complete_chapter(task_id: str, chapter_index: int) -> None:
    with db.get_connection() as conn:
        conn.execute("""
            INSERT OR IGNORE INTO task_checkpoints (task_id, chapter_index)
            SELECT id, ? FROM tasks WHERE id = ?
        """, (chapter_index, task_id))


def settle_stop(task_id: str) -> TaskRecord | None:
    with db.get_connection() as conn:
        conn.execute("""
            UPDATE tasks SET
                status = CASE status WHEN 'pause_requested' THEN 'paused' ELSE 'cancelled' END,
                message = CASE status WHEN 'pause_requested' THEN '任务已暂停，已完成内容已保留'
                          ELSE '任务已取消，已完成内容已保留' END,
                updated_at = ?
            WHERE id = ? AND status IN ('pause_requested', 'cancel_requested')
        """, (datetime.now(UTC).isoformat().replace("+00:00", "Z"), task_id))
    return db.get_task(task_id)


def settle_interrupted_controls() -> None:
    with db.get_connection() as conn:
        ids = [row[0] for row in conn.execute(
            "SELECT id FROM tasks WHERE status IN ('pause_requested', 'cancel_requested')",
        )]
    for task_id in ids:
        settle_stop(task_id)
