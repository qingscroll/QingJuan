"""Task failures must preserve published pages and contain every writer."""

import asyncio
import hashlib
import threading
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace

import pytest
from PIL import Image

from app import db, main, scraper
from app.maintenance import MaintenanceGate
from app.models import BookRecord, ChapterActionPayload, OpenAICompatibleConfig


def png(color):
    buffer = BytesIO()
    Image.new("RGB", (8, 8), color).save(buffer, "PNG")
    return buffer.getvalue()


@pytest.fixture
def publication_runtime(monkeypatch, tmp_path):
    (tmp_path / ".isolated-review").write_text("Never migrate real data.")
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "LIBRARY_ROOT", tmp_path / "library")
    monkeypatch.setattr(main, "TASK_QUEUE", asyncio.Queue())
    monkeypatch.setattr(main.app.state, "maintenance_gate", MaintenanceGate())
    monkeypatch.setattr(main.app.state, "chapter_manifest_locks", {}, raising=False)
    monkeypatch.setattr(main.app.state, "deleted_book_ids", set(), raising=False)
    monkeypatch.setattr(main, "require_user_access", lambda _: SimpleNamespace(owner_id="user-admin"))
    db.init_db()
    settings = db.load_settings()
    settings.downloadConcurrency = 2
    settings.translationModel = OpenAICompatibleConfig(
        enabled=True, baseUrl="https://model.example.test", apiKey="test-only", model="test"
    )
    db.save_settings(settings)
    book = BookRecord(
        id="publication-book", title="Publication", sourceUrl="https://example.test/book",
        bookKind="漫画", language="中文", status="已下载", chapterCount=2,
        translated=False, localPath="library/publication-book",
    )
    db.save_book(book)
    folder = tmp_path / book.localPath
    folder.mkdir(parents=True)
    for name in ("1.png", "2.png"):
        (folder / name).write_bytes(png("white"))
    for index in (1, 2):
        (folder / f"{index}.txt").write_text("Source chapter", encoding="utf-8")
    main.save_manifest(folder, {
        "title": book.title, "book_kind": book.bookKind, "source_url": book.sourceUrl,
        "chapters": [{
            "index": index, "title": str(index), "url": f"https://example.test/{index}",
            "file_name": f"{index}.txt", "downloaded": True,
            "image_files": ["1.png", "2.png"] if index == 1 else [],
            "image_urls": [], "page_count": 2 if index == 1 else 0,
        } for index in (1, 2)],
    })
    return book, folder


async def enqueue(book, action):
    endpoint = main.post_translate_chapters if action == "translate" else main.post_download_chapters
    return await endpoint(book.id, ChapterActionPayload(chapterIndexes=[1]), None)


async def read(book):
    return await main.get_chapter_content(book.id, 1, None, mode="translated", prefetch=True)


@pytest.mark.asyncio
async def test_download_publication_preserves_reader_cache(publication_runtime, monkeypatch):
    book, folder = publication_runtime
    (folder / "2.txt").unlink()
    entered, release = asyncio.Event(), asyncio.Event()

    async def download(_client, directory, index, chapter, **_kwargs):
        if index == 1:
            entered.set()
            await release.wait()
        (directory / f"{index}.txt").write_text(f"Content {index}")
        return {
            "index": index, "file_name": f"{index}.txt", "downloaded": True,
            "illustration": False, "image_urls": [], "image_files": [f"{index}.png"],
            "translated_image_files": [], "page_count": 1,
        }

    monkeypatch.setattr(scraper, "_download_single_chapter", download)
    task = await enqueue(book, "download")
    running = asyncio.create_task(main._run_task(task.id))
    try:
        await asyncio.wait_for(entered.wait(), 3)
        await main._cache_source_chapter_by_id(book.id, 2)
        assert main.load_manifest(folder)["chapters"][1]["image_files"] == ["2.png"]
        release.set()
        await asyncio.wait_for(running, 3)
        assert db.get_task(task.id).status == "completed"
        assert main.load_manifest(folder)["chapters"][1]["image_files"] == ["2.png"]
    finally:
        release.set()
        await asyncio.gather(running, return_exceptions=True)


