import asyncio

import pytest

from app.fair_task_queue import FairTaskQueue


def test_busy_user_cannot_fill_every_position_ahead_of_other_users():
    queue = FairTaskQueue(lambda value: value.split("-")[0])
    for task in ["a-1", "a-2", "a-3", "b-1", "b-2", "c-1", "c-2"]:
        queue.put_nowait(task)
    assert [queue.get_nowait() for _ in range(7)] == [
        "a-1", "b-1", "c-1", "a-2", "b-2", "c-2", "a-3",
    ]
    assert queue.empty() and queue.qsize() == 0


@pytest.mark.asyncio
async def test_late_user_gets_a_turn_and_join_tracks_finished_work():
    queue = FairTaskQueue(lambda value: value.split("-")[0])
    await queue.put("a-1")
    assert await queue.get() == "a-1"
    await queue.put("a-2")
    await queue.put("b-1")
    assert await queue.get() == "b-1"
    assert await queue.get() == "a-2"
    joined = asyncio.create_task(queue.join())
    await asyncio.sleep(0)
    assert not joined.done()
    for _ in range(3):
        queue.task_done()
    await asyncio.wait_for(joined, 1)


@pytest.mark.asyncio
async def test_cancelled_waiter_does_not_lose_next_item_and_capacity_is_task_count():
    queue = FairTaskQueue(lambda _: "same-user", maxsize=2)
    waiting = asyncio.create_task(queue.get())
    await asyncio.sleep(0)
    waiting.cancel()
    with pytest.raises(asyncio.CancelledError):
        await waiting
    queue.put_nowait("first")
    queue.put_nowait("second")
    with pytest.raises(asyncio.QueueFull):
        queue.put_nowait("third")
    assert await queue.get() == "first"
    assert await queue.get() == "second"
