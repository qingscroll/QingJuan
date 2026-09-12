from __future__ import annotations

import sqlite3
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from pathlib import Path

import pytest
import test_translation_quality as base

from app import db
from app import storage_quota as quota
from app.resource_limits import ResourceLimitError
from app.storage_meter import measure_owner_storage
from app.storage_models import StorageError

quality_book = base.quality_book


def set_limit(owner, value):
    with db.get_connection() as conn:
        conn.execute("INSERT OR REPLACE INTO resource_limits VALUES(?,?,NULL,0)", (owner, value))


def test_quota_counts_actual_owned_files_and_exports_preserves_previous_on_failure(quality_book):
    book, directory = quality_book
    target = directory / "new.txt"
    current = measure_owner_storage(book.ownerId)
    set_limit(book.ownerId, current + 4)
    quota.quota_write_bytes(target, b"1234")
    assert measure_owner_storage(book.ownerId) == current + 4
    with pytest.raises(ResourceLimitError) as error:
        quota.quota_write_bytes(target, b"12345")
    assert error.value.status_code == 413 and target.read_bytes() == b"1234"
    export = db.DATA_DIR / "exports" / book.id / ("a" * 32 + ".zip")
    with pytest.raises(ResourceLimitError):
        quota.quota_write_bytes(export, b"x")
    assert not export.exists()
    set_limit(book.ownerId, 0)
    quota.quota_write_bytes(target, b"1")
    assert target.read_bytes() == b"1"  # Reduced limits still allow existing files to shrink.
    assert not list(directory.glob(".quota-*"))


def test_concurrent_writers_cannot_both_consume_the_same_remaining_space(quality_book):
    book, directory = quality_book
    current = measure_owner_storage(book.ownerId)
    set_limit(book.ownerId, current + 10)

    def write(name):
        try:
            quota.quota_write_bytes(directory / name, b"x" * 10)
            return True
        except ResourceLimitError:
            return False

    with ThreadPoolExecutor(max_workers=2) as workers:
        results = list(workers.map(write, ["a.txt", "b.txt"]))
    assert sorted(results) == [False, True]
    assert measure_owner_storage(book.ownerId) == current + 10


def test_failed_transaction_commit_rolls_back_atomic_file_publish(quality_book, monkeypatch):
    _, directory = quality_book
    target = directory / "one.txt"
    original = target.read_bytes()
    connection = db.get_connection

    @contextmanager
    def fail_commit():
        with connection() as conn:
            yield conn
            raise sqlite3.OperationalError("commit failure")

    with monkeypatch.context() as patch:
        patch.setattr(db, "get_connection", fail_commit)
        with pytest.raises(sqlite3.Error):
            quota.quota_write_bytes(target, b"new content")
    assert target.read_bytes() == original
    assert not list(directory.glob(".quota-*"))


@pytest.mark.parametrize("commit_fails", [False, True])
def test_hard_link_failure_copies_and_flushes_backup_before_publish_or_rollback(
    quality_book, monkeypatch, commit_fails
):
    _, directory = quality_book
    target = directory / "one.txt"
    previous = target.read_bytes()
    connection = db.get_connection
    copy_file = quota.shutil.copy2
    copies = []

    def fail_link(*args, **kwargs):
        raise OSError("hard links unavailable")

    def record_copy(source, destination):
        result = copy_file(source, destination)
        copies.append((source, destination.read_bytes()))
        return result

    @contextmanager
    def fail_commit():
        with connection() as conn:
            yield conn
            raise sqlite3.OperationalError("commit failure")

    monkeypatch.setattr(quota.os, "link", fail_link)
    monkeypatch.setattr(quota.shutil, "copy2", record_copy)
    if commit_fails:
        monkeypatch.setattr(db, "get_connection", fail_commit)
        with pytest.raises(sqlite3.Error):
            quota.quota_write_bytes(target, b"new content")
    else:
        quota.quota_write_bytes(target, b"new content")
    assert copies == [(target, previous)]
    assert target.read_bytes() == (previous if commit_fails else b"new content")
    assert not list(directory.glob(".quota-*"))


@pytest.mark.parametrize("copy_fallback", [False, True])
def test_failed_commit_and_failed_restore_keep_last_old_copy(quality_book, monkeypatch, copy_fallback):
    _, directory = quality_book
    target = directory / "one.txt"
    previous = target.read_bytes()
    connection = db.get_connection
    replace = quota.os.replace
    restored = []

    @contextmanager
    def fail_commit():
        with connection() as conn:
            yield conn
            assert target.read_bytes() == b"new published content"
            raise sqlite3.OperationalError("commit failure")

    def fail_restore(source, destination):
        if source.suffix == ".old" and destination == target:
            restored.append(source)
            assert source.read_bytes() == previous
            raise OSError("restore storage failure")
        return replace(source, destination)

    def fail_link(*args, **kwargs):
        raise OSError("hard links unavailable")

    monkeypatch.setattr(db, "get_connection", fail_commit)
    monkeypatch.setattr(quota.os, "replace", fail_restore)
    if copy_fallback:
        monkeypatch.setattr(quota.os, "link", fail_link)
    with pytest.raises(StorageError) as error:
        quota.quota_write_bytes(target, b"new published content")
    assert error.value.status_code == 503 and "恢复副本已保留" in str(error.value)
    assert str(directory) not in str(error.value)
    assert target.read_bytes() == b"new published content"
    backups = list(directory.glob(".quota-*.old"))
    assert backups == restored and len(backups) == 1
    assert backups[0].read_bytes() == previous
    assert not list(directory.glob(".quota-*.tmp"))
    assert_publication_lock_released()


