import json
from concurrent.futures import ThreadPoolExecutor

import pytest
from pydantic import ValidationError

from app import db
from app.library_metadata import (
    BookMetadataPatch,
    apply_book_metadata,
    get_book_metadata,
    metadata_manifest,
    read_source_manifest,
    update_book_metadata,
)
from app.library_metadata_repository import MetadataConflict, load_metadata, update_metadata
from app.models import BookRecord


@pytest.fixture
def source_book(monkeypatch, tmp_path):
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    db.init_db()
    folder = tmp_path / "library" / "source"
    folder.mkdir(parents=True)
    manifest = {
        "title": "源书名",
        "author": "来源作者",
        "synopsis": "来源简介",
        "chapters": [{"index": 1, "file_name": "001.txt", "translated_file_name": "001.zh.txt"}],
    }
    (folder / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    (folder / "001.txt").write_text("source text", encoding="utf-8")
    (folder / "001.zh.txt").write_text("原有译文", encoding="utf-8")
    book = BookRecord(
        id="metadata-book",
        ownerId="alice",
        title="源书名",
        sourceUrl="",
        bookKind="长小说",
        language="中文",
        status="已下载",
        chapterCount=1,
        translated=True,
        localPath="library/source",
        synopsis="数据库简介",
    )
    db.save_book(book)
    return book, folder, manifest


def test_overlay_preserves_source_and_chapters_and_survives_background_save(source_book):
    book, folder, source = source_book
    before = {path.name: path.read_bytes() for path in folder.iterdir()}
    result = update_book_metadata(
        book,
        BookMetadataPatch(
            expectedRevision=0,
            title="新书名",
            author="新作者",
            synopsis="",
            groupName="追更",
            tags=["奇幻"],
            pinned=True,
            readingState="finished",
        ),
    )
    assert result.revision == 1 and result.overriddenFields == ["title", "author", "synopsis"]
    display = apply_book_metadata(book)
    assert display.title == "新书名" and display.synopsis == "" and display.translated
    assert display.localPath == book.localPath and book.title == "源书名"
    exported = metadata_manifest(book, source)
    assert exported["title"] == "新书名" and exported["author"] == "新作者"
    assert exported["chapters"] == source["chapters"] and source["title"] == "源书名"
    db.save_book(book.model_copy(update={"chapterCount": 2, "title": "源标题更新"}))
    assert apply_book_metadata(db.get_book(book.id, owner_id="alice")).title == "新书名"
    assert {path.name: path.read_bytes() for path in folder.iterdir()} == before
    assert db.get_book(book.id, owner_id="alice").title == "源标题更新"


def test_partial_update_null_reset_and_noop_revision(source_book):
    book, _, _ = source_book
    first = update_book_metadata(
        book,
        BookMetadataPatch(
            expectedRevision=0, title="用户标题", groupName=" 我的书单 ", tags=["奇幻", " 奇幻 ", "冒险"]
        ),
    )
    assert first.tags == ["奇幻", "冒险"] and first.groupName == "我的书单"
    same = update_book_metadata(book, BookMetadataPatch(expectedRevision=1, title="用户标题"))
    assert same.revision == 1 and same.updatedAt == first.updatedAt
    reset = update_book_metadata(book, BookMetadataPatch(expectedRevision=1, title=None, groupName=None))
    assert reset.title == "源书名" and reset.groupName is None
    assert reset.tags == first.tags and reset.overriddenFields == [] and reset.revision == 2
    db.init_db()
    assert get_book_metadata(book).revision == 2


def test_concurrent_metadata_writers_have_one_winner(source_book):
    book, _, _ = source_book

    def write(index):
        try:
            return update_book_metadata(book, BookMetadataPatch(expectedRevision=0, title=f"标题{index}"))
        except MetadataConflict as error:
            return error

    with ThreadPoolExecutor(max_workers=6) as executor:
        results = list(executor.map(write, range(6)))
    assert sum(not isinstance(result, MetadataConflict) for result in results) == 1
    assert all(result.revision == 1 for result in results)


def test_metadata_owner_isolation_and_delete_cascade(source_book):
    book, _, _ = source_book
    update_book_metadata(book, BookMetadataPatch(expectedRevision=0, groupName="私有分组"))
    assert load_metadata(book.id, "bob") == ({}, 0, None)
    with pytest.raises(KeyError):
        update_metadata(book.id, "bob", {"title": "其他账号"}, expected_revision=0)
    with db.get_connection() as conn:
        conn.execute("DELETE FROM books WHERE id=?", (book.id,))
    assert load_metadata(book.id, "alice") == ({}, 0, None)


@pytest.mark.parametrize(
    "changes",
    [
        {},
        {"title": " "},
        {"pinned": "true"},
        {"expectedRevision": True, "title": "书名"},
        {"tags": [""]},
        {"tags": ["x" * 81]},
        {"tags": [str(i) for i in range(21)]},
        {"readingState": "deleted"},
        {"title": "x\0y"},
        {"chapterCount": 99},
    ],
)
def test_invalid_updates_are_rejected(changes):
    with pytest.raises(ValidationError):
        BookMetadataPatch.model_validate({"expectedRevision": 0, **changes})


def test_manifest_fallback_rejects_paths_outside_data_and_invalid_json(source_book, tmp_path):
    book, folder, _ = source_book
    outside = tmp_path.parent / f"{tmp_path.name}-outside"
    outside.mkdir()
    (outside / "manifest.json").write_text('{"author":"outside"}', encoding="utf-8")
    assert read_source_manifest(book.model_copy(update={"localPath": str(outside)})) == {}
    assert read_source_manifest(book)["author"] == "来源作者"
    (folder / "manifest.json").write_text('["wrong-shape"]', encoding="utf-8")
    assert read_source_manifest(book) == {}
    (folder / "manifest.json").write_bytes(b"\xff\xfeinvalid")
    assert read_source_manifest(book) == {}
