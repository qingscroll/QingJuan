import asyncio
import copy
import json
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import httpx
import pytest
from fastapi import FastAPI

from app import book_updates_repository as repository
from app import db
from app.book_updates import BookUpdateService, original_source_payload
from app.book_updates_merge import append_new_chapters
from app.book_updates_models import BookUpdateSettings
from app.maintenance import MaintenanceGate
from app.manifest_storage import save_manifest
from app.models import BookRecord, ChapterPreview, PreviewResponse, ReadingProgressRecord, TaskRecord


@pytest.fixture
def tracked(monkeypatch, tmp_path):
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    monkeypatch.setattr(db, "_SITE_PLUGIN_STATE_CACHE", None)
    db.init_db()
    with db.get_connection() as conn:
        repository.ensure_book_updates_schema(conn)
    folder = tmp_path / "library" / "serial"
    folder.mkdir(parents=True)
    source = {
        "title": "原书名",
        "source_url": "https://serial.example/book",
        "site_plugin_id": "generic-web",
        "chapter_count": 1,
        "chapters": [
            {
                "index": 7,
                "title": "原章节",
                "url": "https://serial.example/1",
                "file_name": "original.txt",
                "translated_file_name": "original.zh.txt",
                "downloaded": True,
                "translated": True,
                "image_files": ["page.png"],
                "extra": {"keep": True},
            }
        ],
    }
    book = BookRecord(
        id="serial",
        ownerId="alice",
        title="原书名",
        sourceUrl=source["source_url"],
        bookKind="长小说",
        language="中文",
        status="已完成",
        chapterCount=1,
        translated=True,
        localPath="library/serial",
    )
    db.save_book(book)
    save_manifest(folder, source)
    for filename, content in [("original.txt", "原文"), ("original.zh.txt", "译文"), ("page.png", "image")]:
        (folder / filename).write_text(content, encoding="utf-8")
    incoming = [
        ChapterPreview(title="网页改名也不得覆盖原章", url="https://serial.example/1"),
        ChapterPreview(title="新章节", url="https://serial.example/2"),
    ]

    async def preview(payload):
        return PreviewResponse(
            title="网页新标题", chapters=incoming, chapterCount=len(incoming), bookKind="长小说"
        )

    downloads = []
    locks = {}
    runtime = SimpleNamespace(
        DATA_DIR=tmp_path,
        app=SimpleNamespace(state=SimpleNamespace(maintenance_gate=MaintenanceGate())),
        _resolve_book_dir=lambda book: tmp_path / book.localPath,
        load_manifest=lambda directory: json.loads((directory / "manifest.json").read_text(encoding="utf-8")),
        save_manifest=save_manifest,
        preview_from_url=preview,
        _chapter_manifest_lock_for=lambda book_id: locks.setdefault(book_id, asyncio.Lock()),
        _chapter_needs_source_cache=lambda directory, chapter: not (
            directory / chapter["file_name"]
        ).is_file(),
        _get_chapter_cache_coordinator=lambda: SimpleNamespace(
            schedule=lambda book_id, indexes: downloads.append((book_id, indexes))
        ),
    )
    clock = [datetime(2026, 9, 11, tzinfo=UTC)]
    service = BookUpdateService(runtime, now=lambda: clock[0])
    return SimpleNamespace(
        book=book,
        folder=folder,
        source=source,
        runtime=runtime,
        service=service,
        incoming=incoming,
        clock=clock,
        downloads=downloads,
    )


def _configure(tracked, *, auto=True):
    return tracked.service.configure(
        "serial", "alice", BookUpdateSettings(expectedRevision=0, enabled=True, autoDownload=auto)
    )


def _task(status):
    db.save_task(
        TaskRecord(
            id="worker",
            ownerId="alice",
            bookId="serial",
            taskType="download",
            chapterIndexes=[7],
            status=status,
            totalCount=1,
            createdAt="2026-09-11T00:00:00Z",
            updatedAt="2026-09-11T00:00:00Z",
        )
    )


