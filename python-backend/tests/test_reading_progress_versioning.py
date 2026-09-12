from concurrent.futures import ThreadPoolExecutor

import pytest

from app import db
from app import reading_progress_repository as repository
from app.models import BookRecord, ReadingProgressRecord


@pytest.fixture
def progress_database(tmp_path, monkeypatch):
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "progress.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    monkeypatch.setattr(db, "_SITE_PLUGIN_STATE_CACHE", None)
    db.init_db()
    with db.get_connection() as conn:
        repository.ensure_reading_progress_schema(conn)
    db.save_book(
        BookRecord(
            ownerId="user-admin",
            id="book",
            title="Book",
            sourceUrl="",
            bookKind="长小说",
            language="中文",
            status="已下载",
            chapterCount=9,
            translated=False,
            localPath="library/book",
            synopsis="",
        )
    )


def _position(chapter=3, owner="user-admin"):
    return ReadingProgressRecord(
        ownerId=owner,
        bookId="book",
        lastChapterIndex=chapter,
        lastScrollRatio=0.4,
        lastReadAt="2026-09-11T00:00:00Z",
    )


def test_old_devices_cannot_overwrite_newer_progress_and_rereading_is_allowed(progress_database):
    first = repository.save_progress(_position(8), expected_revision=0, operation_id="device-a-operation-1")
    assert first.revision == 1
    with pytest.raises(repository.ProgressConflict) as conflict:
        repository.save_progress(_position(9), expected_revision=0, operation_id="device-b-operation-1")
    assert conflict.value.code == "reading_progress_conflict"
    assert conflict.value.current.lastChapterIndex == 8
    assert conflict.value.current.revision == 1
    back = repository.save_progress(_position(2), expected_revision=1, operation_id="device-a-operation-2")
    assert back.lastChapterIndex == 2 and back.revision == 2


def test_legacy_writes_are_supported_until_first_versioned_write(progress_database):
    legacy = repository.save_progress(_position(1))
    assert legacy.revision == 1
    repository.save_progress(
        _position(2), expected_revision=legacy.revision, operation_id="new-client-operation"
    )
    with pytest.raises(repository.ProgressConflict) as error:
        repository.save_progress(_position(5))
    assert error.value.code == "reading_progress_upgrade_required"
    assert repository.load_progress("book", "user-admin").lastChapterIndex == 2


def test_response_loss_replay_is_exact_and_never_overwrites_newer_device(progress_database):
    first = repository.save_progress(_position(), expected_revision=0, operation_id="device-a-operation-1")
    repository.save_progress(_position(8), expected_revision=1, operation_id="device-b-operation-1")
    replay = repository.save_progress(
        _position().model_copy(update={"lastReadAt": "later"}),
        expected_revision=0,
        operation_id="device-a-operation-1",
    )
    assert replay == first
    assert repository.load_progress("book", "user-admin").lastChapterIndex == 8
    with pytest.raises(repository.ProgressConflict) as error:
        repository.save_progress(_position(7), expected_revision=0, operation_id="device-a-operation-1")
    assert error.value.code == "reading_progress_operation_reused"


def test_concurrent_cas_has_one_winner_and_owner_scope_cannot_be_reassigned(progress_database):
    def write(chapter):
        try:
            repository.save_progress(
                _position(chapter), expected_revision=0, operation_id=f"device-{chapter}-operation"
            )
            return True
        except repository.ProgressConflict:
            return False

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(write, [2, 3])) == [False, True]
    with pytest.raises(KeyError):
        repository.save_progress(
            _position(7, owner="somebody-else"), expected_revision=1, operation_id="foreign-operation-id"
        )
    assert repository.load_progress("book", "user-admin").revision == 1


def test_internal_adjustments_increment_revision_without_removing_protection(progress_database):
    repository.save_progress(_position(5), expected_revision=0, operation_id="device-a-operation-1")
    result = repository.save_progress_internal(_position(3))
    assert result.revision == 2
    with pytest.raises(repository.ProgressConflict):
        repository.save_progress(_position(8), expected_revision=1, operation_id="device-a-operation-2")
    with pytest.raises(repository.ProgressConflict):
        repository.save_progress(_position(8))
    with pytest.raises(KeyError):
        repository.save_progress_internal(_position(1, owner="another-user"))


def test_schema_migration_keeps_existing_progress(progress_database):
    repository.save_progress(_position(4))
    with db.get_connection() as conn:
        repository.ensure_reading_progress_schema(conn)
        repository.ensure_reading_progress_schema(conn)
    assert repository.load_progress("book", "user-admin").lastChapterIndex == 4
    assert repository.load_progress("book", "somebody-else").revision == 0


def test_http_conflict_has_stable_versioned_body_and_get_returns_current(progress_database, monkeypatch):
    from fastapi.testclient import TestClient

    from app import main
    from app.application import create_application
    from app.models import ChapterRecord

    monkeypatch.setattr(
        main,
        "_load_chapter_records",
        lambda book: [
            ChapterRecord(id=f"chapter-{i}", index=i, title=str(i), fileName=f"{i}.txt", wordCount=100)
            for i in range(1, 10)
        ],
    )
    with TestClient(create_application(routers=[main.library_router], api_prefix="/api/v1")) as client:
        assert client.get("/api/v1/books/book/progress").json()["revision"] == 0
        payload = {"chapterIndex": 8, "expectedRevision": 0, "operationId": "http-operation-id-1"}
        first = client.put("/api/v1/books/book/progress", json=payload)
        assert first.status_code == 200, first.text
        conflict = client.put(
            "/api/v1/books/book/progress", json={**payload, "operationId": "http-operation-id-2"}
        )
        assert conflict.status_code == 409
        assert conflict.json()["detail"]["code"] == "reading_progress_conflict"
        assert conflict.json()["detail"]["current"]["revision"] == 1
        assert "ownerId" not in conflict.json()["detail"]["current"]
        invalid = client.put("/api/v1/books/book/progress", json={"chapterIndex": 3, "expectedRevision": 1})
        assert invalid.status_code == 422
        assert client.get("/api/v1/books/book/progress").json()["lastChapterIndex"] == 8
