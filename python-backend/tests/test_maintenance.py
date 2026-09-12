import asyncio

import httpx
import pytest
from fastapi import APIRouter

from app.application import create_application
from app.maintenance import MaintenanceBusy, MaintenanceGate


@pytest.mark.asyncio
async def test_exclusive_waits_for_active_writes_and_rejects_new_requests():
    router = APIRouter()
    entered, finish = asyncio.Event(), asyncio.Event()

    @router.post('/admin/config')
    async def write():
        entered.set()
        await finish.wait()
        return {'saved': True}

    app = create_application(routers=(router,))
    gate = app.state.maintenance_gate
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        request = asyncio.create_task(client.post('/admin/config'))
        await entered.wait()
        exclusive_entered = asyncio.Event()

        async def maintenance():
            async with gate.exclusive(timeout=1):
                exclusive_entered.set()
                assert gate.active_count == 0

        task = asyncio.create_task(maintenance())
        await asyncio.sleep(0)
        assert not exclusive_entered.is_set()
        assert (await client.post('/admin/config')).status_code == 503
        finish.set()
        assert (await request).status_code == 200
        await task
        assert exclusive_entered.is_set()
        assert (await client.post('/admin/config')).status_code == 200


@pytest.mark.asyncio
async def test_timeout_reopens_gate_without_cancelling_active_work():
    gate = MaintenanceGate()
    async with gate.operation():
        with pytest.raises(MaintenanceBusy):
            async with gate.exclusive(timeout=0.01):
                pytest.fail('active write must not be interrupted')
        assert not gate.closed
        assert gate.active_count == 1
    assert gate.active_count == 0


@pytest.mark.asyncio
async def test_child_writer_is_counted_after_parent_finishes():
    gate = MaintenanceGate()
    entered, finish = asyncio.Event(), asyncio.Event()

    async def child():
        async with gate.operation():
            entered.set()
            await finish.wait()

    async with gate.operation():
        task = asyncio.create_task(child())
        await entered.wait()
    assert gate.active_count == 1
    with pytest.raises(MaintenanceBusy):
        async with gate.exclusive(timeout=0.01):
            pytest.fail('child is still writing')
    finish.set()
    await task
    assert gate.active_count == 0


@pytest.mark.asyncio
async def test_background_waits_for_reopen_and_cancellation_releases_gate():
    gate = MaintenanceGate()
    entered = asyncio.Event()

    async def work():
        async with gate.operation():
            entered.set()

    async with gate.exclusive():
        task = asyncio.create_task(work())
        await asyncio.sleep(0)
        assert not entered.is_set()
    await task
    assert entered.is_set()

    async def interrupted():
        async with gate.exclusive():
            entered.clear()
            await asyncio.Future()

    task = asyncio.create_task(interrupted())
    await asyncio.sleep(0)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert not gate.closed


@pytest.mark.asyncio
async def test_cancelled_request_does_not_release_a_running_thread_writer():
    import threading

    router = APIRouter()
    started, finish = threading.Event(), threading.Event()

    @router.post('/write')
    async def write():
        def persist():
            started.set()
            finish.wait(2)
        await asyncio.to_thread(persist)
        return {'saved': True}

    app = create_application(routers=(router,))
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        task = asyncio.create_task(client.post('/write'))
        assert await asyncio.to_thread(started.wait, 1)
        task.cancel()
        await asyncio.sleep(0)
        assert app.state.maintenance_gate.active_count == 1
        with pytest.raises(MaintenanceBusy):
            async with app.state.maintenance_gate.exclusive(timeout=0.01):
                pytest.fail('the thread still owns the write boundary')
        finish.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert app.state.maintenance_gate.active_count == 0
