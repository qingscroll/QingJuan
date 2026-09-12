import json
from concurrent.futures import ThreadPoolExecutor

import pytest
from pydantic import ValidationError

from app import annotations as service
from app import annotations_repository as repository
from app import db
from app.annotations_models import AnnotationCreate, AnnotationPatch
from app.models import BookRecord


@pytest.fixture
def annotated_book(monkeypatch, tmp_path):
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    db.init_db()
    with db.get_connection() as connection:
        repository.ensure_annotations_schema(connection)
    folder = tmp_path / "library" / "notes"
    folder.mkdir(parents=True)
    (folder / "manifest.json").write_text(
        json.dumps(
            {
                "chapters": [
                    {"index": 1, "title": "开篇", "file_name": "one.txt"},
                    {"index": 2, "title": "未缓存", "file_name": "two.txt"},
                ]
            }
        ),
        encoding="utf-8",
    )
    (folder / "one.txt").write_text("原有正文😀\n\n第二段", encoding="utf-8")
    book = BookRecord(
        id="notes-book",
        ownerId="alice",
        title="作品",
        sourceUrl="",
        bookKind="长小说",
        language="中文",
        status="已下载",
        chapterCount=2,
        translated=False,
        localPath="library/notes",
    )
    db.save_book(book)
    return book, folder


def payload(key="client-key", **changes):
    return AnnotationCreate.model_validate(
        {
            "clientKey": key,
            "kind": "note",
            "label": "标注",
            "quote": "正文😀",
            "note": "我的想法",
            "position": {"chapterIndex": 1, "contentMode": "original", "characterOffset": 3},
            **changes,
        }
    )


def test_idempotent_create_survives_edit_and_preserves_all_source_files(annotated_book):
    book, folder = annotated_book
    before = {path.name: path.read_bytes() for path in folder.iterdir()}
    created = service.create_annotation(book, payload())
    assert created.revision == 1 and created.contentHash and not created.contentChanged
    edited = service.update_annotation(book, created.id, AnnotationPatch(expectedRevision=1, note="已修改"))
    assert edited.revision == 2 and edited.note == "已修改"
    retried = service.create_annotation(book, payload())
    assert retried.id == created.id and retried.note == "已修改"
    assert len(service.list_annotations(book)) == 1
    assert {path.name: path.read_bytes() for path in folder.iterdir()} == before
    with pytest.raises(repository.AnnotationConflict):
        service.create_annotation(book, payload(note="不同内容"))


def test_owner_scope_and_revision_delete(annotated_book):
    book, _ = annotated_book
    created = service.create_annotation(book, payload())
    for operation in [
        lambda: repository.list_annotations(book.id, "bob"),
        lambda: repository.get_annotation(book.id, "bob", created.id),
        lambda: repository.update_annotation(
            book.id, "bob", created.id, AnnotationPatch(expectedRevision=1, note="别人的"), None
        ),
        lambda: repository.delete_annotation(book.id, "bob", created.id, 1),
        lambda: repository.create_annotation(book.id, "bob", payload(), None),
    ]:
        with pytest.raises(KeyError):
            operation()
    with pytest.raises(repository.AnnotationConflict):
        repository.delete_annotation(book.id, "alice", created.id, 0)
    repository.delete_annotation(book.id, "alice", created.id, 1)
    assert service.list_annotations(book) == []
    with pytest.raises(repository.AnnotationConflict, match="已经删除"):
        service.create_annotation(book, payload())
    with db.get_connection() as connection:
        assert connection.execute(
            "SELECT label,quote,note,position_json FROM reading_annotations"
        ).fetchone() == ("", "", "", "{}")


def test_concurrent_edits_have_exactly_one_winner(annotated_book):
    book, _ = annotated_book
    created = service.create_annotation(book, payload())

    def edit(note):
        try:
            return service.update_annotation(book, created.id, AnnotationPatch(expectedRevision=1, note=note))
        except repository.AnnotationConflict:
            return None

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(edit, ["设备一", "设备二"]))
    assert sum(result is not None for result in results) == 1
    assert service.list_annotations(book)[0].revision == 2


