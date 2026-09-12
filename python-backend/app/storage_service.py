from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import secrets
import threading
import time
from datetime import UTC, datetime

from . import db
from .storage_meter import measure_book_storage
from .storage_models import StorageArtifact, StorageCleanupPreview, StorageCleanupResult, StorageError
from .storage_paths import export_files, inspect_file


async def _blocking(function, *args):
    task = asyncio.create_task(asyncio.to_thread(function, *args))
    try:
        return await asyncio.shield(task)
    except asyncio.CancelledError:
        while not task.done():
            try:
                await asyncio.shield(task)
            except asyncio.CancelledError:
                continue
            except Exception:
                break
        if not task.cancelled():
            task.exception()
        raise


class StorageService:
    def __init__(self, *, quiesce):
        self.quiesce = quiesce
        self._secret = secrets.token_bytes(32)
        self._previews = {}
        self._preview_lock = threading.RLock()

    def _token(self, identifier, record):
        return hmac.new(
            self._secret,
            json.dumps(
                {
                    "id": identifier,
                    "owner": record["owner"],
                    "book": record["book"],
                    "expires": record["expires"],
                    "files": [(str(item.path), item.signature) for item in record["files"]],
                },
                sort_keys=True,
            ).encode(),
            hashlib.sha256,
        ).hexdigest()

    def preview(self, book, categories) -> StorageCleanupPreview:
        if categories != ["exports"]:
            raise StorageError("只能选择导出临时文件进行清理", 422)
        files = export_files(book.id)
        if len(files) > 5000:
            raise StorageError("导出产物过多，请等待过期清理后再试", 413)
        identifier = secrets.token_hex(16)
        record = {"book": book.id, "owner": book.ownerId, "files": files, "expires": time.time() + 600}
        with self._preview_lock:
            self._previews = {
                key: value for key, value in self._previews.items() if value["expires"] > time.time()
            }
            if len(self._previews) >= 256:
                raise StorageError("清理预览较多，请稍后重试", 429)
            self._previews[identifier] = record
        return StorageCleanupPreview(
            bookId=book.id,
            cleanupId=identifier,
            confirmationToken=self._token(identifier, record),
            totalBytes=sum(item.size for item in files),
            fileCount=len(files),
            artifacts=[
                StorageArtifact(
                    id=item.path.stem,
                    format=item.path.suffix[1:],
                    sizeBytes=item.size,
                    createdAt=datetime.fromtimestamp(item.modified_ns / 1_000_000_000, UTC)
                    .isoformat()
                    .replace("+00:00", "Z"),
                )
                for item in files
            ],
            warnings=["仅删除此书的导出临时文件，已有导出下载链接将失效；原文、译文、图片与阅读记录均保留。"],
        )

    def _validate(self, book_id, owner_id, identifier, token):
        with self._preview_lock:
            record = self._previews.get(identifier)
        if (
            record is None
            or record["expires"] <= time.time()
            or not hmac.compare_digest(self._token(identifier, record), token)
        ):
            raise StorageError("清理预览已过期，请重新预览", 409)
        if (record["book"], record["owner"]) != (book_id, owner_id):
            raise StorageError("未找到书籍清理预览", 404)
        book = db.get_book(book_id, owner_id)
        if book is None:
            raise StorageError("未找到书籍", 404)
        with db.get_connection() as conn:
            if conn.execute(
                """SELECT 1 FROM tasks WHERE book_id=? AND status IN
                ('running','pause_requested','cancel_requested') LIMIT 1""",
                (book_id,),
            ).fetchone():
                raise StorageError("书籍仍有任务运行，请先暂停并等待当前操作完成", 409)
        files = export_files(book_id)
        if files != record["files"]:
            raise StorageError("导出文件在预览后已变化，请重新预览", 409)
        return book, files

    def _delete(self, book, files, identifier):
        with self._preview_lock:
            self._previews.pop(identifier, None)
        removed_bytes = removed_files = 0
        warnings = []
        for item in files:
            try:
                if inspect_file(item.path) != item:
                    raise StorageError("导出文件发生变化，已停止清理，请重新预览", 409)
                item.path.unlink()
                removed_bytes += item.size
                removed_files += 1
            except OSError:
                warnings.append("部分导出文件无法移除，已保留；请关闭占用文件的程序后重新预览。")
                break
            except StorageError:
                warnings.append("导出文件在清理期间发生变化，已停止后续删除；请重新预览。")
                break
        return StorageCleanupResult(
            bookId=book.id,
            deletedBytes=removed_bytes,
            deletedFiles=removed_files,
            warnings=warnings,
            storage=measure_book_storage(book),
        )

    async def cleanup(self, book_id: str, owner_id: str, cleanup_id: str, confirmation_token: str):
        async with self.quiesce("storage-cleanup") as reload:
            try:
                book, files = await _blocking(
                    self._validate, book_id, owner_id, cleanup_id, confirmation_token
                )
                return await _blocking(self._delete, book, files, cleanup_id)
            finally:
                await reload()
