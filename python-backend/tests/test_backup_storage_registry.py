import pytest
import test_backup_service as base

from app import db
from app.backup_format import BackupError, open_database, validate_database
from app.backup_service import BackupService

source = base.source


@pytest.mark.asyncio
async def test_migration_preserves_and_remaps_interrupted_import_storage_registry(
    source, tmp_path, monkeypatch
):
    orphan = source / "library" / "interrupted"
    orphan.mkdir()
    (orphan / "download.part").write_bytes(b"unfinished user file")
    with db.get_connection() as conn:
        conn.execute("INSERT INTO storage_provisional_roots VALUES ('library/interrupted','user-admin','')")
    original = BackupService(source, "2.2.1", quiesce=base.quiesce)
    artifact = await original.create()
    target = tmp_path / "target"
    base.initialize_target(target, monkeypatch)
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "1")
    service = BackupService(target, "2.2.1", quiesce=base.quiesce)
    preview = await service.inspect(
        original.artifact_path(artifact.id), mode="migrate_local", migration_owner_id="target-user"
    )
    await service.restore(preview.restoreId, preview.confirmationToken)
    with open_database(target / "qingjuan.db") as conn:
        assert conn.execute("SELECT storage_key,owner_id FROM storage_provisional_roots").fetchall() == [
            ("library/interrupted", "target-user")
        ]
    assert (target / "library/interrupted/download.part").read_bytes() == b"unfinished user file"


@pytest.mark.parametrize("key", ["../outside", "library", "/absolute", "exports/private"])
def test_backup_rejects_unsafe_provisional_storage_keys(source, key):
    with db.get_connection() as conn:
        conn.execute("INSERT INTO storage_provisional_roots VALUES (?,'user-admin','')", (key,))
    with pytest.raises(BackupError):
        validate_database(source)
