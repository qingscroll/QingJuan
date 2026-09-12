from __future__ import annotations

import asyncio
import threading
from contextlib import asynccontextmanager

import pytest
import test_translation_quality as base

from app import db
from app.storage_meter import measure_book_storage
from app.storage_models import StorageError
from app.storage_service import StorageService

quality_book = base.quality_book


@pytest.fixture
def exports(quality_book):
    book, directory = quality_book
    root = db.DATA_DIR / "exports" / book.id
    root.mkdir(parents=True)
    artifact = root / ("a" * 32 + ".epub")
    artifact.write_bytes(b"exported")
    (root / "keep.txt").write_bytes(b"unknown protected file")
    return book, directory, artifact


def service_for(events):
    @asynccontextmanager
    async def quiesce(operation):
        events.append(operation)

        async def reload():
            events.append("reload")

        try:
            yield reload
        finally:
            events.append("release")

    return StorageService(quiesce=quiesce)


@pytest.mark.asyncio
async def test_cleanup_only_removes_previewed_export_artifacts(exports):
    book, directory, artifact = exports
    source = {item.name: item.read_bytes() for item in directory.iterdir()}
    report = measure_book_storage(book)
    assert report.reclaimableBytes == 8
    assert report.totalBytes == sum(len(value) for value in source.values()) + 8 + 22
    assert [item.id for item in report.categories if item.cleanable] == ["exports"]
    events = []
    service = service_for(events)
    preview = service.preview(book, ["exports"])
    assert preview.totalBytes == 8 and preview.fileCount == 1
    assert all("path" not in key.lower() for key in preview.model_dump())
    result = await service.cleanup(book.id, book.ownerId, preview.cleanupId, preview.confirmationToken)
    assert result.deletedBytes == 8 and result.deletedFiles == 1 and result.storage.reclaimableBytes == 0
    assert not artifact.exists() and (artifact.parent / "keep.txt").exists()
    assert source == {item.name: item.read_bytes() for item in directory.iterdir()}
    assert events == ["storage-cleanup", "reload", "release"]


@pytest.mark.asyncio
@pytest.mark.parametrize("change", ["file", "owner", "token"])
async def test_changed_preview_or_wrong_owner_fails_under_gate_without_deleting(exports, change):
    book, _, artifact = exports
    events = []
    service = service_for(events)
    preview = service.preview(book, ["exports"])
    owner, token = book.ownerId, preview.confirmationToken
    if change == "file":
        artifact.write_bytes(b"replacement")
    elif change == "owner":
        owner = "another-user"
    else:
        token = "0" * 64
    with pytest.raises(StorageError) as error:
        await service.cleanup(book.id, owner, preview.cleanupId, token)
    assert error.value.status_code == (404 if change == "owner" else 409)
    assert artifact.exists() and events == ["storage-cleanup", "reload", "release"]


def test_symlink_export_never_enters_cleanup_or_storage_report(exports, tmp_path):
    book, _, artifact = exports
    outside = tmp_path / "private.txt"
    outside.write_bytes(b"private")
    link = artifact.parent / ("b" * 32 + ".zip")
    try:
        link.symlink_to(outside)
    except OSError:
        pytest.skip("Symlink privilege unavailable")
    with pytest.raises(StorageError):
        measure_book_storage(book)
    with pytest.raises(StorageError):
        service_for([]).preview(book, ["exports"])
    assert outside.read_bytes() == b"private"


@pytest.mark.asyncio
async def test_active_book_task_rejects_cleanup_and_keeps_export(exports):
    from app.models import TaskRecord

    book, _, artifact = exports
    db.save_task(
        TaskRecord(
            id="storage-active",
            bookId=book.id,
            taskType="translate",
            chapterIndexes=[1],
            status="running",
            totalCount=1,
            createdAt="2026-09-11",
            updatedAt="2026-09-11",
        )
    )
    service = service_for([])
    preview = service.preview(book, ["exports"])
    with pytest.raises(StorageError) as error:
        await service.cleanup(book.id, book.ownerId, preview.cleanupId, preview.confirmationToken)
    assert error.value.status_code == 409 and artifact.exists()


@pytest.mark.asyncio
async def test_cancelled_cleanup_keeps_gate_until_file_thread_finishes(exports, monkeypatch):
    book, _, artifact = exports
    events = []
    service = service_for(events)
    preview = service.preview(book, ["exports"])
    entered, finish = threading.Event(), threading.Event()
    original = service._delete

    def delayed(*args):
        entered.set()
        assert finish.wait(5)
        return original(*args)

    monkeypatch.setattr(service, "_delete", delayed)
    cleaning = asyncio.create_task(
        service.cleanup(book.id, book.ownerId, preview.cleanupId, preview.confirmationToken)
    )
    assert await asyncio.to_thread(entered.wait, 5)
    cleaning.cancel()
    await asyncio.sleep(0)
    assert events == ["storage-cleanup"] and artifact.exists()
    finish.set()
    with pytest.raises(asyncio.CancelledError):
        await cleaning
    assert events == ["storage-cleanup", "reload", "release"] and not artifact.exists()
