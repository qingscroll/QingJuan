from __future__ import annotations

import os
import re
import stat
from dataclasses import dataclass
from pathlib import Path

from . import db
from .storage_models import StorageError

EXPORT_NAME = re.compile(r"^[0-9a-f]{32}\.(txt|text|docx|epub|pdf|zip)$")
PRIVATE_TEMP = re.compile(
    r"^(\.quota-[0-9a-f]+\.(tmp|old)|\.(quality|manifest|chapter)-[A-Za-z0-9_-]+\.tmp|\.translation-quality-\d+\.json|.+\.part)$"
)
PRIVATE_DIRECTORY = re.compile(r"^\.manga-translation-[0-9a-f]+\.tmp$")


def unpublished_path(path: Path) -> bool:
    return bool(PRIVATE_TEMP.fullmatch(path.name)) or any(
        PRIVATE_DIRECTORY.fullmatch(part) for part in path.relative_to(db.DATA_DIR.absolute()).parts[:-1]
    )


def controlled_path(path: Path, *, base: Path | None = None) -> Path:
    base = Path(os.path.abspath(base or db.DATA_DIR))
    target = Path(os.path.abspath(path))
    if not target.is_relative_to(base):
        raise StorageError("存储路径不在受控数据目录中", 422)
    for current in (
        base,
        *(
            base.joinpath(*target.relative_to(base).parts[:index])
            for index in range(1, len(target.relative_to(base).parts) + 1)
        ),
    ):
        if current.is_symlink() or getattr(current, "is_junction", lambda: False)():
            raise StorageError("存储目录包含符号链接，已停止统计或清理", 409)
        if current.exists() and not (current.is_dir() or current.is_file()):
            raise StorageError("存储目录包含特殊文件", 409)
    return target


def book_root(book) -> Path:
    if not book.localPath:
        raise StorageError("书籍尚未分配存储目录，请先完成导入", 409)
    raw = Path(book.localPath)
    root = controlled_path(raw if raw.is_absolute() else db.DATA_DIR / raw, base=db.DATA_DIR / "library")
    if root == (db.DATA_DIR / "library").absolute():
        raise StorageError("书籍存储目录无效", 422)
    return root


def export_root(book_id: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", book_id):
        raise StorageError("书籍标识无效", 422)
    return controlled_path(db.DATA_DIR / "exports" / book_id)


@dataclass(frozen=True)
class StorageFile:
    path: Path
    size: int
    modified_ns: int
    inode: int
    device: int

    @property
    def signature(self):
        return self.size, self.modified_ns, self.inode, self.device


def inspect_file(path: Path) -> StorageFile:
    controlled_path(path)
    result = path.lstat()
    if not stat.S_ISREG(result.st_mode):
        raise StorageError("导出产物已变化，请重新预览", 409)
    return StorageFile(path, result.st_size, result.st_mtime_ns, result.st_ino, result.st_dev)


def walk_files(root: Path) -> list[StorageFile]:
    controlled_path(root)
    if not root.exists():
        return []
    if not root.is_dir():
        raise StorageError("书籍存储目录无效", 409)
    pending = [root]
    results = []
    try:
        while pending:
            with os.scandir(pending.pop()) as entries:
                for entry in entries:
                    path = Path(entry.path)
                    if entry.is_symlink() or getattr(path, "is_junction", lambda: False)():
                        raise StorageError("存储目录包含符号链接，已停止统计或清理", 409)
                    if entry.is_dir(follow_symlinks=False):
                        pending.append(path)
                    elif entry.is_file(follow_symlinks=False):
                        results.append(inspect_file(path))
                    else:
                        raise StorageError("存储目录包含特殊文件", 409)
                    if len(results) + len(pending) > 200_000:
                        raise StorageError("书籍文件过多，无法一次统计，请联系管理员", 413)
    except FileNotFoundError:
        raise StorageError("文件在统计期间发生变化，请稍后刷新", 409) from None
    return sorted(results, key=lambda item: str(item.path))


def export_files(book_id: str) -> list[StorageFile]:
    root = export_root(book_id)
    return [
        item
        for item in walk_files(root)
        if item.path.parent == root and EXPORT_NAME.fullmatch(item.path.name)
    ]
