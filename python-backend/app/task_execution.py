"""Queue execution separated from the legacy HTTP composition module."""

from typing import Any

from . import db
from .models import BookRecord, TaskRecord
from .resource_limits import resource_actor
from .task_boundaries import TaskInterrupted, chapter_completed, checkpoint, task_boundaries
from .task_control import complete_chapter, completed_chapters, settle_stop, stop_requested


async def run_task(runtime: Any, task_id: str) -> None:
    task = db.get_task(task_id)
    if task is None or task.status not in {"queued", "running"}:
        return
    book = runtime._get_book_or_404(task.bookId, task.ownerId)
    task.status = "running"
    task.attempts += 1
    task.error = None
    task.message = "任务开始执行"
    task.updatedAt = runtime._now()
    db.save_task(task)
    runtime._append_task_runtime_log(task, "info", task.message, update_message=False)

    try:
        with resource_actor(task.ownerId), task_boundaries(
            lambda: stop_requested(task.id),
            lambda index: complete_chapter(task.id, index),
        ):
            checkpoint()
            if task.taskType == "download":
                await runtime._process_download_task(task, book)
            else:
                await runtime._process_translate_task(task, book)
            checkpoint()
        if runtime._is_task_deleted(task.id) or runtime._is_book_deleted(book.id):
            return
        task.status = "completed"
        task.completedCount = task.totalCount
        task.progress = 100
        task.message = "任务已完成"
        task.updatedAt = runtime._now()
        db.save_task(task)
        runtime._append_task_runtime_log(task, "info", task.message, update_message=False)
        runtime._refresh_book_state(book)
    except TaskInterrupted:
        settle_stop(task.id)
        if not runtime._is_book_deleted(book.id):
            runtime._refresh_book_state(book)
    except Exception as exc:
        if runtime._is_task_deleted(task.id) or runtime._is_book_deleted(book.id):
            return
        if stop_requested(task.id):
            settle_stop(task.id)
            return
        task.status = "failed"
        task.error = str(exc)
        task.message = "任务执行失败"
        task.updatedAt = runtime._now()
        db.save_task(task)
        runtime._append_task_runtime_log(task, "error", str(exc), update_message=False)


async def process_download(runtime: Any, task: TaskRecord, book: BookRecord) -> None:
    book_dir = runtime._resolve_book_dir(book)
    manifest = runtime._load_or_initialize_manifest(book, book_dir)
    settings = runtime.load_settings()
    concurrency = max(1, min(settings.downloadConcurrency, 8))
    done = completed_chapters(task.id)
    remaining = [index for index in task.chapterIndexes if index not in done]
    baseline = len(set(task.chapterIndexes) & done)
    if not remaining:
        return

    async def on_progress(completed_count: int, total_count: int, active_titles: list[str]) -> None:
        runtime._ensure_task_resources_exist(task.id, book.id)
        task.completedCount = baseline + completed_count
        task.progress = round(task.completedCount / task.totalCount * 100, 2) if task.totalCount else 0
        task.message = f"{concurrency} 线程下载中，已完成 {task.completedCount}/{task.totalCount} 章"
        if active_titles:
            task.message += "，当前：" + "、".join(active_titles[:3])
        task.updatedAt = runtime._now()
        db.save_task(task)

    await runtime.download_selected_chapters(
        book_dir=book_dir, manifest=manifest, chapter_indexes=remaining, concurrency=concurrency,
        progress_callback=on_progress,
        **runtime._site_account_download_kwargs(book.ownerId, book.sourceUrl),
    )


async def process_translate(runtime: Any, task: TaskRecord, book: BookRecord) -> None:
    book_dir = runtime._resolve_book_dir(book)
    manifest = runtime._load_or_initialize_manifest(book, book_dir)
    settings = runtime.load_settings()
    unit = "话" if book.bookKind == "漫画" else "章"
    done = completed_chapters(task.id)

    async def on_log(level: str, message: str) -> None:
        runtime._ensure_task_resources_exist(task.id, book.id)
        runtime._append_task_runtime_log(task, level, message)

    for index, chapter_index in enumerate(task.chapterIndexes, start=1):
        checkpoint()
        if chapter_index in done:
            continue
        runtime._ensure_task_resources_exist(task.id, book.id)
        runtime._append_task_runtime_log(task, "info", f"开始处理{unit} {chapter_index}")

        async def on_page_progress(completed_pages: int, total_pages: int, chapter_position: int = index) -> None:
            runtime._ensure_task_resources_exist(task.id, book.id)
            fraction = completed_pages / total_pages if total_pages else 0
            task.completedCount = chapter_position - 1
            task.progress = round(((chapter_position - 1) + fraction) / task.totalCount * 100, 2)
            task.message = f"正在翻译第 {chapter_position}/{task.totalCount} {unit}，本{unit}已完成 {completed_pages}/{total_pages} 页"
            task.updatedAt = runtime._now()
            db.save_task(task)

        await runtime.translate_selected_chapters(
            book_dir=book_dir, manifest=manifest, chapter_indexes=[chapter_index], language=book.language,
            settings=settings, log_callback=on_log, progress_callback=on_page_progress,
        )
        runtime._ensure_task_resources_exist(task.id, book.id)
        chapter_completed(chapter_index)
        task.completedCount = index
        task.progress = round(index / task.totalCount * 100, 2)
        task.message = f"已翻译 {index}/{task.totalCount} {unit}"
        task.updatedAt = runtime._now()
        db.save_task(task)
        runtime._append_task_runtime_log(task, "info", f"已完成{unit} {chapter_index}", update_message=False)
        manifest = runtime.load_manifest(book_dir)
        checkpoint()
