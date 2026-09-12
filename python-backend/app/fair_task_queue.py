"""Round-robin users while preserving each user's task order."""

import asyncio
from collections import deque
from collections.abc import Callable


class FairTaskQueue(asyncio.Queue[str]):
    def __init__(self, owner_for_task: Callable[[str], str], maxsize: int = 0):
        self._owner_for_task = owner_for_task
        super().__init__(maxsize)

    def _init(self, maxsize: int) -> None:
        self._by_owner: dict[str, deque[str]] = {}
        self._owners: deque[str] = deque()
        self._count = 0
        self._last_owner: str | None = None

    def qsize(self) -> int:
        return self._count

    def empty(self) -> bool:
        return self._count == 0

    def _put(self, item: str) -> None:
        owner = self._owner_for_task(item)
        if owner not in self._by_owner:
            self._by_owner[owner] = deque()
            self._owners.append(owner)
        self._by_owner[owner].append(item)
        self._count += 1

    def _get(self) -> str:
        # Also yield to a newly arrived user after the previous user's queue
        # became empty while their task was executing.
        if len(self._owners) > 1 and self._owners[0] == self._last_owner:
            self._owners.rotate(-1)
        owner = self._owners.popleft()
        queued = self._by_owner[owner]
        item = queued.popleft()
        if queued:
            self._owners.append(owner)
        else:
            del self._by_owner[owner]
        self._last_owner = owner
        self._count -= 1
        return item

    def _format(self) -> str:
        return f"maxsize={self._maxsize} tasks={self._count} users={len(self._owners)}"


def create_task_queue() -> FairTaskQueue:
    from .db import get_task

    def owner_for_task(task_id: str) -> str:
        task = get_task(task_id)
        return task.ownerId if task else "deleted"

    return FairTaskQueue(owner_for_task)
