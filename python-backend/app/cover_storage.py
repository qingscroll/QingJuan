"""Commit a cover, its manifest reference and book timestamp as one publication."""

import json
import os
import shutil
from pathlib import Path
from uuid import uuid4

from . import db
from .resource_limits import ResourceLimitError
from .storage_meter import measure_owner_storage
from .storage_models import StorageError
from .storage_paths import controlled_path
from .storage_quota import PUBLISH_LOCK, _owner

MAX_COVER_BYTES = 20 * 1024 * 1024
_replace_file = os.replace


def _temporary(path: Path, data: bytes) -> Path:
    target = path.parent / f".quota-{uuid4().hex}.tmp"
    try:
        with target.open("xb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        return target
    except BaseException:
        target.unlink(missing_ok=True)
        raise


def publish_cover(book, directory: Path, extension: str, content: bytes, updated_at: str) -> dict:
    if not content:
        raise StorageError("封面文件为空", 400)
    if len(content) > MAX_COVER_BYTES:
        raise StorageError("封面文件不能超过 20 MiB", 413)
    if extension not in {".jpg", ".png", ".webp"}:
        raise StorageError("封面文件格式无效", 400)
    directory = controlled_path(directory, base=db.DATA_DIR / "library")
    cover = controlled_path(directory / "covers" / f"custom-cover{extension}")
    manifest_path = controlled_path(directory / "manifest.json")
    backups = {}
    changed = []
    temporaries = []
    locked = False
    recovered = True
    try:
        with db.get_connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            PUBLISH_LOCK.acquire()
            locked = True
            row = connection.execute(
                "SELECT local_path FROM books WHERE id=? AND owner_id=?", (book.id, book.ownerId)
            ).fetchone()
            if row is None:
                raise StorageError("未找到书籍", 404)
            current_root = Path(row[0])
            current_root = current_root if current_root.is_absolute() else db.DATA_DIR / current_root
            if controlled_path(current_root) != directory:
                raise StorageError("书籍目录已变化，请重新加载", 409)
            if connection.execute(
                "SELECT 1 FROM tasks WHERE book_id=? AND status IN ('running','pause_requested','cancel_requested') LIMIT 1",
                (book.id,),
            ).fetchone():
                raise StorageError("正在处理章节，请稍后更换封面", 409)
            _owner(connection, cover, book.ownerId)
            if not manifest_path.is_file() or manifest_path.stat().st_size > 32 * 1024 * 1024:
                raise StorageError("书籍目录无法读取", 409)
            try:
                manifest = json.loads(manifest_path.read_bytes())
            except (ValueError, UnicodeError) as error:
                raise StorageError("书籍目录格式无效", 409) from error
            if not isinstance(manifest, dict):
                raise StorageError("书籍目录格式无效", 409)
            previous = manifest.get("cover_file")
            old_cover = None
            if isinstance(previous, str) and previous:
                candidate = controlled_path(directory / previous)
                if candidate.parent == cover.parent and candidate != cover and candidate.is_file():
                    old_cover = candidate
            manifest = {**manifest, "cover_file": f"covers/{cover.name}", "cover_url": None}
            encoded = json.dumps(manifest, ensure_ascii=False, indent=2, allow_nan=False).encode("utf-8")
            originals = {
                path for path in (cover, manifest_path, old_cover) if path is not None and path.exists()
            }
            if any(not path.is_file() for path in originals):
                raise StorageError("封面存储目标不是文件", 409)
            limit_row = connection.execute(
                "SELECT storage_bytes FROM resource_limits WHERE owner_id=?", (book.ownerId,)
            ).fetchone()
            limit = limit_row[0] if limit_row else None
            # Account for replacement as a whole; a full account may replace a
            # cover with a smaller one even when its extension changes.
            delta = len(content) + len(encoded) - sum(path.stat().st_size for path in originals)
            if (
                limit is not None
                and delta > 0
                and measure_owner_storage(book.ownerId, connection, published_only=True) + delta > limit
            ):
                raise ResourceLimitError("书籍存储空间已达限额，请清理导出临时文件或联系管理员调整限制", 413)
            cover.parent.mkdir(parents=True, exist_ok=True)
            for path in originals:
                backup = path.parent / f".quota-{uuid4().hex}.old"
                backups[path] = backup
                shutil.copy2(path, backup)
                with backup.open("rb+") as handle:
                    os.fsync(handle.fileno())
            for path, data in [(cover, content), (manifest_path, encoded)]:
                temporary = _temporary(path, data)
                temporaries.append(temporary)
                _replace_file(temporary, path)
                changed.append(path)
            connection.execute(
                "UPDATE books SET updated_at=? WHERE id=? AND owner_id=?", (updated_at, book.id, book.ownerId)
            )
            if old_cover is not None:
                old_cover.unlink()
                changed.append(old_cover)
    except BaseException:
        for path in reversed(changed):
            try:
                backup = backups.get(path)
                if backup is not None:
                    os.replace(backup, path)
                else:
                    path.unlink(missing_ok=True)
            except OSError:
                recovered = False
        if not recovered:
            raise StorageError("封面提交失败且恢复未完成，请保留 .quota 备份并联系管理员", 503) from None
        raise
    finally:
        try:
            for path in temporaries:
                path.unlink(missing_ok=True)
            if recovered:
                for path in backups.values():
                    path.unlink(missing_ok=True)
        finally:
            if locked:
                PUBLISH_LOCK.release()
    return manifest