def test_changed_chapter_is_flagged_and_note_edit_does_not_ack_change(annotated_book):
    book, folder = annotated_book
    created = service.create_annotation(book, payload())
    (folder / "one.txt").write_text("正文已经改变", encoding="utf-8")
    listed = service.list_annotations(book)[0]
    assert listed.contentChanged
    edited = service.update_annotation(
        book, created.id, AnnotationPatch(expectedRevision=1, note="保留原摘录")
    )
    assert edited.contentChanged and edited.contentHash == created.contentHash
    moved = service.update_annotation(
        book,
        created.id,
        AnnotationPatch(expectedRevision=2, position={"chapterIndex": 1, "characterOffset": 1}),
    )
    assert not moved.contentChanged and moved.contentHash != created.contentHash


def test_uncached_bookmark_and_kind_pagination(annotated_book):
    book, _ = annotated_book
    first = service.create_annotation(book, payload())
    mark = service.create_annotation(book, payload("bookmark", kind="bookmark", position={"chapterIndex": 2}))
    assert mark.contentHash is None
    assert service.list_annotations(book, kind="note")[0].id == first.id
    assert service.list_annotations(book, limit=1, offset=1)[0].id == first.id
    with pytest.raises(ValueError, match="阅读位置"):
        service.create_annotation(book, payload("bad-position", position={"chapterIndex": 3}))


@pytest.mark.parametrize(
    "changes",
    [{"position": None}, {"expectedRevision": True}, {"note": "\0"}, {"unknown": 1}, {"note": "a" * 20001}],
)
def test_patch_validation_rejects_invalid_inputs(changes):
    with pytest.raises(ValidationError):
        AnnotationPatch.model_validate({"expectedRevision": 1, **changes})


def test_noop_patch_retains_revision_and_delete_cascades(annotated_book):
    book, _ = annotated_book
    created = service.create_annotation(book, payload())
    same = service.update_annotation(book, created.id, AnnotationPatch(expectedRevision=1, note=" 我的想法 "))
    assert same.revision == created.revision and same.updatedAt == created.updatedAt
    with db.get_connection() as connection:
        connection.execute("DELETE FROM books WHERE id=?", (book.id,))
        assert connection.execute("SELECT count(*) FROM reading_annotations").fetchone()[0] == 0


def test_reader_chapter_mode_filter_applies_before_pagination_and_excludes_deleted(annotated_book):
    book, _ = annotated_book
    original = service.create_annotation(book, payload("original"))
    legacy = service.create_annotation(book, payload("legacy", position={"chapterIndex": 1}))
    for index in range(55):
        service.create_annotation(book, payload(f"other-{index}", position={"chapterIndex": 2}))
    translated = service.create_annotation(
        book,
        payload(
            "translated", position={"chapterIndex": 1, "contentMode": "translated", "characterOffset": 3}
        ),
    )
    result = service.list_annotations(book, kind="note", chapter_index=1, mode="original", limit=1)
    assert [item.id for item in result] == [legacy.id]
    assert [
        item.id
        for item in service.list_annotations(book, kind="note", chapter_index=1, mode="original", offset=1)
    ] == [original.id]
    assert [item.id for item in service.list_annotations(book, chapter_index=1, mode="translated")] == [
        translated.id
    ]
    repository.delete_annotation(book.id, book.ownerId, legacy.id, legacy.revision)
    assert [item.id for item in service.list_annotations(book, chapter_index=1, mode="original")] == [
        original.id
    ]


@pytest.mark.asyncio
async def test_reader_annotation_filter_api_validates_scope(annotated_book, monkeypatch):
    from types import SimpleNamespace

    import httpx
    from fastapi import FastAPI

    from app.api import annotations as api

    book, _ = annotated_book
    created = service.create_annotation(book, payload())
    application = FastAPI()
    application.include_router(api.router)
    monkeypatch.setattr(api, "require_user_access", lambda _: SimpleNamespace(owner_id=book.ownerId))
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=application), base_url="http://test"
    ) as client:
        response = await client.get(f"/books/{book.id}/annotations?chapterIndex=1&mode=original&kind=note")
        assert response.status_code == 200
        assert [item["id"] for item in response.json()] == [created.id]
        assert response.headers["Cache-Control"] == "no-store"
        assert (await client.get(f"/books/{book.id}/annotations?chapterIndex=0")).status_code == 422
        assert (await client.get(f"/books/{book.id}/annotations?mode=invalid")).status_code == 422
        monkeypatch.setattr(api, "require_user_access", lambda _: SimpleNamespace(owner_id="other"))
        assert (await client.get(f"/books/{book.id}/annotations?chapterIndex=1")).status_code == 404
