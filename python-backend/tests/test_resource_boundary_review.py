import asyncio
import io
import json
import threading
from types import SimpleNamespace

import httpx
import pytest
import test_resource_limits as limits_base
import test_translation_quality as quality_base
from fastapi import HTTPException
from starlette.datastructures import UploadFile

from app import cover_storage, db, main, model_endpoint_security, translation_model_health
from app.api import translation_model
from app.book_import_execution import create_imported_book
from app.manifest_storage import save_manifest
from app.models import AddBookPayload, ChapterPreview, PreviewResponse, TranslationSettings
from app.resource_limits import (
    ResourceLimitError,
    ResourceLimitPatch,
    get_usage,
    resource_actor,
    update_limit,
)
from app.storage_meter import measure_owner_storage
from app.storage_models import StorageError
from app.storage_quota import quota_write_text

limits_db = limits_base.limits_db
quality_book = quality_base.quality_book


@pytest.mark.asyncio
async def test_forced_model_check_obeys_calling_admin_daily_limit(limits_db, monkeypatch):
    calls = []
    settings = TranslationSettings()
    settings.translationModel.enabled = True
    settings.translationModel.baseUrl = "https://models.example.test/v1"
    settings.translationModel.apiKey = "fixture-key"
    settings.translationModel.model = "fixture-model"
    access = SimpleNamespace(owner_id=limits_db, user=SimpleNamespace(id=limits_db))
    monkeypatch.setattr(translation_model, "require_user_access", lambda _: access)
    monkeypatch.setattr(translation_model, "require_admin_write_access", lambda _: access)
    monkeypatch.setattr(translation_model, "load_settings", lambda: settings)
    monkeypatch.setattr(
        model_endpoint_security,
        "ValidatedModelHTTPTransport",
        lambda **_: httpx.MockTransport(
            lambda request: calls.append(request)
            or httpx.Response(200, json={"choices": [{"message": {"content": "OK"}}]})
        ),
    )
    translation_model_health.reset_translation_model_check_cache()
    update_limit(limits_db, ResourceLimitPatch(expectedRevision=0, dailyModelRequests=0))
    with pytest.raises(ResourceLimitError):
        await translation_model.post_translation_model_check(object(), force=True)
    assert calls == []
    assert get_usage(limits_db).modelRequests == 0
    update_limit(limits_db, ResourceLimitPatch(expectedRevision=1, dailyModelRequests=1))
    result = await translation_model.post_translation_model_check(object(), force=True)
    assert result.available and len(calls) == 1
    passive = await translation_model.post_translation_model_check(object(), force=False)
    assert passive.cached and len(calls) == 1
    assert get_usage(limits_db).modelRequests == 1
    with pytest.raises(ResourceLimitError):
        await translation_model.post_translation_model_check(object(), force=True)
    assert len(calls) == 1
    translation_model_health.reset_translation_model_check_cache()


@pytest.mark.asyncio
async def test_provider_timeout_and_image_requests_consume_budget_but_get_does_not(limits_db, monkeypatch):
    calls = []

    def reply(request):
        calls.append(request)
        if len(calls) == 1:
            raise httpx.ReadTimeout("uncertain provider result")
        return httpx.Response(200, json={})

    monkeypatch.setattr(
        model_endpoint_security, "ValidatedModelHTTPTransport", lambda **_: httpx.MockTransport(reply)
    )
    update_limit(limits_db, ResourceLimitPatch(expectedRevision=0, dailyModelRequests=2))
    with resource_actor(limits_db):
        async with model_endpoint_security.create_model_http_client(timeout=1) as client:
            with pytest.raises(httpx.ReadTimeout):
                await client.post("https://models.example.test/v1/chat/completions", json={})
            await client.post("https://models.example.test/v1/images/edits", content=b"image")
            await client.get("https://models.example.test/generated.png")
            with pytest.raises(ResourceLimitError):
                await client.post("https://models.example.test/v1/chat/completions", json={})
    assert len(calls) == 3 and get_usage(limits_db).modelRequests == 2
    db.init_db()
    assert get_usage(limits_db).modelRequests == 2


