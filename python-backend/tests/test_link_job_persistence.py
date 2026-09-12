from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

import pytest

from app import db
from app.models import AddBookPayload


@pytest.fixture
def persistent_jobs(monkeypatch, tmp_path):
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    db.init_db()
    from app.link_job_repository import PersistentLinkJobStore
    return PersistentLinkJobStore


def payload(url="https://example.com/book/1"):
    return AddBookPayload(sourceUrl=url, bookKind="长小说", language="中文")


def test_restart_recovers_job_logs_payload_and_idempotency(persistent_jobs):
    first = persistent_jobs()
    job, created = first.create_or_get("import", payload(), "alice", "request-1")
    assert created
    first.start(job.id, "正在下载")
    first.append_log(job.id, "info", "第一章已保存", progress=35)
    restarted = persistent_jobs()
    pending = restarted.recover()
    assert [item.id for item in pending] == [job.id]
    assert pending[0].status == "queued"
    assert any(log.message == "第一章已保存" for log in pending[0].logs)
    assert restarted.payload_for(job.id) == payload()
    repeated, created = restarted.create_or_get("import", payload(), "alice", "request-1")
    assert repeated.id == job.id and not created
    with pytest.raises(ValueError):
        restarted.create_or_get("import", payload("https://example.com/book/2"), "alice", "request-1")


def test_persistent_creation_is_atomic_across_store_instances(persistent_jobs):
    def create(_):
        return persistent_jobs().create_or_get("import", payload(), "alice", "same")
    with ThreadPoolExecutor(max_workers=6) as executor:
        results = list(executor.map(create, range(12)))
    assert sum(created for _, created in results) == 1
    assert len({job.id for job, _ in results}) == 1


def test_history_retry_and_owner_isolation(persistent_jobs):
    store = persistent_jobs()
    alice, _ = store.create_or_get("import", payload(), "alice", "same")
    bob, _ = store.create_or_get("import", payload(), "bob", "same")
    store.fail(alice.id, "网络中断")
    assert [job.id for job in store.list("alice")] == [alice.id]
    for method in (store.get, store.retry):
        with pytest.raises(KeyError):
            method(alice.id, "bob")
    retried, enqueue = persistent_jobs().retry(alice.id, "alice")
    assert enqueue and retried.id == alice.id and retried.error is None
    assert not store.retry(alice.id, "alice")[1]
    assert len(store.list("alice")) == 1
    assert store.get(bob.id, "bob").status == "queued"


def test_history_pages_and_completed_jobs_are_not_restarted(persistent_jobs):
    store = persistent_jobs()
    jobs = [store.create("preview", payload(), "alice") for _ in range(3)]
    store.complete(jobs[0].id, "解析完成")
    assert jobs[0].id not in {job.id for job in persistent_jobs().recover()}
    page1 = store.list("alice", limit=2)
    page2 = store.list("alice", limit=2, offset=2)
    assert len(page1) == 2 and len(page2) == 1
    assert {job.id for job in page1 + page2} == {job.id for job in jobs}
