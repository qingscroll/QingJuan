from __future__ import annotations

from contextlib import nullcontext
from pathlib import Path

from . import db
from .storage_models import BookStorageReport, StorageCategory, StorageError
from .storage_paths import EXPORT_NAME, book_root, controlled_path, export_root, unpublished_path, walk_files


def ensure_storage_schema(conn):
    conn.execute("""CREATE TABLE IF NOT EXISTS storage_provisional_roots (
        storage_key TEXT PRIMARY KEY, owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        created_at TEXT NOT NULL)""")
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_storage_provisional_owner ON storage_provisional_roots(owner_id)"
    )


def measure_book_storage(book) -> BookStorageReport:
    root = book_root(book)
    definitions = {
        "original": ("原文", "下载和阅读缓存中的小说原文，保留"),
        "translation": ("译文与翻译数据", "已翻译内容、译图和翻译检查点，保留"),
        "images": ("图片与附件", "原图、插图与封面，保留"),
        "protected": ("其他书籍数据", "目录、配置、恢复记录与其他文件，保留"),
        "exports": ("导出临时文件", "清理后导出下载链接失效，可从原书重新导出"),
    }
    counts = {key: [0, 0] for key in definitions}
    for item in walk_files(root):
        name = item.path.name.lower()
        category = "protected"
        if ".translated." in name:
            category = "translation"
        elif item.path.suffix.lower() in {".txt", ".text"}:
            category = "original"
        elif item.path.suffix.lower() in {".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif"}:
            category = "images"
        counts[category][0] += item.size
        counts[category][1] += 1
    exports = export_root(book.id)
    for item in walk_files(exports):
        category = (
            "exports"
            if item.path.parent == exports and EXPORT_NAME.fullmatch(item.path.name)
            else "protected"
        )
        counts[category][0] += item.size
        counts[category][1] += 1
    categories = [
        StorageCategory(
            id=key,
            label=label,
            bytes=counts[key][0],
            fileCount=counts[key][1],
            cleanable=key == "exports",
            description=description,
        )
        for key, (label, description) in definitions.items()
    ]
    total = sum(item.bytes for item in categories)
    reclaimable = counts["exports"][0]
    return BookStorageReport(
        bookId=book.id,
        totalBytes=total,
        protectedBytes=total - reclaimable,
        reclaimableBytes=reclaimable,
        fileCount=sum(item.fileCount for item in categories),
        categories=categories,
        warnings=["章节缓存就是原文或原图，不能清理；笔记、进度和作品信息不在清理范围。"],
    )


def owned_roots(conn, owner_id: str | None = None):
    sql = "SELECT id,owner_id,local_path FROM books"
    rows = conn.execute(
        sql + (" WHERE owner_id=?" if owner_id else ""), (owner_id,) if owner_id else ()
    ).fetchall()
    roots = []
    for book_id, owner, key in rows:
        if key:
            path = Path(key)
            root = controlled_path(
                path if path.is_absolute() else db.DATA_DIR / path, base=db.DATA_DIR / "library"
            )
            if root == (db.DATA_DIR / "library").absolute():
                raise StorageError("书库目录归属无效", 409)
            roots.append((root, owner))
        roots.append((export_root(book_id), owner))
    rows = conn.execute(
        "SELECT storage_key,owner_id FROM storage_provisional_roots"
        + (" WHERE owner_id=?" if owner_id else ""),
        (owner_id,) if owner_id else (),
    ).fetchall()
    for key, owner in rows:
        root = controlled_path(db.DATA_DIR / key, base=db.DATA_DIR / "library")
        if root == (db.DATA_DIR / "library").absolute():
            raise StorageError("临时书库目录归属无效", 409)
        roots.append((root, owner))
    return roots


def measure_owner_storage(owner_id: str, connection=None, *, published_only=False, exclude=()) -> int:
    """Logical file bytes, including book exports and crash-surviving provisional roots."""
    with db.get_connection() if connection is None else nullcontext(connection) as conn:
        roots = sorted({root for root, _ in owned_roots(conn, owner_id)}, key=lambda root: len(root.parts))
    counted = []
    total = 0
    excluded = {Path(item).absolute() for item in exclude}
    for root in roots:
        if any(root.is_relative_to(previous) for previous in counted):
            continue
        counted.append(root)
        for item in walk_files(root):
            if item.path in excluded or (published_only and unpublished_path(item.path)):
                continue
            total += item.size
    return total