@pytest.mark.asyncio
@pytest.mark.parametrize("stage", ["inspect", "write"])
async def test_cancelled_local_import_drains_worker_before_cleanup(limits_db, monkeypatch, stage):
    monkeypatch.setattr(main, "DATA_DIR", db.DATA_DIR)
    monkeypatch.setattr(main, "LIBRARY_ROOT", db.DATA_DIR / "library")
    monkeypatch.setattr(main, "require_user_access", lambda _: SimpleNamespace(owner_id=limits_db))
    started = asyncio.Event()
    release = threading.Event()
    finished = threading.Event()
    loop = asyncio.get_running_loop()
    attribute = "inspect_local_document" if stage == "inspect" else "write_local_document"
    original = getattr(main, attribute)

    def blocked(*args, **kwargs):
        loop.call_soon_threadsafe(started.set)
        try:
            assert release.wait(5)
            return original(*args, **kwargs)
        finally:
            finished.set()

    monkeypatch.setattr(main, attribute, blocked)
    upload = UploadFile(io.BytesIO("第一章\n\n完整正文。".encode()), filename="local.txt")
    task = asyncio.create_task(
        main.post_import_local(
            file=upload,
            bookKind="长小说",
            language="中文",
            request=object(),
            needTranslation=False,
            title="取消导入",
        )
    )
    try:
        await asyncio.wait_for(started.wait(), 2)
        task.cancel()
        await asyncio.sleep(0.02)
        assert not task.done(), "请求已退出但文件线程还未结束，会越过维护 gate 并过早释放上传文件"
        assert not upload.file.closed
    finally:
        release.set()
        await asyncio.gather(task, return_exceptions=True)
        await asyncio.to_thread(finished.wait, 2)
    assert finished.is_set() and upload.file.closed
    assert not any((db.DATA_DIR / "import-cache").iterdir())


@pytest.mark.parametrize("format", ["txt", "text", "docx", "epub"])
@pytest.mark.parametrize("single", [False, True])
def test_export_rejection_preserves_source_and_previous_artifacts(quality_book, monkeypatch, format, single):
    book, directory = quality_book
    monkeypatch.setattr(main, "DATA_DIR", db.DATA_DIR)
    monkeypatch.setattr(main, "EXPORT_ROOT", db.DATA_DIR / "exports")
    monkeypatch.setattr(main, "_resolve_book_dir", lambda _: directory)
    exports = db.DATA_DIR / "exports" / book.id
    exports.mkdir(parents=True)
    prior = exports / ("a" * 32 + ".txt")
    prior.write_bytes(b"previous export")
    before = {path: path.read_bytes() for path in directory.iterdir()}
    update_limit(
        book.ownerId, ResourceLimitPatch(expectedRevision=0, storageBytes=measure_owner_storage(book.ownerId))
    )
    with pytest.raises(ResourceLimitError):
        if single:
            main._export_chapter(book, 1, format)
        else:
            main._export_book(book, format)
    assert {path: path.read_bytes() for path in directory.iterdir()} == before
    assert list(exports.iterdir()) == [prior] and prior.read_bytes() == b"previous export"


@pytest.mark.asyncio
async def test_new_import_has_durable_owner_before_first_write_and_retry_reuses_book(limits_db):
    calls = []
    preview = PreviewResponse(
        title="新书",
        synopsis="",
        bookKind="长小说",
        chapterCount=1,
        chapters=[ChapterPreview(title="第一章", url="https://novel.example.test/1")],
    )
    payload = AddBookPayload(sourceUrl="https://novel.example.test/book", bookKind="长小说", language="中文")

    async def write(payload, preview, root):
        calls.append(root)
        directory = root / "中文" / "新书"
        quota_write_text(directory / "one.txt", "新作品正文")
        save_manifest(directory, {"chapters": [{"index": 1, "file_name": "one.txt"}]})
        return SimpleNamespace(
            title=preview.title, synopsis="", chapters=preview.chapters, local_path=directory, cover=None
        )

    runtime = SimpleNamespace(
        get_book=db.get_book,
        _hydrate_book_record=lambda book: book,
        _uses_manifest_only_import=lambda payload: False,
        LIBRARY_ROOT=db.DATA_DIR / "library",
        download_book=write,
        _site_account_download_kwargs=lambda *_: {},
        save_book=db.save_book,
        _storage_key_for_path=lambda path: path.relative_to(db.DATA_DIR).as_posix(),
        _now=lambda: "2026-09-11T00:00:00Z",
    )
    first = await create_imported_book(runtime, payload, preview, owner_id=limits_db, book_id="stable")
    second = await create_imported_book(runtime, payload, preview, owner_id=limits_db, book_id="stable")
    assert first.id == second.id and len(calls) == 1
    with db.get_connection() as connection:
        assert connection.execute("SELECT count(*) FROM storage_provisional_roots").fetchone()[0] == 0