@pytest.mark.asyncio
async def test_failed_download_cancels_image_siblings_before_maintenance(publication_runtime, monkeypatch):
    book, folder = publication_runtime
    started, release, finished = threading.Event(), threading.Event(), threading.Event()
    bad, late = "https://images.example.test/bad.png", "https://images.example.test/late.png"
    manifest = main.load_manifest(folder)
    manifest["chapters"][0]["url"] = "https://18comic.vip/photo/123"
    main.save_manifest(folder, manifest)
    target = folder / "images" / f"0001-02-{hashlib.md5(late.encode()).hexdigest()[:10]}.png"

    async def fetch(*_args, **_kwargs):
        return scraper.ChapterFetchResult(text="pages", image_urls=[bad, late])

    def binary(url, _referer):
        if url == bad:
            assert started.wait(3)
            raise OSError("first image failed")
        started.set()
        try:
            assert release.wait(5)
            return png("blue")
        finally:
            finished.set()

    monkeypatch.setattr(scraper, "_fetch_chapter_data", fetch)
    monkeypatch.setattr(scraper, "_sync_fetch_18comic_binary", binary)
    task = await enqueue(book, "download")
    try:
        await asyncio.wait_for(main._run_task(task.id), 3)
        assert db.get_task(task.id).status == "failed"
        gate = main.app.state.maintenance_gate
        async with gate.exclusive(timeout=0.5):
            protected = png("red")
            target.write_bytes(protected)
            release.set()
            assert await asyncio.to_thread(finished.wait, 3)
            await asyncio.sleep(0.05)
            assert target.read_bytes() == protected
    finally:
        release.set()
        await asyncio.to_thread(finished.wait, 3)


@pytest.mark.asyncio
async def test_cancelled_image_write_drains_before_gate_releases(publication_runtime, monkeypatch):
    book, folder = publication_runtime
    entered, release = threading.Event(), threading.Event()
    original_write = scraper.write_image_atomic

    async def fetch(*_args, **_kwargs):
        return scraper.ChapterFetchResult(text="page", image_urls=["https://images.example.test/one.png"])

    async def binary(*_args):
        return png("blue")

    def write(path, content):
        entered.set()
        assert release.wait(5)
        original_write(path, content)

    monkeypatch.setattr(scraper, "_fetch_chapter_data", fetch)
    monkeypatch.setattr(scraper, "_download_binary_bytes", binary)
    monkeypatch.setattr(scraper, "write_image_atomic", write)
    task = await enqueue(book, "download")
    running = asyncio.create_task(main._run_task(task.id))
    try:
        assert await asyncio.to_thread(entered.wait, 3)
        running.cancel()
        await asyncio.sleep(0.05)
        assert not running.done()
        assert main.app.state.maintenance_gate.active_count == 1
        running.cancel()
        await asyncio.sleep(0.05)
        assert not running.done()
        assert main.app.state.maintenance_gate.active_count == 1
    finally:
        release.set()
        await asyncio.gather(running, return_exceptions=True)
    assert main.app.state.maintenance_gate.active_count == 0


@pytest.mark.asyncio
@pytest.mark.parametrize("failed_page", [1, 2])
async def test_retranslation_failure_preserves_published_chapter_and_retry_checkpoint(
    publication_runtime, monkeypatch, failed_page
):
    book, folder = publication_runtime

    async def old_translation(**kwargs):
        return png("red"), f"Old page {kwargs['page_number']}", None

    monkeypatch.setattr(scraper, "_translate_manga_page_with_pipeline", old_translation)
    first = await enqueue(book, "translate")
    await main._run_task(first.id)
    assert db.get_task(first.id).status == "completed"
    paths = ["1.translated.png", "2.translated.png", "1.translated.txt", "1.translated.json", "manifest.json"]
    published = {name: (folder / name).read_bytes() for name in paths}
    calls = []

    async def failing_translation(**kwargs):
        calls.append(kwargs["page_number"])
        if kwargs["page_number"] == failed_page:
            raise TimeoutError("simulated model timeout")
        return png("blue"), f"New page {kwargs['page_number']}", None

    monkeypatch.setattr(scraper, "_translate_manga_page_with_pipeline", failing_translation)
    second = await enqueue(book, "translate")
    await main._run_task(second.id)
    assert db.get_task(second.id).status == "failed"
    assert all((folder / name).read_bytes() == value for name, value in published.items())
    assert len((await read(book)).imageSources) == 2

    async def retry_translation(**kwargs):
        calls.append(kwargs["page_number"])
        return png("blue"), f"New page {kwargs['page_number']}", None

    monkeypatch.setattr(scraper, "_translate_manga_page_with_pipeline", retry_translation)
    await main.post_retry_task(second.id, None)
    await main._run_task(second.id)
    assert db.get_task(second.id).status == "completed"
    assert calls == ([1, 1, 2] if failed_page == 1 else [1, 2, 2])
    response = await read(book)
    assert response.pageTranslations == ["New page 1", "New page 2"]
    assert len(response.imageSources) == 2


