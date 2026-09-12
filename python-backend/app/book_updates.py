"""Check serial catalogs outside locks and append under the existing short manifest lock."""

from __future__ import annotations

import asyncio
from contextlib import suppress
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from . import book_updates_repository as repository
from . import db
from .book_updates_merge import append_new_chapters, manifest_chapters
from .book_updates_models import BookUpdateSettings, BookUpdateState
from .models import AddBookPayload, BookRecord
from .site_plugins import resolve_site_plugin


class UpdateCheckError(ValueError):
    pass


def original_source_payload(book: BookRecord, manifest: dict) -> AddBookPayload:
    source_url = str(manifest.get("source_url") or book.sourceUrl).strip()
    if not source_url or not book.sourceUrl or source_url != book.sourceUrl.strip():
        raise UpdateCheckError("作品没有可确认的原始网页来源，无法检查更新")
    source_id = manifest.get("source_id")
    if source_id:
        source = db.get_book_source(str(source_id))
        if source is None or not source.enabled:
            raise UpdateCheckError("原书源已移除或停用，请恢复原书源后重试")
        if source.origin != "builtin":
            raise UpdateCheckError("原书源使用自定义解析规则，暂不支持安全追更")
    plugin = resolve_site_plugin(source_url)
    saved_plugin_id = manifest.get("site_plugin_id")
    if plugin is None or (saved_plugin_id and plugin.id != saved_plugin_id):
        raise UpdateCheckError("原站点插件已更换或无法匹配，请恢复原插件后重试")
    if not saved_plugin_id and (plugin.origin != "builtin" or plugin.id == "generic-web"):
        raise UpdateCheckError("旧作品缺少原书源记录，无法安全追更，请重新导入作品")
    if not db.is_site_plugin_enabled(plugin.id):
        raise UpdateCheckError("原站点插件已停用，请启用后重试")
    if plugin.chapter_handler is None:
        raise UpdateCheckError("原站点仅提供作品信息，尚不支持章节追更")
    return AddBookPayload(
        sourceUrl=source_url,
        sourceId=source_id,
        bookKind=book.bookKind,
        language=book.language,
        downloadMode="on_demand",
    )