@pytest.mark.asyncio
@pytest.mark.parametrize("empty", [False, True])
async def test_failed_new_extension_cover_preserves_existing_cover(quality_book, monkeypatch, empty):
    book, directory = quality_book
    monkeypatch.setattr(main, "DATA_DIR", db.DATA_DIR)
    monkeypatch.setattr(main, "_resolve_book_dir", lambda _: directory)
    monkeypatch.setattr(main, "require_user_access", lambda _: SimpleNamespace(owner_id=book.ownerId))
    cover = directory / "covers" / "custom-cover.png"
    cover.parent.mkdir()
    cover.write_bytes(b"previous cover")
    manifest_path = directory / "manifest.json"
    manifest = json.loads(manifest_path.read_text("utf-8"))
    manifest["cover_file"] = "covers/custom-cover.png"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    before = manifest_path.read_bytes()
    update_limit(book.ownerId, ResourceLimitPatch(expectedRevision=0, storageBytes=0))
    upload = UploadFile(io.BytesIO(b"" if empty else b"new cover"), filename="replacement.jpg")
    with pytest.raises((ResourceLimitError, HTTPException, StorageError)):
        await main.post_book_cover(book.id, upload, object())
    assert cover.is_file() and cover.read_bytes() == b"previous cover"
    assert not (cover.parent / "custom-cover.jpg").exists()
    assert manifest_path.read_bytes() == before


@pytest.mark.asyncio
async def test_failed_cover_manifest_commit_restores_previous_file(quality_book, monkeypatch):
    book, directory = quality_book
    monkeypatch.setattr(main, "DATA_DIR", db.DATA_DIR)
    monkeypatch.setattr(main, "_resolve_book_dir", lambda _: directory)
    monkeypatch.setattr(main, "require_user_access", lambda _: SimpleNamespace(owner_id=book.ownerId))
    cover = directory / "covers" / "custom-cover.png"
    cover.parent.mkdir()
    cover.write_bytes(b"previous cover")
    manifest_path = directory / "manifest.json"
    manifest = json.loads(manifest_path.read_text("utf-8"))
    manifest["cover_file"] = "covers/custom-cover.png"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    before = manifest_path.read_bytes()

    replace = cover_storage._replace_file
    attempted = []

    def reject_manifest(source, target):
        attempted.append(target)
        if target == manifest_path:
            raise ResourceLimitError("manifest quota exceeded", 413)
        replace(source, target)

    monkeypatch.setattr(cover_storage, "_replace_file", reject_manifest)
    upload = UploadFile(io.BytesIO(b"changed cover"), filename="replacement.png")
    with pytest.raises(ResourceLimitError):
        await main.post_book_cover(book.id, upload, object())
    assert cover.read_bytes() == b"previous cover"
    assert manifest_path.read_bytes() == before
    assert attempted == [cover, manifest_path]


@pytest.mark.asyncio
async def test_cover_response_uses_committed_manifest_without_background_rewrite(quality_book, monkeypatch):
    book, directory = quality_book
    monkeypatch.setattr(main, "DATA_DIR", db.DATA_DIR)
    monkeypatch.setattr(main, "_resolve_book_dir", lambda _: directory)
    monkeypatch.setattr(main, "require_user_access", lambda _: SimpleNamespace(owner_id=book.ownerId))

    def unexpected_hydration(*args):
        raise AssertionError("封面响应不得在事务完成后重新改写章节目录")

    monkeypatch.setattr(main, "_hydrate_book_record", unexpected_hydration)
    original = json.loads((directory / "manifest.json").read_text("utf-8"))
    upload = UploadFile(io.BytesIO(b"new cover"), filename="replacement.png")
    result = await main.post_book_cover(book.id, upload, object())
    assert result.cover.endswith("/assets/covers/custom-cover.png")
    changed = json.loads((directory / "manifest.json").read_text("utf-8"))
    assert changed == {**original, "cover_file": "covers/custom-cover.png", "cover_url": None}
