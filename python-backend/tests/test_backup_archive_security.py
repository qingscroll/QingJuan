from __future__ import annotations

import hashlib
import json
import stat
import zipfile
from dataclasses import replace

import pytest
import test_backup_service
from test_backup_service import quiesce

from app.backup_format import BackupError, BackupLimits, extract_archive, open_database
from app.backup_service import BackupService

source = test_backup_service.source


@pytest.fixture
async def archive(source):
    service = BackupService(source, "2.2.1", quiesce=quiesce)
    record = await service.create()
    return service.artifact_path(record.id)


@pytest.mark.parametrize(
    "name",
    [
        "../escape",
        "/absolute",
        "C:/drive",
        "library\\backslash",
        "library/nul.txt",
        "library/name.",
        "qingjuan.db",
        "LIBRARY/user-admin/book-one/chapter.txt",
    ],
)
def test_unsafe_and_duplicate_zip_members_are_rejected(archive, tmp_path, name):
    with zipfile.ZipFile(archive, "a") as output:
        output.writestr(name, "malicious")
    with pytest.raises(BackupError):
        extract_archive(archive, tmp_path / "extract", app_version="2.2.1", limits=BackupLimits())
    assert not (tmp_path / "escape").exists()


def test_symlink_member_is_rejected(archive, tmp_path):
    entry = zipfile.ZipInfo("library/linked")
    entry.create_system = 3
    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
    with zipfile.ZipFile(archive, "a") as output:
        output.writestr(entry, "../../outside")
    with pytest.raises(BackupError, match="文件类型"):
        extract_archive(archive, tmp_path / "extract", app_version="2.2.1", limits=BackupLimits())


@pytest.mark.parametrize(
    "limits",
    [
        replace(BackupLimits(), archive_bytes=10),
        replace(BackupLimits(), expanded_bytes=10),
        replace(BackupLimits(), entry_bytes=10),
        replace(BackupLimits(), members=1),
        replace(BackupLimits(), compression_ratio=1),
    ],
)
def test_archive_limits_are_enforced(archive, tmp_path, limits):
    with pytest.raises(BackupError) as error:
        extract_archive(archive, tmp_path / "extract", app_version="2.2.1", limits=limits)
    assert error.value.status_code == 413


def rewrite_archive(source_path, target_path, change):
    with zipfile.ZipFile(source_path) as source_zip:
        payloads = {name: source_zip.read(name) for name in source_zip.namelist()}
    change(payloads)
    with zipfile.ZipFile(target_path, "w", zipfile.ZIP_DEFLATED) as target_zip:
        for name, data in payloads.items():
            target_zip.writestr(name, data)


@pytest.mark.asyncio
async def test_hash_mismatch_and_modified_staged_upload_cannot_restore(source, archive, tmp_path):
    invalid = tmp_path / "tampered.zip"

    def change(payloads):
        payloads["library/user-admin/book-one/chapter.txt"] = "被替换正文".encode()

    rewrite_archive(archive, invalid, change)
    service = BackupService(source, "2.2.1", quiesce=quiesce)
    before = (source / "qingjuan.db").read_bytes()
    with pytest.raises(BackupError, match="校验"):
        await service.inspect(invalid, mode="replace")
    report = await service.inspect(archive, mode="replace")
    staged = service.storage / f"restore-{report.restoreId}.zip"
    staged.write_bytes(b"changed")
    with pytest.raises(BackupError, match="已改变"):
        await service.restore(report.restoreId, report.confirmationToken)
    assert (source / "qingjuan.db").read_bytes() == before


@pytest.mark.asyncio
async def test_invalid_ownership_and_executable_sqlite_schema_are_rejected_before_apply(
    source, archive, tmp_path
):
    for index, statement in enumerate(
        [
            "UPDATE reading_progress SET owner_id='missing-user'",
            "CREATE TRIGGER injected AFTER UPDATE ON books BEGIN DELETE FROM users; END",
        ]
    ):
        staged = tmp_path / f"database-{index}"
        extract_archive(archive, staged, app_version="2.2.1", limits=BackupLimits())
        with open_database(staged / "qingjuan.db") as conn:
            conn.execute(statement)
        content = (staged / "qingjuan.db").read_bytes()
        invalid = tmp_path / f"invalid-{index}.zip"

        def change(payloads, content=content):
            manifest = json.loads(payloads["manifest.json"])
            manifest["files"]["qingjuan.db"] = {
                "size": len(content),
                "sha256": hashlib.sha256(content).hexdigest(),
            }
            payloads["qingjuan.db"] = content
            payloads["manifest.json"] = json.dumps(manifest).encode()

        rewrite_archive(archive, invalid, change)
        service = BackupService(source, "2.2.1", quiesce=quiesce)
        before = (source / "qingjuan.db").read_bytes()
        with pytest.raises(BackupError):
            await service.inspect(invalid, mode="replace")
        assert (source / "qingjuan.db").read_bytes() == before


@pytest.mark.asyncio
async def test_snapshot_includes_plugin_package_settings_and_rejects_corrupt_blob(source):
    from test_plugin_packages import make_package

    from app.plugin_system.packages import inspect_package

    package = make_package(id="external")
    manifest, _ = inspect_package(package)
    with open_database(source / "qingjuan.db") as conn:
        conn.execute(
            "INSERT INTO site_plugin_packages VALUES ('external', ?, ?, ?, '', '')",
            (manifest.model_dump_json(), package, hashlib.sha256(package).hexdigest()),
        )
        conn.execute("INSERT INTO site_plugin_settings VALUES ('external', 0, '')")
    service = BackupService(source, "2.2.1", quiesce=quiesce)
    artifact = await service.create()
    report = await service.inspect(service.artifact_path(artifact.id), mode="replace")
    assert report.backupCounts["site_plugin_packages"] == 1
    await service.restore(report.restoreId, report.confirmationToken)
    with open_database(source / "qingjuan.db") as conn:
        assert (
            conn.execute("SELECT package FROM site_plugin_packages WHERE plugin_id='external'").fetchone()[0]
            == package
        )
        assert (
            conn.execute("SELECT enabled FROM site_plugin_settings WHERE plugin_id='external'").fetchone()[0]
            == 0
        )
        conn.execute("UPDATE site_plugin_packages SET sha256='bad-digest'")
    with pytest.raises(BackupError, match="插件包"):
        await service.create()