class BookUpdateService:
    def __init__(self, runtime: Any, *, now=None, interval_seconds: float = 60):
        self.runtime = runtime
        self.now = now or (lambda: datetime.now(UTC))
        self.interval_seconds = interval_seconds
        self._checks: dict[str, asyncio.Task] = {}
        self._loop_task: asyncio.Task | None = None
        self._closed = False

    def _book(self, book_id: str, owner_id: str) -> BookRecord:
        is_deleted = getattr(self.runtime, "_is_book_deleted", None)
        if callable(is_deleted) and is_deleted(book_id):
            raise KeyError("未找到书籍")
        book = db.get_book(book_id, owner_id)
        if book is None:
            raise KeyError("未找到书籍")
        return book

    def _manifest(self, book: BookRecord) -> tuple[Path, dict]:
        folder = self.runtime._resolve_book_dir(book).resolve()
        root = self.runtime.DATA_DIR.resolve()
        path = (folder / "manifest.json").resolve()
        if not path.is_relative_to(root) or not path.is_file():
            raise UpdateCheckError("原目录文件不可用，无法安全追更")
        manifest = self.runtime.load_manifest(folder)
        if not isinstance(manifest, dict):
            raise UpdateCheckError("原目录文件无效，无法安全追更")
        manifest_chapters(manifest)
        return folder, manifest

    def state(self, book_id: str, owner_id: str) -> BookUpdateState:
        book = self._book(book_id, owner_id)
        row = self.register_book(book_id, owner_id)
        try:
            _, manifest = self._manifest(book)
            indexes = [chapter["index"] for chapter in manifest_chapters(manifest)]
        except ValueError:
            indexes = []
        latest = max(indexes, default=0)
        acknowledged = row["acknowledged_index"] if row else latest
        return BookUpdateState(
            bookId=book_id,
            supported=bool(row["supported"]),
            unsupportedReason=row["unsupported_reason"],
            sourceStatus=row["source_status"],
            sourceStatusCheckedAt=row["source_status_checked_at"],
            enabled=bool(row["enabled"]) if row else False,
            intervalHours=row["interval_hours"] if row else 6,
            autoDownload=bool(row["auto_download"]) if row else False,
            revision=row["revision"] if row else 0,
            checking=book_id in self._checks and not self._checks[book_id].done(),
            lastCheckedAt=row["last_checked_at"] if row else None,
            nextCheckAt=row["next_check_at"] if row and row["enabled"] else None,
            lastError=row["last_error"] if row else None,
            latestChapterIndex=latest,
            acknowledgedChapterIndex=acknowledged,
            newChapterCount=sum(index > acknowledged for index in indexes),
        )

    def register_book(self, book_id: str, owner_id: str) -> dict:
        """Synchronously register a saved book; no network or chapter writes.

        Periodic discovery also calls this for existing books, so importing does
        not depend on a client enabling tracking or on the optional import hook.
        """
        book = self._book(book_id, owner_id)
        source_status, evidence, checked_at = "unknown", None, None
        current_index, supported, reason = 0, False, None
        try:
            _, manifest = self._manifest(book)
            current_index = max(chapter["index"] for chapter in manifest_chapters(manifest))
            value = manifest.get("source_status")
            if isinstance(value, str) and value in {"ongoing", "completed", "unknown"}:
                source_status = value
            raw_evidence = manifest.get("source_status_evidence")
            evidence = raw_evidence[:128] if isinstance(raw_evidence, str) else None
            raw_time = manifest.get("source_status_checked_at")
            if isinstance(raw_time, str):
                with suppress(ValueError):
                    observed = datetime.fromisoformat(raw_time.replace("Z", "+00:00"))
                    if observed.tzinfo is not None:
                        checked_at = repository.timestamp(observed.astimezone(UTC))
            original_source_payload(book, manifest)
            supported = True
        except (OSError, ValueError, KeyError) as error:
            reason = str(error) if isinstance(error, UpdateCheckError) else "作品目录不可用，暂不支持自动追更"
        return repository.sync_automatic(
            book_id,
            owner_id,
            current_index=current_index,
            source_status=source_status,
            evidence=evidence,
            checked_at=checked_at,
            supported=supported,
            unsupported_reason=reason,
            now=self.now(),
        )

    def list_states(self, owner_id: str | None) -> list[BookUpdateState]:
        states = []
        for book in db.list_books(owner_id):
            with suppress(KeyError):
                states.append(self.state(book.id, book.ownerId))
        return states

    def configure(self, book_id: str, owner_id: str, settings: BookUpdateSettings) -> BookUpdateState:
        state = self.state(book_id, owner_id)
        repository.configure(
            book_id,
            owner_id,
            current_index=state.latestChapterIndex,
            expected_revision=settings.expectedRevision,
            enabled=state.enabled,
            interval_hours=settings.intervalHours,
            auto_download=settings.autoDownload,
        )
        return self.state(book_id, owner_id)

    def acknowledge(self, book_id: str, owner_id: str, through_index: int) -> BookUpdateState:
        state = self.state(book_id, owner_id)
        repository.acknowledge(
            book_id, owner_id, through_index=through_index, current_index=state.latestChapterIndex
        )
        return self.state(book_id, owner_id)

    def _assert_idle(self, book_id: str) -> None:
        if repository.has_running_task(book_id):
            raise repository.UpdateConflict("正在处理章节，请稍后检查更新")

    async def check(self, book_id: str, owner_id: str) -> BookUpdateState:
        self._book(book_id, owner_id)  # Do not expose another owner's in-flight operation.
        if self._closed:
            raise UpdateCheckError("追更服务正在重启，请稍后重试")
        task = self._checks.get(book_id)
        if task is None or task.done():
            task = asyncio.create_task(self._check_once(book_id, owner_id))
            self._checks[book_id] = task
        try:
            await asyncio.shield(task)
        finally:
            if task.done() and self._checks.get(book_id) is task:
                self._checks.pop(book_id, None)
        return self.state(book_id, owner_id)

    async def _check_once(self, book_id: str, owner_id: str) -> None:
        async with self.runtime.app.state.maintenance_gate.operation():
            self._assert_idle(book_id)
            book = self._book(book_id, owner_id)
            _, snapshot = self._manifest(book)
            payload = original_source_payload(book, snapshot)
            self.register_book(book_id, owner_id)
            repository.claim_check(
                book_id,
                owner_id,
                current_index=max(chapter["index"] for chapter in manifest_chapters(snapshot)),
                now=self.now(),
            )
            try:
                try:
                    preview = await asyncio.wait_for(self.runtime.preview_from_url(payload), timeout=90)
                except Exception as error:
                    raise UpdateCheckError("未能读取来源目录，请检查网络和原书源后重试") from error
                async with self.runtime._chapter_manifest_lock_for(book_id):
                    self._assert_idle(book_id)
                    current_book = self._book(book_id, owner_id)
                    folder, current = self._manifest(current_book)
                    current_payload = original_source_payload(current_book, current)
                    if current_payload != payload:
                        raise repository.UpdateConflict("作品来源已变更，请重新检查更新")
                    merged, _ = append_new_chapters(current, preview.chapters)
                    merged.update(
                        source_status=preview.sourceStatus,
                        source_status_evidence=preview.sourceStatusEvidence,
                        source_status_checked_at=repository.timestamp(self.now()),
                    )
                    # No await between task-state validation and publication.
                    self.runtime.save_manifest(folder, merged)
                    # The manifest is authoritative across a crash between file
                    # publication and the subsequent SQLite state/counter update.
                    self.register_book(book_id, owner_id)
                    repository.complete_check(book_id, owner_id, chapters=merged["chapters"], now=self.now())
                self._retry_downloads(book_id, owner_id)
            except asyncio.CancelledError:
                raise
            except Exception as error:
                message = (
                    str(error)
                    if isinstance(error, (ValueError, repository.UpdateConflict))
                    else "追更状态保存失败，请稍后重试"
                )
                repository.record_failure(book_id, owner_id, message, self.now())
                if isinstance(error, (ValueError, repository.UpdateConflict, KeyError)):
                    raise
                raise UpdateCheckError(message) from error

    def _retry_downloads(self, book_id: str, owner_id: str) -> None:
        row = repository.get_tracking(book_id, owner_id)
        if (
            not row
            or not row["supported"]
            or not row["auto_download"]
            or repository.has_running_task(book_id)
        ):
            return
        book = self._book(book_id, owner_id)
        folder, manifest = self._manifest(book)
        original_source_payload(book, manifest)
        missing = [
            chapter["index"]
            for chapter in manifest_chapters(manifest)
            if chapter["index"] > row["acknowledged_index"]
            and self.runtime._chapter_needs_source_cache(folder, chapter)
        ]
        if missing:
            self.runtime._get_chapter_cache_coordinator().schedule(book_id, missing)

    async def run_due(self) -> None:
        async with self.runtime.app.state.maintenance_gate.operation():
            await self._run_due_admitted()

    async def _run_due_admitted(self) -> None:
        # Discover old/new books without requiring any client tracking action.
        for book in db.list_books():
            if self._closed:
                return
            with suppress(KeyError, ValueError, OSError):
                self.register_book(book.id, book.ownerId)
        now_text = repository.timestamp(self.now())
        for row in repository.list_tracking():
            if self._closed:
                break
            # Retry unfinished automatic downloads even between catalog checks.
            try:
                async with self.runtime.app.state.maintenance_gate.operation():
                    self._retry_downloads(row["book_id"], row["owner_id"])
                if row["enabled"] and (row["next_check_at"] is None or row["next_check_at"] <= now_text):
                    await self.check(row["book_id"], row["owner_id"])
            except (KeyError, ValueError, OSError) as error:
                with suppress(Exception):
                    repository.record_failure(row["book_id"], row["owner_id"], str(error), self.now())
                continue

    async def _loop(self) -> None:
        while not self._closed:
            # A transient database or disk failure must not kill future checks.
            with suppress(Exception):
                await self.run_due()
            await asyncio.sleep(self.interval_seconds)

    def start(self) -> None:
        if self._loop_task is None or self._loop_task.done():
            self._closed = False
            self._loop_task = asyncio.create_task(self._loop())

    async def stop(self) -> None:
        self._closed = True
        tasks = [*self._checks.values(), *([self._loop_task] if self._loop_task else [])]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self._checks.clear()
        self._loop_task = None
