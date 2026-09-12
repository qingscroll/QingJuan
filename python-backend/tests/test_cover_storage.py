import json
import sqlite3
from contextlib import contextmanager

import pytest
import test_translation_quality as base

from app import cover_storage, db
from app.models import TaskRecord
from app.resource_limits import ResourceLimitPatch, update_limit
from app.storage_meter import measure_owner_storage
from app.storage_models import StorageError

quality_book = base.quality_book


def original_cover(directory):
    path = directory / "covers" / "custom-cover.png"
    path.parent.mkdir()
    path.write_bytes(b"o" * 200)
    manifest = json.loads((directory / "manifest.json").read_text("utf-8"))
    manifest.update(cover_file="covers/custom-cover.png", cover_url=None)
    (directory / "manifest.json").write_bytes(
        json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8")
    )
    return path, manifest


def test_full_account_can_change_extension_when_final_publication_shrinks(quality_book, monkeypatch):
    book, directory = quality_book
    old, manifest = original_cover(directory)
    initial = measure_owner_storage(book.ownerId)
    update_limit(book.ownerId, ResourceLimitPatch(expectedRevision=0, storageBytes=initial))
    replace = cover_storage._replace_file
    stages = []

    def checked_replace(source, target):
        assert old.exists(), "旧扩展名封面必须保留到新封面与目录发布完成"
        stages.append(target.name)
        replace(source, target)

    monkeypatch.setattr(cover_storage, "_replace_file", checked_replace)
    cover_storage.publish_cover(book, directory, ".jpg", b"n" * 50, "2026-09-11T12:00:00Z")
    assert not old.exists()
    assert (directory / "covers" / "custom-cover.jpg").read_bytes() == b"n" * 50
    changed = json.loads((directory / "manifest.json").read_text("utf-8"))
    assert changed == {**manifest, "cover_file": "covers/custom-cover.jpg"}
    assert stages == ["custom-cover.jpg", "manifest.json"]
    assert measure_owner_storage(book.ownerId) == initial - 150
    assert db.get_book(book.id).updatedAt == "2026-09-11T12:00:00Z"
    assert not list(directory.rglob(".quota-*"))


def test_database_commit_failure_restores_manifest_both_cover_paths_and_timestamp(quality_book, monkeypatch):
    book, directory = quality_book
    old, _ = original_cover(directory)
    before = {path: path.read_bytes() for path in directory.rglob("*") if path.is_file()}
    timestamp = db.get_book(book.id).updatedAt
    connect = db.get_connection

    @contextmanager
    def fail_commit():
        with connect() as connection:
            yield connection
            if connection.in_transaction:
                raise sqlite3.OperationalError("commit rejected")

    with monkeypatch.context() as patch:
        patch.setattr(db, "get_connection", fail_commit)
        with pytest.raises(sqlite3.OperationalError):
            cover_storage.publish_cover(book, directory, ".jpg", b"changed", "new timestamp")
    assert {path: path.read_bytes() for path in directory.rglob("*") if path.is_file()} == before
    assert old.exists() and db.get_book(book.id).updatedAt == timestamp


@pytest.mark.parametrize("status", ["running", "pause_requested", "cancel_requested"])
def test_active_chapter_task_prevents_stale_manifest_cover_overwrite(quality_book, status):
    book, directory = quality_book
    old, _ = original_cover(directory)
    db.save_task(
        TaskRecord(
            id="active",
            ownerId=book.ownerId,
            bookId=book.id,
            taskType="download",
            chapterIndexes=[1],
            status=status,
            totalCount=1,
            createdAt="now",
            updatedAt="now",
        )
    )
    with pytest.raises(StorageError, match="正在处理章节") as error:
        cover_storage.publish_cover(book, directory, ".jpg", b"changed", "new timestamp")
    assert error.value.status_code == 409 and old.exists()
    assert not (old.parent / "custom-cover.jpg").exists()


def test_corrupt_manifest_and_oversized_cover_do_not_write(quality_book, monkeypatch):
    book, directory = quality_book
    old, _ = original_cover(directory)
    monkeypatch.setattr(cover_storage, "MAX_COVER_BYTES", 5)
    with pytest.raises(StorageError) as error:
        cover_storage.publish_cover(book, directory, ".png", b"x" * 6, "timestamp")
    assert error.value.status_code == 413 and old.read_bytes() == b"o" * 200
    (directory / "manifest.json").write_bytes(b"not JSON")
    with pytest.raises(StorageError, match="目录格式"):
        cover_storage.publish_cover(book, directory, ".jpg", b"new", "timestamp")
    assert old.read_bytes() == b"o" * 200 and not list(directory.rglob(".quota-*"))
