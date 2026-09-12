import sqlite3
import threading
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from functools import partial
from io import BytesIO
from types import SimpleNamespace

import pytest
import test_resource_limits as limits_base
import test_translation_quality as quality_base
from PIL import Image

from app import db, main, manga_download, scraper, storage_quota
from app.book_import_execution import create_imported_book
from app.manifest_storage import save_manifest
from app.models import AddBookPayload, ChapterPreview, PreviewResponse
from app.resource_limits import ResourceLimitError, ResourceLimitPatch, update_limit
from app.storage_meter import measure_owner_storage

quality_book = quality_base.quality_book
limits_db = limits_base.limits_db


def image_bytes(size):
    output = BytesIO()
    Image.new("RGB", (size, size), "red").save(output, "PNG")
    return output.getvalue()


@pytest.mark.parametrize("kind", ["chapter", "manifest", "image"])
@pytest.mark.parametrize("failure", ["quota", "replace"])
def test_real_chapter_manifest_and_image_writers_preserve_previous_file_on_publication_failure(
    quality_book, monkeypatch, kind, failure
):
    book, directory = quality_book
    if kind == "chapter":
        target = directory / "one.txt"
        write = partial(scraper._write_chapter_text_atomic, target, "更多新的正文。" * 100)
    elif kind == "manifest":
        target = directory / "manifest.json"
        write = partial(save_manifest, directory, {"chapters": [], "synopsis": "长简介" * 100})
    else:
        target = directory / "page.png"
        target.write_bytes(image_bytes(1))
        write = partial(manga_download.write_image_atomic, target, image_bytes(64))
    previous = target.read_bytes()
    all_before = {path: path.read_bytes() for path in directory.iterdir()}
    if failure == "quota":
        update_limit(
            book.ownerId,
            ResourceLimitPatch(expectedRevision=0, storageBytes=measure_owner_storage(book.ownerId)),
        )
    else:
        original = storage_quota.os.replace

        def fail_replace(source, destination):
            if destination == target and source != target:
                raise OSError("test publication failure")
            return original(source, destination)

        monkeypatch.setattr(storage_quota.os, "replace", fail_replace)
    with pytest.raises(ResourceLimitError if failure == "quota" else OSError):
        write()
    assert target.read_bytes() == previous
    assert {path: path.read_bytes() for path in directory.iterdir()} == all_before


@pytest.mark.asyncio
async def test_failed_online_import_keeps_durable_owner_and_charge_without_registered_book(limits_db):
    preview = PreviewResponse(
        title="未完成的书",
        synopsis="",
        bookKind="长小说",
        chapterCount=1,
        chapters=[ChapterPreview(title="第一章", url="https://novel.example.test/1")],
    )
    payload = AddBookPayload(sourceUrl="https://novel.example.test/book", bookKind="长小说", language="中文")
    update_limit(limits_db, ResourceLimitPatch(expectedRevision=0, storageBytes=5))

    async def download(payload, preview, root):
        directory = root / "中文" / "未完成的书"
        storage_quota.quota_write_bytes(directory / "one.txt", b"first")
        storage_quota.quota_write_bytes(directory / "two.txt", b"x" * 10)
        pytest.fail("Quota must reject the second download")

    runtime = SimpleNamespace(
        get_book=db.get_book,
        _uses_manifest_only_import=lambda _: False,
        LIBRARY_ROOT=db.DATA_DIR / "library",
        download_book=download,
        _site_account_download_kwargs=lambda *_: {},
    )
    with pytest.raises(ResourceLimitError):
        await create_imported_book(runtime, payload, preview, owner_id=limits_db, book_id="incomplete")
    assert db.get_book("incomplete", limits_db) is None
    assert measure_owner_storage(limits_db) == 5
    with db.get_connection() as conn:
        assert conn.execute("SELECT owner_id FROM storage_provisional_roots").fetchall() == [(limits_db,)]
    db.init_db()
    assert measure_owner_storage(limits_db) == 5
    with pytest.raises(ResourceLimitError):
        storage_quota.quota_write_bytes(
            db.DATA_DIR / "library" / limits_db / "incomplete" / "later.txt", b"more"
        )


def test_manga_batch_failure_cannot_let_another_writer_consume_space_that_rollback_needs(
    quality_book, monkeypatch
):
    book, directory = quality_book
    target = directory / "translated.png"
    target.write_bytes(b"old" * 100)
    old_bytes = target.read_bytes()
    before = measure_owner_storage(book.ownerId)
    update_limit(book.ownerId, ResourceLimitPatch(expectedRevision=0, storageBytes=before + 10))
    staging = directory / (".manga-translation-" + "f" * 32 + ".tmp")
    staging.mkdir()
    (staging / target.name).write_bytes(b"new")
    (staging / "second.png").write_bytes(b"huge" * 100)
    attempted, finished = threading.Event(), threading.Event()
    competitor = directory / "competing.txt"
    original = storage_quota.quota_replace
    futures = []

    def compete():
        attempted.set()
        try:
            storage_quota.quota_write_bytes(competitor, b"x" * 200)
            return True
        except ResourceLimitError:
            return False
        finally:
            finished.set()

    with ThreadPoolExecutor(max_workers=1) as executor:

        def interleave(source, destination, **kwargs):
            result = original(source, destination, **kwargs)
            if destination == target:
                futures.append(executor.submit(compete))
                assert attempted.wait(2)
                # The fixed batch holds its SQLite/lock boundary across all files.
                finished.wait(0.1)
            return result

        monkeypatch.setattr(storage_quota, "quota_replace", interleave)
        with pytest.raises(ResourceLimitError):
            main._publish_staged_manga_translation_files(directory, staging, [target.name, "second.png"])
        assert futures[0].result(timeout=5) is False
    assert target.read_bytes() == old_bytes
    assert not competitor.exists() and not (directory / "second.png").exists()
    assert measure_owner_storage(book.ownerId, published_only=True) == before


def test_manga_batch_database_commit_failure_restores_all_previous_files(quality_book, monkeypatch):
    _, directory = quality_book
    staging = directory / (".manga-translation-" + "f" * 32 + ".tmp")
    staging.mkdir()
    (directory / "first.png").write_bytes(b"old image")
    (staging / "first.png").write_bytes(b"new image")
    (staging / "second.png").write_bytes(b"new second image")
    connection = db.get_connection

    @contextmanager
    def fail_commit():
        with connection() as conn:
            yield conn
            raise sqlite3.OperationalError("commit failure")

    monkeypatch.setattr(db, "get_connection", fail_commit)
    with pytest.raises(sqlite3.Error):
        main._publish_staged_manga_translation_files(directory, staging, ["first.png", "second.png"])
    assert (directory / "first.png").read_bytes() == b"old image"
    assert not (directory / "second.png").exists()
    assert not list(directory.glob(".quota-*"))
