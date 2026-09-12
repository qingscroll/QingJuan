from __future__ import annotations

import hashlib
import json
import zipfile
from contextlib import asynccontextmanager

import pytest

from app import db
from app.backup_format import open_database
from app.backup_service import BackupError, BackupService
from app.models import BookRecord


@pytest.fixture
def source(tmp_path, monkeypatch):
    root = tmp_path / "source"
    root.mkdir()
    monkeypatch.setattr(db, "DATA_DIR", root)
    monkeypatch.setattr(db, "DB_PATH", root / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "0")
    db.init_db()
    directory = root / "library" / "user-admin" / "book-one"
    directory.mkdir(parents=True)
    (directory / "chapter.txt").write_text("保留正文和译文", encoding="utf-8")
    db.save_book(
        BookRecord(
            id="book-one",
            title="备份书",
            sourceUrl="https://example.test/book",
            bookKind="长小说",
            language="中文",
            status="已下载",
            chapterCount=1,
            translated=False,
            localPath="library/user-admin/book-one",
            updatedAt="2026-09-11T00:00:00Z",
            synopsis="",
        )
    )
    with db.get_connection() as conn:
        conn.execute("INSERT INTO settings VALUES (1, ?)", (json.dumps({"privateKey": "sensitive-test"}),))
        conn.execute(
            "INSERT INTO reading_progress (book_id, last_chapter_index) VALUES (?, 0)", ("book-one",)
        )
    return root


@asynccontextmanager
async def quiesce(_operation):
    async def reload():
        return None

    yield reload


@pytest.mark.asyncio
async def test_complete_snapshot_roundtrip_and_preview_are_non_destructive(source, tmp_path):
    service = BackupService(source, "2.2.1", quiesce=quiesce)
    artifact = await service.create()
    path = service.artifact_path(artifact.id)
    with zipfile.ZipFile(path) as archive:
        assert {
            "manifest.json",
            "qingjuan.db",
            "security.json",
            "library/user-admin/book-one/chapter.txt",
        } <= set(archive.namelist())
        manifest = json.loads(archive.read("manifest.json"))
        assert manifest["containsSensitiveData"] is True
        assert "sensitive-test" not in archive.read("manifest.json").decode()
    target = tmp_path / "target"
    target.mkdir()
    target_service = BackupService(target, "2.2.1", quiesce=quiesce)
    report = await target_service.inspect(path, mode="replace")
    assert report.backupCounts["books"] == 1
    assert not (target / "qingjuan.db").exists()
    result = await target_service.restore(report.restoreId, report.confirmationToken)
    assert result.restoredCounts["books"] == 1
    with open_database(target / "qingjuan.db") as conn:
        assert "sensitive-test" in conn.execute("SELECT payload FROM settings").fetchone()[0]
        assert conn.execute("SELECT book_id FROM reading_progress").fetchone()[0] == "book-one"
        assert conn.execute("SELECT local_path FROM books").fetchone()[0] == "library/user-admin/book-one"
    assert (target / "library/user-admin/book-one/chapter.txt").read_text("utf-8") == "保留正文和译文"


@pytest.mark.asyncio
async def test_invalid_archive_and_modified_inspection_preserve_live_data(source):
    service = BackupService(source, "2.2.1", quiesce=quiesce)
    artifact = await service.create()
    path = service.artifact_path(artifact.id)
    before = (source / "qingjuan.db").read_bytes()
    report = await service.inspect(path, mode="replace")
    with pytest.raises(BackupError):
        await service.restore(report.restoreId, "incorrect-token")
    assert (source / "qingjuan.db").read_bytes() == before
    with zipfile.ZipFile(path, "a") as archive:
        archive.writestr("../escape", "evil")
    with pytest.raises(BackupError):
        await service.inspect(path, mode="replace")
    assert (source / "qingjuan.db").read_bytes() == before


