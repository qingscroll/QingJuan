"""Exercise snapshots with real application workers instead of a no-op gate."""

import asyncio

import httpx
import pytest

from app import db, main
from app.maintenance import MaintenanceGate
from app.models import BookRecord


@pytest.mark.asyncio
async def test_snapshot_restore_restarts_real_workers_and_reloads_books(monkeypatch, tmp_path):
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "0")
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "LIBRARY_ROOT", tmp_path / "library")
    monkeypatch.setattr(main, "EXPORT_ROOT", tmp_path / "exports")
    monkeypatch.setattr(main, "TASK_QUEUE", asyncio.Queue())
    monkeypatch.setattr(main.app.state, "maintenance_gate", MaintenanceGate())
    service = main._create_backup_service()
    monkeypatch.setattr(main.app.state, "backup_service", service)
    await main._run_startup(main.app)
    try:
        book_dir = tmp_path / "library" / "user-admin" / "book-integration"
        book_dir.mkdir(parents=True)
        chapter = book_dir / "chapter.txt"
        chapter.write_text("快照正文", encoding="utf-8")
        book = BookRecord(
            id="book-integration",
            title="快照书",
            sourceUrl="https://example.test/book",
            bookKind="长小说",
            language="中文",
            status="已下载",
            chapterCount=1,
            translated=False,
            localPath="library/user-admin/book-integration",
        )
        db.save_book(book)
        main.save_manifest(
            book_dir,
            {
                "title": "快照书",
                "chapters": [
                    {"index": 1, "title": "第一章", "file_name": "chapter.txt", "downloaded": True},
                ],
            },
        )
        worker = main.app.state.queue_worker
        cleanup_worker = service._cleanup_task
        artifact = await service.create()
        assert worker.done()
        assert cleanup_worker.done()
        assert service._cleanup_task is not cleanup_worker
        assert main.app.state.queue_worker is not worker
        assert not main.app.state.maintenance_gate.closed
        assert main.app.state.task_queue is main.TASK_QUEUE
        chapter.write_text("备份后的正文", encoding="utf-8")
        db.save_book(book.model_copy(update={"title": "备份后的标题"}))
        inspection = await service.inspect(service.artifact_path(artifact.id), mode="replace")
        await service.restore(inspection.restoreId, inspection.confirmationToken)
        assert chapter.read_text("utf-8") == "快照正文"
        assert db.get_book(book.id).title == "快照书"
        assert not main.app.state.queue_worker.done()
        assert not service._cleanup_task.done()
        assert not main.app.state.maintenance_gate.closed
    finally:
        await main._run_shutdown(main.app)
    assert service._cleanup_task is None


@pytest.mark.asyncio
async def test_backup_auth_does_not_write_device_data_during_maintenance(monkeypatch):
    from app import security

    def must_not_write(_request):
        pytest.fail("backup authentication must never register a client device")

    monkeypatch.setattr(security, "register_request_device", must_not_write)
    monkeypatch.setenv("QINGJUAN_TRUST_LOCAL_ADMIN", "0")
    monkeypatch.setattr(main.app.state, "maintenance_gate", MaintenanceGate())
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=main.app), base_url="http://test"
    ) as client:
        response = await client.get("/api/v1/backups", headers={"Authorization": "Bearer untrusted"})
        assert response.status_code in {401, 403}