def test_failed_commit_and_failed_new_file_removal_report_retained_file(quality_book, monkeypatch):
    _, directory = quality_book
    target = directory / "new.txt"
    connection = db.get_connection
    unlink = Path.unlink

    @contextmanager
    def fail_commit():
        with connection() as conn:
            yield conn
            assert target.read_bytes() == b"new published content"
            raise sqlite3.OperationalError("commit failure")

    def fail_remove(path, *args, **kwargs):
        if path == target:
            raise OSError("remove storage failure")
        return unlink(path, *args, **kwargs)

    monkeypatch.setattr(db, "get_connection", fail_commit)
    monkeypatch.setattr(Path, "unlink", fail_remove)
    with pytest.raises(StorageError) as error:
        quota.quota_write_bytes(target, b"new published content")
    assert error.value.status_code == 503 and "未能移除新文件" in str(error.value)
    assert str(directory) not in str(error.value)
    assert target.read_bytes() == b"new published content"
    assert not list(directory.glob(".quota-*"))
    assert_publication_lock_released()


def assert_publication_lock_released():
    def acquire_elsewhere():
        acquired = quota.PUBLISH_LOCK.acquire(timeout=1)
        if acquired:
            quota.PUBLISH_LOCK.release()
        return acquired

    with ThreadPoolExecutor(max_workers=1) as worker:
        assert worker.submit(acquire_elsewhere).result(timeout=2)


def test_provisional_roots_are_billed_after_failure_and_removed_after_nested_book_registration(quality_book):
    book, _ = quality_book
    root = db.DATA_DIR / "library" / "imported"
    initial = measure_owner_storage(book.ownerId)
    with pytest.raises(RuntimeError), quota.provisional_book_storage(book.ownerId, root):
        quota.quota_write_bytes(root / "lang" / "title" / "one.txt", b"new book")
        raise RuntimeError("interrupted")
    assert measure_owner_storage(book.ownerId) == initial + 8
    with db.get_connection() as conn:
        assert conn.execute("SELECT count(*) FROM storage_provisional_roots").fetchone()[0] == 1
    with quota.provisional_book_storage(book.ownerId, root):
        db.save_book(book.model_copy(update={"id": "nested", "localPath": "library/imported/lang/title"}))
    with db.get_connection() as conn:
        assert conn.execute("SELECT count(*) FROM storage_provisional_roots").fetchone()[0] == 0
    assert measure_owner_storage(book.ownerId) == initial + 8


def test_provisional_orphans_outside_registered_book_remain_billed(quality_book):
    book, _ = quality_book
    root = db.DATA_DIR / "library" / "imported"
    with quota.provisional_book_storage(book.ownerId, root):
        quota.quota_write_bytes(root / "orphan.txt", b"orphan")
        quota.quota_write_bytes(root / "actual" / "one.txt", b"book")
        db.save_book(book.model_copy(update={"id": "nested", "localPath": "library/imported/actual"}))
    with db.get_connection() as conn:
        assert conn.execute("SELECT count(*) FROM storage_provisional_roots").fetchone()[0] == 1


def test_managed_writes_require_owner_but_standalone_temporary_files_keep_existing_behavior(
    quality_book, tmp_path
):
    book, directory = quality_book
    with pytest.raises(StorageError) as wrong:
        quota.quota_write_text(directory / "x.txt", "other", owner_id="another-user")
    assert wrong.value.status_code == 403
    with pytest.raises(StorageError):
        quota.quota_write_text(db.DATA_DIR / "library" / "unknown" / "one.txt", "orphan")
    # Outside managed library/exports, caller's original path validation remains authoritative.
    external = tmp_path / "system-temp" / "image.bin"
    quota.quota_write_bytes(external, b"allowed")
    assert external.read_bytes() == b"allowed"
    empty_root = db.DATA_DIR / "library" / "empty-import"
    with quota.provisional_book_storage(book.ownerId, empty_root):
        pass
    with db.get_connection() as conn:
        assert conn.execute("SELECT count(*) FROM storage_provisional_roots").fetchone()[0] == 0


def test_internal_manga_staging_is_not_double_counted_but_final_publish_obeys_quota(quality_book):
    book, directory = quality_book
    before = measure_owner_storage(book.ownerId)
    set_limit(book.ownerId, before + 4)
    staged = directory / (".manga-translation-" + "a" * 32 + ".tmp") / "image.png"
    quota.quota_write_bytes(staged, b"x" * 100)
    assert measure_owner_storage(book.ownerId) == before + 100
    assert measure_owner_storage(book.ownerId, published_only=True) == before
    with pytest.raises(ResourceLimitError):
        quota.quota_replace(staged, directory / "image.png")
    assert staged.exists() and not (directory / "image.png").exists()
    quota.quota_write_bytes(staged, b"1234")
    quota.quota_replace(staged, directory / "image.png")
    assert measure_owner_storage(book.ownerId, published_only=True) == before + 4
