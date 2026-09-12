"""Serialize quota checks with final publication; never keep a DB lock during network I/O."""

from __future__ import annotations

import os
import shutil
import stat
import threading
import uuid
from contextlib import contextmanager, nullcontext
from datetime import UTC, datetime
from pathlib import Path

from . import db
from .resource_limits import ACTOR, ResourceLimitError, resource_actor
from .storage_meter import measure_owner_storage, owned_roots
from .storage_models import StorageError
from .storage_paths import controlled_path, unpublished_path, walk_files

PUBLISH_LOCK = threading.RLock()


def _owner(conn, target: Path, explicit: str | None):
    owners = {owner for root, owner in owned_roots(conn) if target.is_relative_to(root)}
    if len(owners) != 1:
        raise StorageError("目标书籍目录尚未登记归属或存在冲突", 409)
    owner = owners.pop()
    actor = explicit or ACTOR.get()
    if actor is not None and actor != owner:
        raise StorageError("不能写入其他账号的书籍目录", 403)
    return owner


def _managed(path: Path):
    return path.is_relative_to((db.DATA_DIR / "library").absolute()) or path.is_relative_to(
        (db.DATA_DIR / "exports").absolute()
    )


def _regular_size(path: Path) -> int:
    value = path.lstat()
    if not stat.S_ISREG(value.st_mode):
        raise StorageError("待发布文件类型无效", 422)
    return value.st_size


def _check(conn, temporary, target, owner_id):
    owner = _owner(conn, target, owner_id)
    if unpublished_path(target):
        # Bounded internal recovery journals/staging are excluded from published quota.
        return
    row = conn.execute("SELECT storage_bytes FROM resource_limits WHERE owner_id=?", (owner,)).fetchone()
    limit = row[0] if row else None
    if limit is None:
        return
    current = measure_owner_storage(
        owner, conn, published_only=True, exclude=() if temporary == target else (temporary,)
    )
    size = _regular_size(temporary)
    old_size = _regular_size(target) if target.exists() else 0
    delta = size - old_size
    projected = current + delta
    # A reduced limit must still permit replacing an existing file with a smaller one.
    if projected > limit and (delta > 0 or temporary == target or not target.exists()):
        raise ResourceLimitError("书籍存储空间已达限额，请清理导出临时文件或联系管理员调整限制", 413)


def quota_replace(temporary: Path, target: Path, *, connection=None, owner_id: str | None = None) -> None:
    temporary, target = Path(os.path.abspath(temporary)), Path(os.path.abspath(target))
    _regular_size(temporary)
    managed = _managed(target)
    if managed:
        controlled_path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    if managed:
        controlled_path(target)
    backup = None
    preserve_backup = False
    published = False
    locked = False
    scope = db.get_connection() if managed and connection is None else nullcontext(connection)
    try:
        with scope as conn:
            # SQLite precedes PUBLISH_LOCK, including callers with an existing write transaction.
            if managed and connection is None:
                conn.execute("BEGIN IMMEDIATE")
            PUBLISH_LOCK.acquire()
            locked = True
            if managed:
                _check(conn, temporary, target, owner_id)
            if temporary == target:
                return
            if target.exists():
                _regular_size(target)
                backup = target.parent / f".quota-{uuid.uuid4().hex}.old"
                try:
                    os.link(target, backup)
                except OSError:
                    shutil.copy2(target, backup)
                    with backup.open("rb+") as handle:
                        os.fsync(handle.fileno())
            os.replace(temporary, target)
            published = True
    except BaseException:
        if published:
            if backup is not None:
                # Until rollback succeeds this is the only copy of the old bytes.
                preserve_backup = True
                try:
                    os.replace(backup, target)
                except OSError:
                    raise StorageError(
                        "文件写入失败且旧文件未能恢复；恢复副本已保留，请联系管理员检查存储", 503
                    ) from None
                preserve_backup = False
            else:
                try:
                    target.unlink(missing_ok=True)
                except OSError:
                    raise StorageError("文件写入失败且未能移除新文件，请联系管理员检查存储", 503) from None
        raise
    finally:
        try:
            if backup is not None and not preserve_backup:
                backup.unlink(missing_ok=True)
        finally:
            if locked:
                PUBLISH_LOCK.release()


def quota_write_bytes(path: Path, data: bytes, *, connection=None, owner_id: str | None = None) -> int:
    path = Path(os.path.abspath(path))
    if _managed(path):
        controlled_path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".quota-{uuid.uuid4().hex}.tmp"
    try:
        with temporary.open("xb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        quota_replace(temporary, path, connection=connection, owner_id=owner_id)
    finally:
        temporary.unlink(missing_ok=True)
    return len(data)


def quota_write_text(path: Path, text: str, *, connection=None, owner_id: str | None = None) -> int:
    quota_write_bytes(path, text.encode("utf-8"), connection=connection, owner_id=owner_id)
    return len(text)


@contextmanager
def provisional_book_storage(owner_id: str, directory: Path):
    """Call before import writes, then save_book within the context; orphan roots stay billed."""
    root = controlled_path(Path(directory), base=db.DATA_DIR / "library")
    if root == (db.DATA_DIR / "library").absolute():
        raise StorageError("不能把整个书库登记为临时作品目录", 422)
    key = root.relative_to(db.DATA_DIR.absolute()).as_posix()
    with db.get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        with PUBLISH_LOCK:
            for previous, owner in owned_roots(conn):
                if (root.is_relative_to(previous) or previous.is_relative_to(root)) and owner != owner_id:
                    raise StorageError("临时书籍目录与其他账号数据重叠", 403)
            conn.execute(
                """INSERT INTO storage_provisional_roots VALUES(?,?,?)
                ON CONFLICT(storage_key) DO NOTHING""",
                (key, owner_id, datetime.now(UTC).isoformat()),
            )
    try:
        with resource_actor(owner_id):
            yield root
    finally:
        with db.get_connection() as conn:
            conn.execute("BEGIN IMMEDIATE")
            registered_roots = []
            for (book_key,) in conn.execute("SELECT local_path FROM books WHERE owner_id=?", (owner_id,)):
                if not book_key:
                    continue
                candidate = Path(book_key)
                candidate = controlled_path(candidate if candidate.is_absolute() else db.DATA_DIR / candidate)
                if candidate.is_relative_to(root):
                    registered_roots.append(candidate)
            remaining = walk_files(root)
            if not remaining or all(
                any(item.path.is_relative_to(registered) for registered in registered_roots)
                for item in remaining
            ):
                conn.execute(
                    "DELETE FROM storage_provisional_roots WHERE storage_key=? AND owner_id=?",
                    (key, owner_id),
                )
