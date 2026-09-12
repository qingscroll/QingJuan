from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager

import pytest
import test_translation_quality as base

from app import db
from app import translation_quality_files as files
from app import translation_quality_service as service
from app.translation_quality_models import TranslationQualityError, TranslationRestore

quality_book = base.quality_book


@pytest.mark.parametrize("failure", ["file", "commit"])
def test_failed_file_publish_or_database_commit_restores_old_text_and_history(
    quality_book, monkeypatch, failure
):
    book, directory = quality_book
    (directory / "one.translated.txt").write_bytes("原有译文\r\n下一行。".encode())
    previous_bytes = (directory / "one.translated.txt").read_bytes()
    before = service.get_chapter(book, 1)
    original = service.atomic_write
    connection = db.get_connection

    def fail_file(path, text, **kwargs):
        if path.name.endswith("translated.txt"):
            raise OSError("private-disk-path")
        return original(path, text, **kwargs)

    @contextmanager
    def fail_commit():
        with connection() as conn:
            yield conn
            if conn.in_transaction:
                raise sqlite3.OperationalError("private-database-error")

    with monkeypatch.context() as patch:
        patch.setattr(service, "atomic_write", fail_file) if failure == "file" else patch.setattr(
            db, "get_connection", fail_commit
        )
        with pytest.raises((OSError, sqlite3.Error)):
            service.save_chapter(book, 1, base.edit(before, "新的校对译文"))
    after = service.get_chapter(book, 1)
    assert after == before
    assert (directory / "one.translated.txt").read_bytes() == previous_bytes
    assert not list(directory.glob(".translation-quality-*.json"))


@pytest.mark.parametrize("committed", [True, False])
def test_startup_reconciles_interrupted_file_swap_against_committed_sqlite_revision(quality_book, committed):
    book, directory = quality_book
    chapter = files.chapter_files(book, 1)
    text = "已提交的新版译文"
    files.prepare_journal(chapter, book, 1, 1, text)
    files.atomic_write(chapter.translated, text)
    if committed:
        with db.get_connection() as conn:
            conn.execute(
                "INSERT INTO translation_quality_state VALUES(?,?,?,?,?,?)",
                (book.id, 1, book.ownerId, 1, files.digest(chapter.source_text), files.digest(text)),
            )
    files.recover_translation_quality_writes(db.DATA_DIR)
    assert chapter.translated.read_text(encoding="utf-8") == (text if committed else chapter.translated_text)
    assert not chapter.journal.exists()


def test_history_restore_creates_a_new_version_and_rejects_original_changes(quality_book):
    book, directory = quality_book
    before = service.get_chapter(book, 1)
    updated = service.save_chapter(book, 1, base.edit(before, "新译文"))
    oldest = updated.history[-1]
    assert service.get_history(book, 1, oldest.id).text == before.translatedText
    payload = TranslationRestore(
        expectedRevision=updated.revision,
        sourceHash=updated.sourceHash,
        translationHash=updated.translationHash,
        historyId=oldest.id,
    )
    restored = service.restore_chapter(book, 1, payload)
    assert restored.translatedText == before.translatedText
    assert restored.revision == 2
    assert restored.history[0].kind == "restore"
    (directory / "one.txt").write_text("原文已更新", encoding="utf-8")
    current = service.get_chapter(book, 1)
    with pytest.raises(TranslationQualityError) as error:
        service.restore_chapter(
            book,
            1,
            payload.model_copy(
                update={
                    "expectedRevision": current.revision,
                    "sourceHash": current.sourceHash,
                    "translationHash": current.translationHash,
                }
            ),
        )
    assert error.value.status_code == 409


def test_running_task_and_other_owner_cannot_edit(quality_book):
    from app.models import TaskRecord

    book, _ = quality_book
    before = service.get_chapter(book, 1)
    db.save_task(
        TaskRecord(
            id="active",
            bookId=book.id,
            taskType="translate",
            chapterIndexes=[1],
            status="running",
            totalCount=1,
            createdAt="2026-09-11",
            updatedAt="2026-09-11",
        )
    )
    with pytest.raises(TranslationQualityError) as error:
        service.save_chapter(book, 1, base.edit(before, "不能覆盖"))
    assert error.value.status_code == 409
    with pytest.raises(TranslationQualityError) as error:
        service.get_chapter(book.model_copy(update={"ownerId": "someone-else"}), 1)
    assert error.value.status_code == 404


def test_recovery_journal_cannot_target_source_text(quality_book):
    book, directory = quality_book
    chapter = files.chapter_files(book, 1)
    files.prepare_journal(chapter, book, 1, 1, "新译文")
    record = json.loads(chapter.journal.read_text(encoding="utf-8"))
    record["fileName"] = "one.txt"
    chapter.journal.write_text(json.dumps(record), encoding="utf-8")
    with pytest.raises(TranslationQualityError):
        files.recover_translation_quality_writes(db.DATA_DIR)
    assert (directory / "one.txt").read_text(encoding="utf-8") == chapter.source_text


def test_over_quota_quality_edit_keeps_exact_old_bytes_history_and_source(quality_book):
    from app.resource_limits import ResourceLimitError
    from app.storage_meter import measure_owner_storage

    book, directory = quality_book
    translated = directory / "one.translated.txt"
    translated.write_bytes("旧译文\r\n保留。".encode())
    original_bytes = translated.read_bytes()
    before = service.get_chapter(book, 1)
    limit = measure_owner_storage(book.ownerId)
    with db.get_connection() as conn:
        conn.execute("INSERT INTO resource_limits VALUES(?,?,NULL,0)", (book.ownerId, limit))
    with pytest.raises(ResourceLimitError) as error:
        service.save_chapter(book, 1, base.edit(before, "新增很长的译文" * 100))
    assert error.value.status_code == 413
    assert translated.read_bytes() == original_bytes
    assert service.get_chapter(book, 1) == before
    assert not list(directory.glob(".translation-quality-*.json"))


def test_recovery_of_shrinking_edit_can_restore_over_quota_original(quality_book, monkeypatch):
    book, directory = quality_book
    translated = directory / "one.translated.txt"
    before = service.get_chapter(book, 1)
    original_bytes = translated.read_bytes()
    with db.get_connection() as conn:
        conn.execute("INSERT INTO resource_limits VALUES(?,0,NULL,0)", (book.ownerId,))
    connection = db.get_connection

    @contextmanager
    def fail_commit():
        with connection() as conn:
            yield conn
            if conn.in_transaction:
                raise sqlite3.OperationalError("commit failure")

    with monkeypatch.context() as patch:
        patch.setattr(db, "get_connection", fail_commit)
        with pytest.raises(sqlite3.Error):
            service.save_chapter(book, 1, base.edit(before, "小"))
    assert translated.read_bytes() == original_bytes
    assert service.get_chapter(book, 1) == before
