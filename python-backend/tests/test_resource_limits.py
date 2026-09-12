from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime

import pytest

from app import db
from app.resource_limits import (
    ResourceLimitError,
    ResourceLimitPatch,
    get_limit,
    get_usage,
    reserve_model_request,
    update_limit,
)


@pytest.fixture
def limits_db(monkeypatch, tmp_path):
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "0")
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    monkeypatch.setattr(db, "_SITE_PLUGIN_STATE_CACHE", None)
    db.init_db()
    return "user-admin"


def test_limit_changes_are_cas_and_null_restores_unlimited(limits_db):
    original = get_limit(limits_db)
    assert original.storageBytes is None and original.revision == 0
    changed = update_limit(limits_db, ResourceLimitPatch(
        expectedRevision=0, storageBytes=1024, dailyModelRequests=0))
    assert changed.storageBytes == 1024 and changed.revision == 1
    with pytest.raises(ResourceLimitError, match="已变化"):
        update_limit(limits_db, ResourceLimitPatch(expectedRevision=0))
    restored = update_limit(limits_db, ResourceLimitPatch(expectedRevision=1))
    assert restored.storageBytes is None and restored.dailyModelRequests is None


def test_concurrent_reservations_never_exceed_limit(limits_db):
    update_limit(limits_db, ResourceLimitPatch(expectedRevision=0, dailyModelRequests=3))
    def reserve(_):
        try:
            reserve_model_request(limits_db)
            return True
        except ResourceLimitError:
            return False
    with ThreadPoolExecutor(max_workers=8) as pool:
        accepted = list(pool.map(reserve, range(16)))
    assert sum(accepted) == 3
    assert get_usage(limits_db).modelRequests == 3


def test_usage_survives_restart_and_resets_at_utc_midnight(limits_db):
    update_limit(limits_db, ResourceLimitPatch(expectedRevision=0, dailyModelRequests=1))
    before = datetime(2026, 9, 11, 23, 59, tzinfo=UTC)
    after = datetime(2026, 9, 12, 0, 0, tzinfo=UTC)
    reserve_model_request(limits_db, instant=before)
    db.init_db()
    with pytest.raises(ResourceLimitError):
        reserve_model_request(limits_db, instant=before)
    reserve_model_request(limits_db, instant=after)
    assert get_usage(limits_db, instant=after).modelRequests == 1
    assert get_usage(limits_db, instant=after).resetsAt == "2026-09-13T00:00:00Z"


def test_unknown_users_cannot_create_quota_or_usage(limits_db):
    for operation in (
        lambda: get_limit("missing"),
        lambda: update_limit("missing", ResourceLimitPatch(expectedRevision=0)),
        lambda: reserve_model_request("missing"),
    ):
        with pytest.raises(ResourceLimitError) as caught:
            operation()
        assert caught.value.status_code == 404
