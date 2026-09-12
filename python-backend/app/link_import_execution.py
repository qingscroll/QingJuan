"""Bounded import scheduling and recovery with stable book identities."""

from __future__ import annotations

import asyncio
from typing import Any


def schedule_link_job(runtime: Any, job_id: str) -> None:
    state = runtime.app.state
    scheduled = getattr(state, "scheduled_link_jobs", None)
    if scheduled is None:
        scheduled = state.scheduled_link_jobs = {}
    if job_id in scheduled and not scheduled[job_id].done():
        return
    semaphore = getattr(state, "link_job_semaphore", None)
    if semaphore is None:
        semaphore = state.link_job_semaphore = asyncio.Semaphore(2)

    async def execute() -> None:
        async with semaphore, state.maintenance_gate.operation():
            if runtime.LINK_JOB_STORE.get(job_id).status == "queued":
                await runtime._run_link_job(job_id)

    task = asyncio.create_task(execute())
    scheduled[job_id] = task
    tasks = getattr(state, "link_job_tasks", None)
    if tasks is None:
        tasks = state.link_job_tasks = set()
    tasks.add(task)

    def finished(done: asyncio.Task) -> None:
        tasks.discard(done)
        scheduled.pop(job_id, None)
        if not done.cancelled() and done.exception() is not None:
            runtime._TASK_LOGGER.error("链接任务调度异常：%s", job_id)

    task.add_done_callback(finished)


async def run_link_job(runtime: Any, job_id: str) -> None:
    request = runtime.LINK_JOB_STORE.get(job_id)
    payload = runtime.LINK_JOB_STORE.payload_for(job_id)
    owner_id = runtime.LINK_JOB_STORE.owner_for(job_id)
    runtime.LINK_JOB_STORE.start(job_id, "开始识别作品链接")
    runtime.LINK_JOB_STORE.append_log(job_id, "info", f"已提交链接：{payload.sourceUrl}", progress=5)
    try:
        preview = await runtime._run_link_job_stage(
            job_id,
            asyncio.create_task(runtime.preview_from_url(payload)),
            message="正在获取作品元数据和章节目录",
            start_progress=12,
            end_progress=60,
        )
        runtime.LINK_JOB_STORE.append_log(
            job_id,
            "info",
            f"已解析《{preview.title}》，共 {preview.chapterCount} 章",
            progress=65 if request.mode == "import" else 95,
        )
        if request.mode == "preview":
            runtime.LINK_JOB_STORE.complete(job_id, "链接解析完成", preview=preview)
            return

        manifest_only = runtime._uses_manifest_only_import(payload)
        if manifest_only and runtime._server_managed_chapter_cache_enabled():
            import_start_message = "开始创建章节目录，完成后由 Linux 服务器顺序缓存正文"
        else:
            import_start_message = (
                "开始创建章节目录，正文将在阅读时按需下载"
                if manifest_only
                else "开始下载全部正文并写入本地书库"
            )
        import_wait_message = "正在写入章节目录" if manifest_only else "正在下载全部正文并写入本地书库"
        runtime.LINK_JOB_STORE.append_log(job_id, "info", import_start_message, progress=68)
        book = await runtime._run_link_job_stage(
            job_id,
            asyncio.create_task(runtime._create_imported_book(payload, preview, owner_id=owner_id, book_id=f"book-{job_id.removeprefix('link-')}")),
            message=import_wait_message,
            start_progress=68,
            end_progress=98,
        )
        if manifest_only and runtime._server_managed_chapter_cache_enabled():
            completion_message = "链接导入完成，Linux 服务器已开始顺序缓存正文"
        else:
            completion_message = "链接导入完成，已启用边看边下" if manifest_only else "链接导入完成"
        runtime.LINK_JOB_STORE.complete(job_id, completion_message, preview=preview, book=book)
    except asyncio.CancelledError:
        runtime.LINK_JOB_STORE.defer(job_id)
        raise
    except Exception as exc:
        runtime.LINK_JOB_STORE.fail(job_id, exc)