def test_merge_only_appends_preserving_order_indexes_and_all_fields(tracked):
    before = copy.deepcopy(tracked.source)
    incoming = [tracked.incoming[1], tracked.incoming[0], tracked.incoming[1]]
    merged, added = append_new_chapters(tracked.source, incoming)
    assert added == [8]
    assert merged["chapters"][0] == before["chapters"][0]
    assert merged["chapters"][1]["url"] == tracked.incoming[1].url
    assert merged["chapters"][1]["translated"] is False
    assert tracked.source == before
    assert append_new_chapters(merged, incoming)[1] == []


@pytest.mark.parametrize(
    "chapters",
    [
        [],
        [ChapterPreview(title="其他作品", url="https://serial.example/unrelated")],
        [
            ChapterPreview(title="旧章", url="https://serial.example/1"),
            ChapterPreview(title="坏章", url="file:///private"),
        ],
    ],
)
def test_empty_disjoint_or_invalid_catalog_never_replaces_existing(tracked, chapters):
    before = copy.deepcopy(tracked.source)
    with pytest.raises(ValueError):
        append_new_chapters(tracked.source, chapters)
    assert tracked.source == before


@pytest.mark.asyncio
async def test_manual_check_persists_marker_preserves_files_and_has_short_throttle(tracked):
    db.save_reading_progress(
        ReadingProgressRecord(
            bookId="serial", ownerId="alice", lastChapterIndex=7, lastPageIndex=4, lastCharacterOffset=250
        )
    )
    progress_before = db.load_reading_progress("serial", "alice").model_dump()
    before = {
        path.name: path.read_bytes() for path in tracked.folder.iterdir() if path.name != "manifest.json"
    }
    state = await tracked.service.check("serial", "alice")
    assert state.newChapterCount == 1 and state.latestChapterIndex == 8
    assert state.acknowledgedChapterIndex == 7 and state.checking is False
    assert tracked.runtime.load_manifest(tracked.folder)["chapters"][0] == tracked.source["chapters"][0]
    assert {
        path.name: path.read_bytes() for path in tracked.folder.iterdir() if path.name != "manifest.json"
    } == before
    assert db.get_book("serial", "alice").chapterCount == 2
    assert db.load_reading_progress("serial", "alice").model_dump() == progress_before
    restarted = BookUpdateService(tracked.runtime)
    assert restarted.state("serial", "alice").newChapterCount == 1
    with pytest.raises(repository.CheckThrottled):
        await tracked.service.check("serial", "alice")
    tracked.service.acknowledge("serial", "alice", 8)
    assert tracked.service.state("serial", "alice").newChapterCount == 0
    with pytest.raises(ValueError):
        tracked.service.acknowledge("serial", "alice", 999)


@pytest.mark.asyncio
async def test_checks_singleflight_and_network_does_not_hold_manifest_lock(tracked):
    entered, release = asyncio.Event(), asyncio.Event()
    calls = []
    original = tracked.runtime.preview_from_url

    async def delayed(payload):
        calls.append(payload)
        entered.set()
        await release.wait()
        return await original(payload)

    tracked.runtime.preview_from_url = delayed
    first = asyncio.create_task(tracked.service.check("serial", "alice"))
    await entered.wait()
    second = asyncio.create_task(tracked.service.check("serial", "alice"))
    await asyncio.sleep(0)
    async with tracked.runtime._chapter_manifest_lock_for("serial"):
        current = tracked.runtime.load_manifest(tracked.folder)
        current["chapters"][0]["cache_completed_during_preview"] = True
        save_manifest(tracked.folder, current)
    release.set()
    results = await asyncio.gather(first, second)
    assert len(calls) == 1 and all(state.newChapterCount == 1 for state in results)
    assert (
        tracked.runtime.load_manifest(tracked.folder)["chapters"][0]["cache_completed_during_preview"] is True
    )


@pytest.mark.asyncio
@pytest.mark.parametrize("status", ["running", "pause_requested", "cancel_requested"])
async def test_active_task_before_or_during_preview_blocks_append(tracked, status):
    _task(status)
    with pytest.raises(repository.UpdateConflict, match="正在处理章节"):
        await tracked.service.check("serial", "alice")
    _task("queued")
    original = tracked.runtime.preview_from_url

    async def starts_task(payload):
        _task(status)
        return await original(payload)

    tracked.runtime.preview_from_url = starts_task
    before = (tracked.folder / "manifest.json").read_bytes()
    with pytest.raises(repository.UpdateConflict, match="正在处理章节"):
        await tracked.service.check("serial", "alice")
    assert (tracked.folder / "manifest.json").read_bytes() == before