@pytest.mark.asyncio
async def test_reload_failure_restores_old_database_and_library(source):
    regular = BackupService(source, "2.2.1", quiesce=quiesce)
    artifact = await regular.create()
    directory = source / "library/user-admin/book-one/chapter.txt"
    directory.write_text("恢复前原文", encoding="utf-8")
    before = (source / "qingjuan.db").read_bytes()
    calls = []

    @asynccontextmanager
    async def fail_first_reload(operation):
        async def reload():
            calls.append(operation)
            if len(calls) == 1:
                raise RuntimeError("sensitive-error")

        yield reload

    service = BackupService(source, "2.2.1", quiesce=fail_first_reload)
    report = await service.inspect(regular.artifact_path(artifact.id), mode="replace")
    with pytest.raises(BackupError, match="原数据"):
        await service.restore(report.restoreId, report.confirmationToken)
    assert directory.read_text("utf-8") == "恢复前原文"
    assert (source / "qingjuan.db").read_bytes() == before
    assert len(calls) == 2


@pytest.mark.asyncio
async def test_backup_requires_valid_library_keys(source):
    with open_database(source / "qingjuan.db") as conn:
        conn.execute("UPDATE books SET local_path = '../outside'")
    service = BackupService(source, "2.2.1", quiesce=quiesce)
    with pytest.raises(BackupError, match="路径"):
        await service.create()


@pytest.mark.asyncio
async def test_newer_version_rejected_and_sqlite_corruption_detected(source, tmp_path):
    service = BackupService(source, "9.0.0", quiesce=quiesce)
    artifact = await service.create()
    path = service.artifact_path(artifact.id)
    target = BackupService(tmp_path / "target", "2.2.1", quiesce=quiesce)
    with pytest.raises(BackupError, match="版本"):
        await target.inspect(path, mode="replace")
    invalid = tmp_path / "invalid.zip"
    with zipfile.ZipFile(path) as archive, zipfile.ZipFile(invalid, "w") as output:
        manifest = json.loads(archive.read("manifest.json"))
        manifest["appVersion"] = "2.2.1"
        data = b"invalid sqlite"
        manifest["files"]["qingjuan.db"] = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        for name in archive.namelist():
            output.writestr(
                name,
                json.dumps(manifest)
                if name == "manifest.json"
                else data
                if name == "qingjuan.db"
                else archive.read(name),
            )
    with pytest.raises(BackupError, match="数据库"):
        await target.inspect(invalid, mode="replace")


def initialize_target(root, monkeypatch):
    root.mkdir()
    with monkeypatch.context() as target_patch:
        target_patch.setattr(db, "DATA_DIR", root)
        target_patch.setattr(db, "DB_PATH", root / "qingjuan.db")
        db.init_db()
    with open_database(root / "qingjuan.db") as conn:
        columns = [row[1] for row in conn.execute("PRAGMA table_info(users)")]
        values = list(conn.execute("SELECT * FROM users WHERE id='user-admin'").fetchone())
        for name, value in {"id": "target-user", "username": "target", "username_key": "target"}.items():
            values[columns.index(name)] = value
        conn.execute(f"INSERT INTO users VALUES ({','.join('?' for _ in values)})", values)
        conn.execute("UPDATE registration_settings SET smtp_host='target-mail.example.test'")


@pytest.mark.asyncio
async def test_explicit_local_migration_preserves_target_accounts_and_registration(
    source, tmp_path, monkeypatch
):
    from app.link_job_repository import PersistentLinkJobStore
    from app.models import AddBookPayload
    from app.reading_progress_repository import ensure_reading_progress_schema

    with open_database(source / "qingjuan.db") as conn:
        ensure_reading_progress_schema(conn)
        conn.execute("UPDATE reading_progress SET revision=3, versioned=1")
        conn.execute(
            "INSERT INTO reading_progress_receipts VALUES ('user-admin', 'book-one', 'operation', 'digest', '{}', 3)"
        )

    store = PersistentLinkJobStore()
    job = store.create(
        "import", AddBookPayload(sourceUrl="https://example.test/book", bookKind="长小说", language="中文")
    )
    store.complete(job.id, "已导入", book=db.get_book("book-one"))
    origin = BackupService(source, "2.2.1", quiesce=quiesce)
    artifact = await origin.create()
    root = tmp_path / "target"
    initialize_target(root, monkeypatch)
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "1")
    target = BackupService(root, "2.2.1", quiesce=quiesce)
    with pytest.raises(BackupError, match="显式迁移"):
        await target.inspect(origin.artifact_path(artifact.id), mode="replace")
    report = await target.inspect(
        origin.artifact_path(artifact.id), mode="migrate_local", migration_owner_id="target-user"
    )
    await target.restore(report.restoreId, report.confirmationToken)
    with open_database(root / "qingjuan.db") as conn:
        assert conn.execute("SELECT count(*) FROM users").fetchone()[0] == 2
        assert (
            conn.execute("SELECT smtp_host FROM registration_settings").fetchone()[0]
            == "target-mail.example.test"
        )
        assert conn.execute("SELECT owner_id, local_path FROM books").fetchone() == (
            "target-user",
            "library/user-admin/book-one",
        )
        assert conn.execute("SELECT owner_id FROM reading_progress").fetchone()[0] == "target-user"
        assert conn.execute("SELECT owner_id, revision FROM reading_progress_receipts").fetchone() == (
            "target-user",
            3,
        )
        assert conn.execute("SELECT revision, versioned FROM reading_progress").fetchone() == (3, 1)
        owner, raw = conn.execute("SELECT owner_id, record FROM link_jobs").fetchone()
        assert owner == "target-user"
        assert json.loads(raw)["book"]["ownerId"] == "target-user"
    with pytest.raises(BackupError, match="必须为空"):
        await target.inspect(
            origin.artifact_path(artifact.id), mode="migrate_local", migration_owner_id="target-user"
        )


