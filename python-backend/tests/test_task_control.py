from __future__ import annotations

import asyncio
from types import SimpleNamespace

import httpx
import pytest

from app import db, main, scraper
from app.api.routers import tasks_router
from app.application import create_application
from app.models import BookRecord, TaskRecord
from app.security import API_PREFIX


@pytest.fixture
def task_runtime(monkeypatch, tmp_path):
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "LIBRARY_ROOT", tmp_path / "library")
    monkeypatch.setattr(main, "TASK_QUEUE", asyncio.Queue())
    db.init_db()
    book_dir = tmp_path / "library" / "book"
    book_dir.mkdir(parents=True)
    db.save_book(BookRecord(
        id="book", title="任务测试", sourceUrl="https://example.com/book",
        bookKind="长小说", language="中文", status="待处理", chapterCount=4,
        translated=False, localPath="library/book",
    ))
    main.save_manifest(book_dir, {
        "title": "任务测试", "chapters": [
            {"index": n, "title": f"第{n}章", "file_name": f"{n}.txt",
             "url": f"https://example.com/{n}"} for n in range(1, 5)
        ],
    })
    task = db.create_task(TaskRecord(
        id="task", bookId="book", taskType="download", chapterIndexes=[1, 2, 3, 4],
        status="queued", totalCount=4, createdAt="2026-09-11T00:00:00Z",
        updatedAt="2026-09-11T00:00:00Z",
    ))
    application = create_application(routers=[tasks_router], api_prefix=API_PREFIX)
    application.state.task_queue = main.TASK_QUEUE
    return application, task, book_dir


@pytest.mark.asyncio
async def test_queued_pause_resume_cancel_are_idempotent_and_persist(task_runtime):
    application, task, _ = task_runtime
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=application), base_url="http://testserver") as client:
        endpoint = f"{API_PREFIX}/tasks/{task.id}"
        for _ in range(2):
            response = await client.post(f"{endpoint}/control/pause")
            assert response.status_code == 200, response.text
            assert response.json()["status"] == "paused"
        db.init_db()
        assert db.get_task(task.id).status == "paused"
        assert db.list_pending_tasks() == []
        for _ in range(2):
            assert (await client.post(f"{endpoint}/control/resume")).json()["status"] == "queued"
        assert main.TASK_QUEUE.qsize() == 1
        for _ in range(2):
            assert (await client.post(f"{endpoint}/control/cancel")).json()["status"] == "cancelled"
        assert (await client.post(f"{endpoint}/control/resume")).status_code == 409
        await main._run_task(task.id)
        assert db.get_task(task.id).status == "cancelled"


@pytest.mark.asyncio
async def test_pause_drains_active_downloads_and_resume_skips_completed_chapters(task_runtime, monkeypatch):
    application, task, book_dir = task_runtime
    settings = db.load_settings()
    settings.downloadConcurrency = 2
    db.save_settings(settings)
    started = []
    active = asyncio.Event()
    release = asyncio.Event()

    async def download(client, directory, index, chapter, **kwargs):
        started.append(index)
        if len(started) == 2:
            active.set()
        await release.wait()
        (directory / chapter["file_name"]).write_text(f"正文{index}", encoding="utf-8")
        return {"index": index, "file_name": chapter["file_name"], "downloaded": True,
                "illustration": False, "image_urls": [], "image_files": [], "page_count": 0}

    monkeypatch.setattr(scraper, "_download_single_chapter", download)
    running = asyncio.create_task(main._run_task(task.id))
    try:
        await asyncio.wait_for(active.wait(), 3)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=application), base_url="http://testserver") as client:
            response = await client.post(f"{API_PREFIX}/tasks/{task.id}/control/pause")
            assert response.status_code == 200, response.text
            assert response.json()["status"] == "pause_requested"
            release.set()
            await asyncio.wait_for(running, 3)
            paused = db.get_task(task.id)
            assert paused.status == "paused"
            assert paused.completedCount == 2
            assert sorted(started) == [1, 2]
            assert (book_dir / "1.txt").read_text(encoding="utf-8") == "正文1"
            await client.post(f"{API_PREFIX}/tasks/{task.id}/control/resume")
            await main._run_task(task.id)
            assert db.get_task(task.id).status == "completed"
            assert sorted(started) == [1, 2, 3, 4]
    finally:
        release.set()
        if not running.done():
            running.cancel()
        await asyncio.gather(running, return_exceptions=True)