@pytest.mark.asyncio
async def test_crash_after_append_recovers_marker_counts_and_missing_downloads(tracked, monkeypatch):
    _configure(tracked)
    original = repository.complete_check
    monkeypatch.setattr(
        repository, "complete_check", lambda *args, **kwargs: (_ for _ in ()).throw(OSError("disk"))
    )
    with pytest.raises(ValueError, match="保存失败"):
        await tracked.service.check("serial", "alice")
    assert tracked.service.state("serial", "alice").newChapterCount == 1
    assert tracked.downloads == []
    monkeypatch.setattr(repository, "complete_check", original)
    tracked.clock[0] += timedelta(minutes=6)
    restarted = BookUpdateService(tracked.runtime, now=lambda: tracked.clock[0])
    await restarted.run_due()
    assert tracked.downloads and all(indexes == [8] for _, indexes in tracked.downloads)
    assert db.get_book("serial", "alice").chapterCount == 2
    assert len(tracked.runtime.load_manifest(tracked.folder)["chapters"]) == 2
    tracked.downloads.clear()
    # No new catalog check is due, but a failed/unfinished download is retried.
    await restarted.run_due()
    assert tracked.downloads == [("serial", [8])]


@pytest.mark.asyncio
async def test_owner_isolation_config_revision_and_new_source_during_preview(tracked):
    configured = _configure(tracked)
    with pytest.raises(KeyError):
        await tracked.service.check("serial", "bob")
    assert tracked.service.list_states("bob") == []
    with pytest.raises(repository.UpdateConflict):
        _configure(tracked)
    assert configured.intervalHours == 6 and configured.revision == 1
    original = tracked.runtime.preview_from_url

    async def changed(payload):
        latest = db.get_book("serial", "alice")
        db.save_book(latest.model_copy(update={"title": "同步的新源标题"}))
        return await original(payload)

    tracked.runtime.preview_from_url = changed
    await tracked.service.check("serial", "alice")
    assert db.get_book("serial", "alice").title == "同步的新源标题"


def test_missing_original_source_and_changed_plugin_fail_explicitly(tracked):
    original_source_payload(tracked.book, tracked.source)
    with pytest.raises(ValueError, match="原书源已移除"):
        original_source_payload(tracked.book, {**tracked.source, "source_id": "gone"})
    with pytest.raises(ValueError, match="原站点插件已更换"):
        original_source_payload(tracked.book, {**tracked.source, "site_plugin_id": "other-plugin"})
    legacy = {**tracked.source}
    legacy.pop("site_plugin_id")
    with pytest.raises(ValueError, match="缺少原书源记录"):
        original_source_payload(tracked.book, legacy)
    db.save_site_plugin_enabled("generic-web", False)
    with pytest.raises(ValueError, match="已停用"):
        original_source_payload(tracked.book, tracked.source)


@pytest.mark.asyncio
async def test_maintenance_wait_and_shutdown_prevent_late_publication(tracked):
    gate = tracked.runtime.app.state.maintenance_gate
    before = (tracked.folder / "manifest.json").read_bytes()
    async with gate.exclusive():
        checking = asyncio.create_task(tracked.service.check("serial", "alice"))
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        assert gate.active_count == 0
        await tracked.service.stop()
        with pytest.raises(asyncio.CancelledError):
            await checking
    assert (tracked.folder / "manifest.json").read_bytes() == before


def test_disabling_remains_possible_when_source_manifest_is_missing(tracked):
    _configure(tracked)
    (tracked.folder / "manifest.json").unlink()
    disabled = tracked.service.configure(
        "serial", "alice", BookUpdateSettings(expectedRevision=1, enabled=False)
    )
    assert not disabled.enabled and disabled.nextCheckAt is None


@pytest.mark.asyncio
async def test_existing_books_are_discovered_without_client_opt_in(tracked):
    assert repository.get_tracking("serial", "alice") is None
    await tracked.service.run_due()
    state = tracked.service.state("serial", "alice")
    assert state.automatic and state.supported and state.enabled
    assert state.sourceStatus == "unknown"
    assert state.newChapterCount == 1
    assert state.nextCheckAt == repository.timestamp(tracked.clock[0] + timedelta(hours=24))
    assert tracked.downloads == []  # Automatic checking does not opt into downloads.


