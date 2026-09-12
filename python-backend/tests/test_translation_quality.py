from __future__ import annotations

import json

import pytest

from app import db
from app.models import BookRecord
from app.translation_quality_models import GlossaryPatch, TranslationEdit, TranslationQualityError
from app.translation_quality_repository import ensure_translation_quality_schema
from app.translation_quality_service import get_chapter, get_glossary, save_chapter, save_glossary


@pytest.fixture
def quality_book(monkeypatch, tmp_path):
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    db.init_db()
    with db.get_connection() as conn:
        ensure_translation_quality_schema(conn)
    directory = tmp_path / "library" / "novel"
    directory.mkdir(parents=True)
    (directory / "manifest.json").write_text(
        json.dumps(
            {"book_kind": "长小说", "chapters": [{"index": 1, "title": "第一章", "file_name": "one.txt"}]}
        ),
        encoding="utf-8",
    )
    (directory / "one.txt").write_text("Hello Alice.\nGoodbye.", encoding="utf-8")
    (directory / "one.translated.txt").write_text("你好，爱丽丝。\n再见。", encoding="utf-8")
    book = BookRecord(
        id="quality-book",
        ownerId="user-admin",
        title="测试小说",
        sourceUrl="https://novel.example.test/1",
        bookKind="长小说",
        language="中文",
        status="已下载",
        chapterCount=1,
        translated=True,
        localPath="library/novel",
    )
    db.save_book(book)
    return book, directory


def edit(snapshot, text):
    return TranslationEdit(
        expectedRevision=snapshot.revision,
        sourceHash=snapshot.sourceHash,
        translationHash=snapshot.translationHash,
        text=text,
    )


def test_manual_edit_preserves_initial_history_and_rejects_stale_revision(quality_book):
    book, directory = quality_book
    before = get_chapter(book, 1)
    after = save_chapter(book, 1, edit(before, "你好，艾丽丝。\n再见。"))
    assert after.revision == 1
    assert {item.revision for item in after.history} == {0, 1}
    assert (directory / "one.translated.txt").read_text(encoding="utf-8") == after.translatedText
    with pytest.raises(TranslationQualityError) as error:
        save_chapter(book, 1, edit(before, "不能覆盖"))
    assert error.value.status_code == 409
    assert get_chapter(book, 1).translatedText == after.translatedText


def test_changed_original_file_cannot_be_overwritten_by_old_edit(quality_book):
    book, directory = quality_book
    before = get_chapter(book, 1)
    (directory / "one.txt").write_text("New original.", encoding="utf-8")
    with pytest.raises(TranslationQualityError) as error:
        save_chapter(book, 1, edit(before, "过期译文"))
    assert error.value.status_code == 409
    assert get_chapter(book, 1).translatedText == before.translatedText


def test_glossary_is_revisioned_and_does_not_change_source(quality_book):
    book, directory = quality_book
    initial = get_glossary(book)
    updated = save_glossary(
        book,
        GlossaryPatch(
            expectedRevision=initial.revision,
            entries=[{"source": "Alice", "target": "艾丽丝", "kind": "name", "note": "女主角"}],
        ),
    )
    assert updated.revision == 1
    assert updated.entries[0].target == "艾丽丝"
    with pytest.raises(TranslationQualityError):
        save_glossary(book, GlossaryPatch(expectedRevision=0, entries=[]))
    assert (directory / "one.txt").read_text(encoding="utf-8").startswith("Hello")


def test_only_downloaded_novels_and_safe_chapter_paths_are_editable(quality_book):
    book, directory = quality_book
    with pytest.raises(TranslationQualityError):
        get_chapter(book.model_copy(update={"bookKind": "漫画"}), 1)
    (directory / "one.txt").unlink()
    with pytest.raises(TranslationQualityError):
        get_chapter(book, 1)
    (directory / "manifest.json").write_text(
        json.dumps({"chapters": [{"index": 1, "title": "第一章", "file_name": "../../secret.txt"}]}),
        encoding="utf-8",
    )
    with pytest.raises(TranslationQualityError):
        get_chapter(book, 1)