@pytest.mark.asyncio
async def test_task_controls_reject_other_owners(task_runtime, monkeypatch):
    from app.api import task_control

    application, task, _ = task_runtime
    monkeypatch.setattr(task_control, "require_user_access", lambda request: SimpleNamespace(owner_id="another-user"))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=application), base_url="http://testserver") as client:
        for action in ("pause", "resume", "cancel"):
            response = await client.post(f"{API_PREFIX}/tasks/{task.id}/control/{action}")
            assert response.status_code == 404
    assert db.get_task(task.id).status == "queued"


@pytest.mark.asyncio
@pytest.mark.parametrize("action", ["pause", "cancel"])
async def test_translation_stops_after_durable_chapter_and_reuses_ledger(task_runtime, monkeypatch, action):
    from app.task_control import change_task, completed_chapters, settle_interrupted_controls

    _, task, book_dir = task_runtime
    task.taskType = "translate"
    db.save_task(task)
    calls = []

    async def translate(**kwargs):
        index = kwargs["chapter_indexes"][0]
        calls.append(index)
        (book_dir / f"{index}.translated.txt").write_text("保留的译文", encoding="utf-8")
        if len(calls) == 1:
            change_task(task.id, task.ownerId, action)
            await kwargs["log_callback"]("info", "当前章节已保存")
            # Late progress/log writes must never overwrite the requested stop.
            assert db.get_task(task.id).status == f"{action}_requested"

    monkeypatch.setattr(main, "translate_selected_chapters", translate)
    await main._run_task(task.id)
    assert calls == [1]
    assert completed_chapters(task.id) == {1}
    assert db.get_task(task.id).status == ("paused" if action == "pause" else "cancelled")
    db.init_db()
    settle_interrupted_controls()
    assert db.list_pending_tasks() == []
    assert (book_dir / "1.translated.txt").read_text(encoding="utf-8") == "保留的译文"
    if action == "pause":
        change_task(task.id, task.ownerId, "resume")
        await main._run_task(task.id)
        assert calls == [1, 2, 3, 4]
        assert db.get_task(task.id).status == "completed"


@pytest.mark.parametrize("action,target", [("pause", "paused"), ("cancel", "cancelled")])
def test_restart_settles_requests_without_resuming_stopped_tasks(task_runtime, action, target):
    from app.task_control import change_task, settle_interrupted_controls

    _, task, _ = task_runtime
    task.status = "running"
    db.save_task(task)
    change_task(task.id, task.ownerId, action)
    db.init_db()
    settle_interrupted_controls()
    assert db.get_task(task.id).status == target
    assert db.list_pending_tasks() == []


@pytest.mark.asyncio
async def test_manga_pause_keeps_page_checkpoint_and_resume_does_not_retranslate(monkeypatch, tmp_path):
    from io import BytesIO

    from PIL import Image

    from app.models import OpenAICompatibleConfig, TranslationSettings
    from app.task_boundaries import TaskInterrupted, task_boundaries

    buffer = BytesIO()
    Image.new("RGB", (8, 8), "white").save(buffer, "PNG")
    png = buffer.getvalue()
    images = ["one.png", "two.png"]
    for name in images:
        (tmp_path / name).write_bytes(png)
    checkpoint_path = tmp_path / "chapter.translated.json.part"
    settings = TranslationSettings(translationModel=OpenAICompatibleConfig(
        enabled=True, baseUrl="https://model.example.com", apiKey="test-only", model="test",
    ))
    calls = []
    stop = False

    async def pipeline(**kwargs):
        calls.append(kwargs["page_number"])
        return png, "译文", None

    def progress(completed, total):
        nonlocal stop
        stop = completed == 1

    monkeypatch.setattr(scraper, "_translate_manga_page_with_pipeline", pipeline)
    arguments = dict(settings=settings, target_language="中文", chapter_index=1, title="chapter",
                     image_files=images, book_dir=tmp_path, checkpoint_path=checkpoint_path)
    with task_boundaries(lambda: stop, lambda _: None), pytest.raises(TaskInterrupted):
        await scraper._translate_manga_pages_with_command_detailed(**arguments, progress_callback=progress)
    assert checkpoint_path.exists()
    assert calls == [1]
    result = await scraper._translate_manga_pages_with_command_detailed(**arguments)
    assert calls == [1, 2]
    assert len(result[2]) == 2