@pytest.mark.asyncio
async def test_two_factor_material_is_complete_and_reencrypted_for_target(source, tmp_path, monkeypatch):
    from app.two_factor import decrypt_totp_secret, encrypt_totp_secret

    secret = "JBSWY3DPEHPK3PXP"
    source_key, target_key = "11" * 32, "22" * 32
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "1")
    monkeypatch.setenv("QINGJUAN_2FA_ENCRYPTION_KEY", source_key)
    with open_database(source / "qingjuan.db") as conn:
        conn.execute("UPDATE users SET totp_secret_encrypted=?", (encrypt_totp_secret(secret),))
    service = BackupService(source, "2.2.1", quiesce=quiesce)
    artifact = await service.create()
    monkeypatch.delenv("QINGJUAN_2FA_ENCRYPTION_KEY")
    with pytest.raises(BackupError, match="缺少独立"):
        await service.create()
    target = BackupService(tmp_path / "target", "2.2.1", quiesce=quiesce)
    with pytest.raises(BackupError, match="目标服务器缺少"):
        await target.inspect(service.artifact_path(artifact.id), mode="replace")
    monkeypatch.setenv("QINGJUAN_2FA_ENCRYPTION_KEY", target_key)
    report = await target.inspect(service.artifact_path(artifact.id), mode="replace")
    assert source_key not in report.model_dump_json()
    await target.restore(report.restoreId, report.confirmationToken)
    with open_database(target.data_dir / "qingjuan.db") as conn:
        ciphertext = conn.execute("SELECT totp_secret_encrypted FROM users").fetchone()[0]
    assert decrypt_totp_secret(ciphertext) == secret
    with pytest.raises(ValueError):
        decrypt_totp_secret(ciphertext, session_secret=source_key)


@pytest.mark.asyncio
async def test_process_interruption_rolls_back_both_database_and_files_at_startup(source):
    from app.backup_format import BackupLimits, extract_archive
    from app.backup_service import _RestoreSwap

    service = BackupService(source, "2.2.1", quiesce=quiesce)
    artifact = await service.create()
    file = source / "library/user-admin/book-one/chapter.txt"
    file.write_text("进程中断前的数据", encoding="utf-8")
    before = (source / "qingjuan.db").read_bytes()
    stage = service.storage / "apply-interrupted"
    extract_archive(service.artifact_path(artifact.id), stage, app_version="2.2.1", limits=BackupLimits())
    swap = _RestoreSwap(service, stage)
    swap.install()
    assert file.read_text("utf-8") == "保留正文和译文"
    restarted = BackupService(source, "2.2.1", quiesce=quiesce)
    restarted.recover_interrupted_restore()
    assert file.read_text("utf-8") == "进程中断前的数据"
    assert (source / "qingjuan.db").read_bytes() == before
    restarted.recover_interrupted_restore()