@pytest.mark.asyncio
async def test_retranslation_publication_failure_rolls_back_and_retry_reuses_staging(
    publication_runtime, monkeypatch
):
    from app import manga_publication

    book, folder = publication_runtime

    async def old_translation(**kwargs):
        return png("red"), f"Old page {kwargs['page_number']}", None

    monkeypatch.setattr(scraper, "_translate_manga_page_with_pipeline", old_translation)
    first = await enqueue(book, "translate")
    await main._run_task(first.id)
    assert db.get_task(first.id).status == "completed"
    paths = ["1.translated.png", "2.translated.png", "1.translated.txt", "1.translated.json", "manifest.json"]
    published = {name: (folder / name).read_bytes() for name in paths}
    calls = []

    async def new_translation(**kwargs):
        calls.append(kwargs["page_number"])
        return png("blue"), f"New page {kwargs['page_number']}", None

    original_replace = manga_publication.quota_replace
    failed = False

    def fail_second_image_once(source, target, **kwargs):
        nonlocal failed
        if target == folder / "2.translated.png" and not failed:
            failed = True
            raise OSError("simulated disk publication error")
        return original_replace(source, target, **kwargs)

    monkeypatch.setattr(scraper, "_translate_manga_page_with_pipeline", new_translation)
    monkeypatch.setattr(manga_publication, "quota_replace", fail_second_image_once)
    second = await enqueue(book, "translate")
    await main._run_task(second.id)
    assert failed and db.get_task(second.id).status == "failed"
    assert all((folder / name).read_bytes() == value for name, value in published.items())
    await main.post_retry_task(second.id, None)
    await main._run_task(second.id)
    assert db.get_task(second.id).status == "completed"
    assert calls == [1, 2]
    assert (await read(book)).pageTranslations == ["New page 1", "New page 2"]
    assert not list(folder.glob(".manga-translation-*.tmp"))
    assert not scraper.translated_checkpoint_path(folder, "1.txt").exists()


def test_failed_rollback_preserves_backup_even_when_marker_cannot_be_written(tmp_path, monkeypatch):
    from app import manga_publication

    folder = tmp_path / "book"
    stage = folder / ".manga-translation-123.tmp"
    stage.mkdir(parents=True)
    for directory, value in [(folder, b"old"), (stage, b"new")]:
        for name in ("1.png", "2.png"):
            (directory / name).write_bytes(value)
    original_replace = manga_publication.os.replace

    def publish(source, target, **_kwargs):
        if target.name == "2.png":
            raise OSError("publish failed")
        original_replace(source, target)

    def fail_rollback(*_args):
        raise OSError("rollback failed")

    def fail_marker(*_args, **_kwargs):
        raise OSError("marker write failed")

    monkeypatch.setattr(manga_publication, "quota_replace", publish)
    monkeypatch.setattr(manga_publication.os, "replace", fail_rollback)
    monkeypatch.setattr(Path, "write_text", fail_marker)
    with pytest.raises(RuntimeError, match="恢复副本已保留"):
        manga_publication.publish_staged_chapter(folder, stage, ["1.png", "2.png"])
    assert (stage / "__backup__/1.png").read_bytes() == b"old"
    assert (stage / "__backup__/2.png").read_bytes() == b"old"
    with pytest.raises(RuntimeError, match="上次译文发布尚未恢复"):
        manga_publication.publish_staged_chapter(folder, stage, ["1.png", "2.png"])
