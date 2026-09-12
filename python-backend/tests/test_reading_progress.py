from __future__ import annotations

import sqlite3
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import db, main
from app.api.routers import library_router
from app.application import create_application
from app.models import BookRecord, ReadingProgressRecord
from app.security import API_PREFIX


@pytest.fixture
def progress_client(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "LIBRARY_ROOT", tmp_path / "library")
    db.init_db()
    book_dir = tmp_path / "library" / "book-progress"
    book_dir.mkdir(parents=True)
    (book_dir / "chapter.txt").write_text("第一段正文\n第二段正文", encoding="utf-8")
    db.save_book(BookRecord(
        id="book-progress", title="分页定位", sourceUrl="", bookKind="长小说",
        language="中文", status="已下载", chapterCount=1, translated=False,
        localPath="library/book-progress",
    ))
    main.save_manifest(book_dir, {
        "title": "分页定位",
        "chapters": [{"index": 1, "title": "第一章", "file_name": "chapter.txt"}],
    })
    application = create_application(routers=[library_router], api_prefix=API_PREFIX)
    with TestClient(application) as client:
        yield client


def test_pagination_progress_round_trips_through_database_detail_and_library(progress_client) -> None:
    payload = {
        "chapterIndex": 1, "scrollRatio": 0.4,
        "anchorType": "paragraph", "anchorIndex": 2, "anchorOffsetRatio": 0.3,
        "pageIndex": 4, "pageCount": 12, "layoutKey": "layout-v1:390x844:20",
        "contentMode": "translated", "characterOffset": 481,
    }
    response = progress_client.put(f"{API_PREFIX}/books/book-progress/progress", json=payload)
    assert response.status_code == 200, response.text
    expected = {
        "lastPageIndex": 4, "lastPageCount": 12, "lastLayoutKey": "layout-v1:390x844:20",
        "lastContentMode": "translated", "lastCharacterOffset": 481,
    }
    assert expected.items() <= response.json().items()
    stored = db.load_reading_progress("book-progress").model_dump()
    assert expected.items() <= stored.items()
    assert stored["lastAnchorIndex"] == 2
    assert stored["lastAnchorOffsetRatio"] == 0.3
    db.init_db()  # Repeated startup migration must preserve saved metadata.
    detail = progress_client.get(f"{API_PREFIX}/books/book-progress").json()
    assert expected.items() <= detail["progress"].items()
    library = progress_client.get(f"{API_PREFIX}/books").json()
    assert library[0]["lastReadPageIndex"] == 4
    assert library[0]["lastReadPageCount"] == 12
    assert db.get_book("book-progress").lastReadPageIndex == 4


def test_legacy_progress_save_clears_stale_page_and_content_metadata(progress_client) -> None:
    endpoint = f"{API_PREFIX}/books/book-progress/progress"
    response = progress_client.put(endpoint, json={
        "chapterIndex": 1, "pageIndex": 0, "pageCount": 3,
        "layoutKey": "layout-v1", "contentMode": "original", "characterOffset": 0,
    })
    assert response.status_code == 200
    response = progress_client.put(endpoint, json={
        "chapterIndex": 1, "anchorType": "paragraph", "anchorIndex": 1,
        "anchorOffsetRatio": 0.5,
    })
    assert response.status_code == 200
    assert response.json()["lastAnchorIndex"] == 1
    for key in ("lastPageIndex", "lastPageCount", "lastLayoutKey", "lastContentMode", "lastCharacterOffset"):
        assert response.json()[key] is None
        assert db.load_reading_progress("book-progress").model_dump()[key] is None
    assert db.get_book("book-progress").lastReadPageIndex is None


def test_removed_chapter_clears_page_metadata_in_detail_and_saved_progress(progress_client) -> None:
    db.save_reading_progress(ReadingProgressRecord(
        bookId="book-progress", lastChapterIndex=2, lastPageIndex=3, lastPageCount=8,
        lastLayoutKey="old-layout", lastContentMode="original", lastCharacterOffset=450,
    ))
    response = progress_client.get(f"{API_PREFIX}/books/book-progress")
    assert response.status_code == 200
    detail = response.json()
    assert detail["progress"]["lastChapterIndex"] == 1
    assert detail["progress"]["lastPageIndex"] is None
    assert detail["progress"]["lastCharacterOffset"] is None
    assert detail["book"]["lastReadChapterIndex"] == 1
    assert detail["book"]["lastReadPageIndex"] is None
    assert detail["book"]["lastReadPageCount"] is None
    assert db.load_reading_progress("book-progress").lastPageIndex is None


@pytest.mark.parametrize("fields", [
    {"pageIndex": -1}, {"pageCount": 0}, {"pageCount": -1},
    {"pageIndex": 3, "pageCount": 3}, {"pageIndex": 4, "pageCount": 3},
    {"layoutKey": "x" * 257}, {"contentMode": "both"},
    {"characterOffset": -1}, {"characterOffset": 2**63},
])
def test_invalid_page_metadata_is_rejected_without_saving(progress_client, fields) -> None:
    response = progress_client.put(
        f"{API_PREFIX}/books/book-progress/progress", json={"chapterIndex": 1, **fields},
    )
    assert response.status_code == 422, response.text
    assert db.load_reading_progress("book-progress").lastReadAt is None


def test_page_columns_migrate_without_changing_old_anchor_progress(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path,
) -> None:
    database = tmp_path / "qingjuan.db"
    with sqlite3.connect(database) as conn:
        conn.execute("""
            CREATE TABLE reading_progress (
                book_id TEXT PRIMARY KEY, last_chapter_index INTEGER NOT NULL,
                last_scroll_ratio REAL NOT NULL DEFAULT 0,
                last_anchor_type TEXT NOT NULL DEFAULT 'top',
                last_anchor_index INTEGER NOT NULL DEFAULT 0,
                last_anchor_offset_ratio REAL NOT NULL DEFAULT 0,
                last_read_at TEXT
            )
        """)
        conn.execute("INSERT INTO reading_progress VALUES (?, ?, ?, ?, ?, ?, ?)",
                     ("legacy-book", 2, 0.6, "paragraph", 5, 0.2, "2030-01-01T00:00:00Z"))
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", database)
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    db.init_db()
    db.init_db()
    progress = db.load_reading_progress("legacy-book")
    assert progress.lastChapterIndex == 2
    assert progress.lastAnchorIndex == 5
    assert progress.lastAnchorOffsetRatio == 0.2
    assert progress.lastPageIndex is None
    assert progress.lastCharacterOffset is None
    assert progress.lastReadAt == "2030-01-01T00:00:00Z"
    saved = progress.model_copy(update={"lastPageIndex": 1, "lastPageCount": 4})
    db.save_reading_progress(saved)
    assert db.load_reading_progress("legacy-book").lastPageIndex == 1


def test_progress_page_metadata_is_scoped_to_book_owner(progress_client) -> None:
    db.save_reading_progress(ReadingProgressRecord(
        ownerId="user-first", bookId="private-book", lastChapterIndex=1,
        lastPageIndex=2, lastPageCount=8, lastCharacterOffset=120,
    ))
    assert db.load_reading_progress("private-book", "user-first").lastPageIndex == 2
    other = db.load_reading_progress("private-book", "user-second")
    assert other.lastPageIndex is None
    assert other.lastCharacterOffset is None