@pytest.mark.asyncio
async def test_ongoing_becomes_completed_without_touching_existing_chapters(tracked):
    manifest = {**tracked.source, "source_status": "ongoing"}
    save_manifest(tracked.folder, manifest)
    original = tracked.runtime.preview_from_url

    async def completed(payload):
        return (await original(payload)).model_copy(
            update={
                "sourceStatus": "completed",
                "sourceStatusEvidence": "qidian.finish",
            }
        )

    tracked.runtime.preview_from_url = completed
    await tracked.service.run_due()
    state = tracked.service.state("serial", "alice")
    assert state.sourceStatus == "completed" and state.supported
    assert state.enabled is False and state.nextCheckAt is None
    assert state.sourceStatusCheckedAt == repository.timestamp(tracked.clock[0])
    saved = tracked.runtime.load_manifest(tracked.folder)
    assert saved["source_status"] == "completed"
    assert saved["chapters"][0] == tracked.source["chapters"][0]
    assert saved["chapter_count"] == 2 and state.newChapterCount == 1
    assert (tracked.folder / "original.txt").read_text(encoding="utf-8") == "原文"
    calls = []

    async def unexpected(payload):
        calls.append(payload)
        raise AssertionError("completed books must not be polled")

    tracked.runtime.preview_from_url = unexpected
    tracked.clock[0] += timedelta(days=3)
    await BookUpdateService(tracked.runtime, now=lambda: tracked.clock[0]).run_due()
    assert calls == []


@pytest.mark.asyncio
async def test_new_ongoing_import_uses_last_source_observation_and_keeps_preferences(tracked):
    save_manifest(
        tracked.folder,
        {
            **tracked.source,
            "source_status": "ongoing",
            "source_status_checked_at": repository.timestamp(tracked.clock[0]),
        },
    )
    state = tracked.service.state("serial", "alice")
    assert state.enabled and state.nextCheckAt == repository.timestamp(tracked.clock[0] + timedelta(hours=6))
    # A legacy opt-out no longer overrides source evidence; preferences remain editable.
    changed = tracked.service.configure(
        "serial",
        "alice",
        BookUpdateSettings(expectedRevision=0, enabled=False, intervalHours=12, autoDownload=True),
    )
    assert changed.enabled and changed.intervalHours == 12 and changed.autoDownload
    assert changed.revision == 1


@pytest.mark.asyncio
async def test_unsupported_source_never_enqueues_and_can_become_supported(tracked):
    save_manifest(tracked.folder, {**tracked.source, "site_plugin_id": "missing"})
    called = []

    async def unexpected(payload):
        called.append(payload)
        raise AssertionError("unsupported source must not enqueue")

    tracked.runtime.preview_from_url = unexpected
    await tracked.service.run_due()
    state = tracked.service.state("serial", "alice")
    assert not state.supported and not state.enabled and state.nextCheckAt is None
    assert state.sourceStatus == "unknown" and "插件已更换" in state.unsupportedReason
    assert called == [] and tracked.downloads == []
    preference = tracked.service.configure(
        "serial", "alice", BookUpdateSettings(expectedRevision=0, intervalHours=24, autoDownload=True)
    )
    assert not preference.supported and preference.autoDownload
    save_manifest(tracked.folder, tracked.source)
    assert tracked.service.state("serial", "alice").supported


@pytest.mark.asyncio
async def test_status_changes_are_published_when_catalog_has_no_new_chapters(tracked):
    tracked.incoming[:] = tracked.incoming[:1]
    original = tracked.runtime.preview_from_url

    async def completed(payload):
        return (await original(payload)).model_copy(update={"sourceStatus": "completed"})

    tracked.runtime.preview_from_url = completed
    state = await tracked.service.check("serial", "alice")
    assert state.sourceStatus == "completed" and state.newChapterCount == 0
    assert tracked.runtime.load_manifest(tracked.folder)["source_status"] == "completed"
    assert tracked.runtime.load_manifest(tracked.folder)["chapters"] == tracked.source["chapters"]


