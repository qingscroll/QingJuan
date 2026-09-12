"""Expired and interrupted inspections must not retain complete archive copies."""

import asyncio
import threading

import pytest
import test_backup_service as base

from app import backup_service
from app.backup_service import BackupError, BackupService

source = base.source


@pytest.mark.asyncio
async def test_expired_inspection_is_removed_but_live_inspection_and_backup_survive(source, monkeypatch):
    service = BackupService(source, "2.2.1", quiesce=base.quiesce)
    artifact = await service.create()
    archive = service.artifact_path(artifact.id)
    expired = await service.inspect(archive, mode="replace")
    monkeypatch.setattr(backup_service.time, "time", lambda: expired.expiresAt - 60)
    current = await service.inspect(archive, mode="replace")
    monkeypatch.setattr(backup_service.time, "time", lambda: expired.expiresAt + 1)

    await service.cleanup_expired_inspections()

    for extension in ("zip", "json"):
        assert not (service.storage / f"restore-{expired.restoreId}.{extension}").exists()
        assert (service.storage / f"restore-{current.restoreId}.{extension}").is_file()
    assert service.artifact_path(artifact.id) == archive
    assert [item.id for item in service.list_artifacts()] == [artifact.id]


@pytest.mark.asyncio
async def test_restart_removes_invalidated_and_orphan_inspections_only(source):
    service = BackupService(source, "2.2.1", quiesce=base.quiesce)
    artifact = await service.create()
    report = await service.inspect(service.artifact_path(artifact.id), mode="replace")
    orphan = service.storage / f"restore-{'a' * 32}.zip"
    orphan.write_bytes(b"interrupted copy")
    unrelated = service.storage / "restore-keep.zip"
    unrelated.write_bytes(b"not an application inspection")
    directory = service.storage / f"restore-{'b' * 32}.zip"
    directory.mkdir()
    (directory / "keep.txt").write_text("not a regular archive")

    restarted = BackupService(source, "2.2.1", quiesce=base.quiesce)
    restarted.recover_interrupted_restore()

    assert not (service.storage / f"restore-{report.restoreId}.zip").exists()
    assert not (service.storage / f"restore-{report.restoreId}.json").exists()
    assert not orphan.exists()
    assert unrelated.read_bytes() == b"not an application inspection"
    assert (directory / "keep.txt").is_file()
    assert restarted.artifact_path(artifact.id).is_file()


@pytest.mark.asyncio
async def test_background_cleanup_runs_without_another_backup_request(source, monkeypatch):
    service = BackupService(source, "2.2.1", quiesce=base.quiesce, cleanup_interval_seconds=0.01)
    artifact = await service.create()
    report = await service.inspect(service.artifact_path(artifact.id), mode="replace")
    retained = service.storage / f"restore-{report.restoreId}.zip"
    monkeypatch.setattr(backup_service.time, "time", lambda: report.expiresAt + 1)

    service.start_cleanup()
    try:
        async with asyncio.timeout(3):
            while retained.exists():
                await asyncio.sleep(0.01)
        assert service.artifact_path(artifact.id).is_file()
    finally:
        await service.stop_cleanup()


@pytest.mark.asyncio
async def test_cleanup_skips_restore_that_crosses_its_expiry(source, monkeypatch):
    service = BackupService(source, "2.2.1", quiesce=base.quiesce)
    artifact = await service.create()
    report = await service.inspect(service.artifact_path(artifact.id), mode="replace")
    entered, release = threading.Event(), threading.Event()
    extract = backup_service.extract_archive

    def hold_extract(*args, **kwargs):
        entered.set()
        assert release.wait(5)
        return extract(*args, **kwargs)

    monkeypatch.setattr(backup_service, "extract_archive", hold_extract)
    restoring = asyncio.create_task(service.restore(report.restoreId, report.confirmationToken))
    try:
        assert await asyncio.to_thread(entered.wait, 5)
        monkeypatch.setattr(backup_service.time, "time", lambda: report.expiresAt + 1)
        await asyncio.wait_for(service.cleanup_expired_inspections(), timeout=1)
        assert (service.storage / f"restore-{report.restoreId}.zip").is_file()
    finally:
        release.set()
        result = await restoring
    assert result.restored


@pytest.mark.asyncio
async def test_cancelled_inspection_drains_copy_then_removes_its_archive(source, monkeypatch):
    service = BackupService(source, "2.2.1", quiesce=base.quiesce)
    artifact = await service.create()
    entered, release = threading.Event(), threading.Event()
    copyfile = backup_service.shutil.copyfile

    def hold_copy(*args, **kwargs):
        result = copyfile(*args, **kwargs)
        entered.set()
        assert release.wait(5)
        return result

    monkeypatch.setattr(backup_service.shutil, "copyfile", hold_copy)
    inspecting = asyncio.create_task(service.inspect(service.artifact_path(artifact.id), mode="replace"))
    try:
        assert await asyncio.to_thread(entered.wait, 5)
        inspecting.cancel()
    finally:
        release.set()
        with pytest.raises(asyncio.CancelledError):
            await inspecting
    assert list(service.storage.glob("restore-*.zip")) == []
    assert list(service.storage.glob("restore-*.json")) == []
    assert service.artifact_path(artifact.id).is_file()


@pytest.mark.asyncio
async def test_wrong_token_preserves_live_inspection_but_expiry_boundary_reclaims_it(source, monkeypatch):
    service = BackupService(source, "2.2.1", quiesce=base.quiesce)
    artifact = await service.create()
    report = await service.inspect(service.artifact_path(artifact.id), mode="replace")
    retained = service.storage / f"restore-{report.restoreId}.zip"

    with pytest.raises(BackupError, match="确认已失效"):
        await service.restore(report.restoreId, "wrong-token")
    assert retained.is_file()
    monkeypatch.setattr(backup_service.time, "time", lambda: report.expiresAt)
    with pytest.raises(BackupError, match="确认已失效"):
        await service.restore(report.restoreId, report.confirmationToken)
    assert not retained.exists()
    assert not (service.storage / f"restore-{report.restoreId}.json").exists()


@pytest.mark.asyncio
async def test_invalid_metadata_and_missing_archive_are_reclaimed(source):
    service = BackupService(source, "2.2.1", quiesce=base.quiesce)
    service._ready()
    identifier = "c" * 32
    broken_zip = service.storage / f"restore-{identifier}.zip"
    broken_zip.write_bytes(b"orphan archive")
    broken_record = service.storage / f"restore-{identifier}.json"
    broken_record.write_text('{"restoreId":"' + identifier + '","expiresAt":9999999999}')
    missing_zip_record = service.storage / f"restore-{'d' * 32}.json"
    missing_zip_record.write_text("{")

    await service.cleanup_expired_inspections()

    assert not broken_zip.exists()
    assert not broken_record.exists()
    assert not missing_zip_record.exists()


@pytest.mark.asyncio
async def test_cleanup_does_not_follow_restore_named_symlink(source, tmp_path):
    service = BackupService(source, "2.2.1", quiesce=base.quiesce)
    service._ready()
    outside = tmp_path / "keep.zip"
    outside.write_bytes(b"outside backup storage")
    link = service.storage / f"restore-{'e' * 32}.zip"
    try:
        link.symlink_to(outside)
    except OSError:
        pytest.skip("symlinks unavailable on this host")

    await service.cleanup_expired_inspections()

    assert link.is_symlink()
    assert outside.read_bytes() == b"outside backup storage"