@pytest.mark.asyncio
async def test_cancelled_backup_drains_thread_before_reloading_or_releasing_gate(source, monkeypatch):
    import asyncio
    import threading

    started, finish = threading.Event(), threading.Event()
    events = []

    @asynccontextmanager
    async def tracked_quiesce(operation):
        async def reload():
            events.append("reloaded")

        try:
            yield reload
        finally:
            events.append("released")

    service = BackupService(source, "2.2.1", quiesce=tracked_quiesce)

    def long_create():
        started.set()
        assert finish.wait(timeout=5)
        events.append("thread-finished")

    monkeypatch.setattr(service, "_create", long_create)
    task = asyncio.create_task(service.create())
    await asyncio.to_thread(started.wait, 5)
    task.cancel()
    await asyncio.sleep(0.01)
    assert events == []
    assert not task.done()
    finish.set()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert events == ["thread-finished", "reloaded", "released"]


@pytest.mark.asyncio
async def test_empty_pending_book_directories_survive_snapshot(source, tmp_path):
    (source / "library/user-admin/book-one/chapter.txt").unlink()
    service = BackupService(source, "2.2.1", quiesce=quiesce)
    artifact = await service.create()
    target = BackupService(tmp_path / "target", "2.2.1", quiesce=quiesce)
    report = await target.inspect(service.artifact_path(artifact.id), mode="replace")
    await target.restore(report.restoreId, report.confirmationToken)
    assert (target.data_dir / "library/user-admin/book-one").is_dir()


@pytest.mark.asyncio
async def test_migration_preserves_new_account_tables_and_never_imports_source_challenges(
    source, tmp_path, monkeypatch
):
    from app.account_maintenance_repository import ensure_account_maintenance_schema

    with open_database(source / "qingjuan.db") as conn:
        ensure_account_maintenance_schema(conn)
        conn.execute("INSERT INTO account_attempt_windows VALUES ('source-window', 0, 9999999999, 1)")
    origin = BackupService(source, "2.2.1", quiesce=quiesce)
    artifact = await origin.create()
    root = tmp_path / "target"
    initialize_target(root, monkeypatch)
    with open_database(root / "qingjuan.db") as conn:
        ensure_account_maintenance_schema(conn)
        conn.execute("INSERT INTO account_verified_emails VALUES ('target-user', 'target@example.test', '')")
        conn.execute("INSERT INTO account_attempt_windows VALUES ('target-window', 0, 9999999999, 1)")
        conn.execute(
            "INSERT INTO user_sessions (token_hash, user_id, created_at, expires_at) VALUES ('target-session', 'target-user', '', '2099')"
        )
        conn.execute(
            "INSERT INTO account_session_metadata VALUES ('target-session', 'public-id', 'windows', '')"
        )
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "1")
    target = BackupService(root, "2.2.1", quiesce=quiesce)
    report = await target.inspect(
        origin.artifact_path(artifact.id), mode="migrate_local", migration_owner_id="target-user"
    )
    await target.restore(report.restoreId, report.confirmationToken)
    with open_database(root / "qingjuan.db") as conn:
        assert conn.execute("SELECT key_hash FROM account_attempt_windows").fetchall() == [("target-window",)]
        assert conn.execute("SELECT user_id FROM account_verified_emails").fetchall() == [("target-user",)]
        assert conn.execute("SELECT public_id FROM account_session_metadata").fetchall() == [("public-id",)]
        assert conn.execute("PRAGMA foreign_key_check").fetchall() == []


@pytest.mark.asyncio
async def test_partial_file_exchange_failure_rolls_back_originals(source, monkeypatch):
    import app.backup_restore_state as state

    service = BackupService(source, "2.2.1", quiesce=quiesce)
    artifact = await service.create()
    report = await service.inspect(service.artifact_path(artifact.id), mode="replace")
    before = (source / "qingjuan.db").read_bytes()
    file = source / "library/user-admin/book-one/chapter.txt"
    file.write_text("原有书库", encoding="utf-8")
    original_replace = state.os.replace

    def fail_install_library(src, dst):
        if src.name == "library" and src.parent.name.startswith("apply-"):
            raise OSError("disk-failure-private-path")
        return original_replace(src, dst)

    monkeypatch.setattr(state.os, "replace", fail_install_library)
    with pytest.raises(BackupError, match="原数据"):
        await service.restore(report.restoreId, report.confirmationToken)
    assert (source / "qingjuan.db").read_bytes() == before
    assert file.read_text("utf-8") == "原有书库"


def test_startup_recovery_keeps_new_data_directory_empty_for_legacy_migration(tmp_path):
    root = tmp_path / "new-data-directory"
    service = BackupService(root, "2.2.1", quiesce=quiesce)
    service.recover_interrupted_restore()
    assert not root.exists()