@pytest.mark.asyncio
async def test_delete_tombstone_during_preview_prevents_late_publication(tracked):
    original = tracked.runtime.preview_from_url

    async def removed(payload):
        tracked.runtime._is_book_deleted = lambda book_id: True
        return await original(payload)

    tracked.runtime.preview_from_url = removed
    before = (tracked.folder / "manifest.json").read_bytes()
    with pytest.raises(KeyError):
        await tracked.service.check("serial", "alice")
    assert (tracked.folder / "manifest.json").read_bytes() == before


@pytest.mark.asyncio
async def test_periodic_snapshot_reads_wait_for_maintenance(tracked, monkeypatch):
    reads = []
    original = repository.list_tracking

    def listed(*args):
        reads.append(True)
        return original(*args)

    monkeypatch.setattr(repository, "list_tracking", listed)
    async with tracked.runtime.app.state.maintenance_gate.exclusive():
        due = asyncio.create_task(tracked.service.run_due())
        await asyncio.sleep(0)
        assert reads == []
    await due
    assert reads == [True]


@pytest.mark.asyncio
@pytest.mark.parametrize("full_download", [True, False])
async def test_import_manifests_retain_source_identity(tracked, monkeypatch, full_download):
    from app import scraper
    from app.models import AddBookPayload

    @asynccontextmanager
    async def client():
        yield object()

    async def cover(*args, **kwargs):
        return None

    async def chapter(*args, **kwargs):
        return scraper.ChapterFetchResult(text="正文", image_urls=[])

    async def images(*args, **kwargs):
        return []

    monkeypatch.setattr(scraper, "_build_http_client", client)
    monkeypatch.setattr(scraper, "_download_cover_image", cover)
    monkeypatch.setattr(scraper, "_fetch_chapter_data", chapter)
    monkeypatch.setattr(scraper, "_download_chapter_images", images)
    monkeypatch.setattr(scraper, "_load_runtime_settings", lambda: SimpleNamespace(downloadConcurrency=1))
    payload = AddBookPayload(
        sourceUrl=tracked.book.sourceUrl, sourceId="original-source", bookKind="长小说", language="中文"
    )
    preview = PreviewResponse(title="来源测试", chapterCount=2, chapters=tracked.incoming)
    import_book = scraper.download_book if full_download else scraper.create_book_manifest_only
    result = await import_book(payload, preview, tracked.runtime.DATA_DIR / "new-import")
    manifest = scraper.load_manifest(result.local_path)
    assert manifest["source_id"] == "original-source"
    assert manifest["site_plugin_id"] == "generic-web"
    assert len(manifest["chapters"]) == 2


@pytest.mark.asyncio
async def test_updates_api_contract_errors_and_owner_boundary(tracked, monkeypatch):
    from app.api import book_updates as api

    owner = ["alice"]
    monkeypatch.setattr(api, "require_user_access", lambda request: SimpleNamespace(owner_id=owner[0]))
    application = FastAPI()
    application.state.book_updates = tracked.service
    application.include_router(api.router, prefix="/api/v1")
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=application), base_url="http://test"
    ) as client:
        prefix = "/api/v1/books/serial/updates"
        first = await client.get(prefix)
        assert first.status_code == 200 and first.json()["revision"] == 0
        assert first.headers["cache-control"] == "no-store"
        changed = await client.put(
            prefix, json={"expectedRevision": 0, "enabled": True, "intervalHours": 12, "autoDownload": True}
        )
        assert changed.status_code == 200 and changed.json()["intervalHours"] == 12
        conflict = await client.put(prefix, json={"expectedRevision": 0, "enabled": False})
        assert conflict.status_code == 409
        checked = await client.post(prefix + "/check")
        assert checked.status_code == 200 and checked.json()["newChapterCount"] == 1
        assert (await client.post(prefix + "/check")).status_code == 429
        assert (await client.post(prefix + "/ack", json={"throughChapterIndex": 99})).status_code == 400
        acknowledged = await client.post(prefix + "/ack", json={"throughChapterIndex": 8})
        assert acknowledged.status_code == 200 and acknowledged.json()["newChapterCount"] == 0
        assert len((await client.get("/api/v1/book-updates")).json()) == 1
        owner[0] = "bob"
        assert (await client.get(prefix)).status_code == 404
        assert (await client.post(prefix + "/check")).status_code == 404
        assert (await client.get("/api/v1/book-updates")).json() == []
