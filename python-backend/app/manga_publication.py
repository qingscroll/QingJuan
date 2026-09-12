"""Publish a staged chapter without losing its previously published translation."""

import os
import shutil
from contextlib import nullcontext, suppress
from pathlib import Path

from . import db
from .storage_quota import PUBLISH_LOCK, quota_replace


def publish_staged_chapter(book_dir: Path, staging_dir: Path, relative_paths: list[str]) -> None:
    book_dir, staging_dir = book_dir.resolve(), staging_dir.resolve()
    backup_root = staging_dir / "__backup__"
    copies_root = staging_dir / "__publish__"
    recovery_marker = staging_dir / ".rollback-failed"
    if recovery_marker.exists() or backup_root.exists():
        raise RuntimeError(f"上次译文发布尚未恢复，恢复副本已保留：{staging_dir}")
    prepared = []
    seen = set()
    for relative_path in relative_paths:
        source = (staging_dir / relative_path).resolve()
        target = (book_dir / relative_path).resolve()
        backup = (backup_root / relative_path).resolve()
        temporary = (copies_root / relative_path).resolve()
        if (
            not source.is_relative_to(staging_dir)
            or not target.is_relative_to(book_dir)
            or not backup.is_relative_to(backup_root)
            or not temporary.is_relative_to(copies_root)
            or not source.is_file()
            or (target.exists() and not target.is_file())
            or target in seen
        ):
            raise ValueError("漫画译文发布路径或文件无效")
        seen.add(target)
        prepared.append((source, target, backup, temporary))

    managed = book_dir.is_relative_to((db.DATA_DIR / "library").absolute())
    scope = db.get_connection() if managed else nullcontext(None)
    published = []
    locked = False
    preserve_backups = False
    try:
        with scope as connection:
            if managed:
                connection.execute("BEGIN IMMEDIATE")
            # Match quota publication's SQLite -> file lock ordering.
            PUBLISH_LOCK.acquire()
            locked = True
            for source, target, backup, temporary in prepared:
                previous = None
                if target.exists():
                    backup.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(target, backup)
                    previous = backup
                temporary.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, temporary)
                published.append((target, previous))
                quota_replace(temporary, target, connection=connection)
    except BaseException as error:
        rollback_errors = []
        for target, previous in reversed(published):
            try:
                if previous is not None:
                    os.replace(previous, target)
                else:
                    target.unlink(missing_ok=True)
            except OSError as rollback_error:
                rollback_errors.append(rollback_error)
        if rollback_errors:
            preserve_backups = True
            with suppress(OSError):
                recovery_marker.write_text("译文回滚未完成；请保留 __backup__ 中的恢复副本。", encoding="utf-8")
            raise RuntimeError(f"译文发布失败且回滚未完成，恢复副本已保留：{staging_dir}") from error
        raise
    finally:
        try:
            shutil.rmtree(copies_root, ignore_errors=True)
            if not preserve_backups and not recovery_marker.exists():
                shutil.rmtree(backup_root, ignore_errors=True)
        finally:
            if locked:
                PUBLISH_LOCK.release()
