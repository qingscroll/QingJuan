"""有界 TTL 缓存；相同键共享一次抓取，返回值互不影响。"""

import asyncio
import copy
import time
from collections.abc import Awaitable, Callable
from typing import Any

from .config import settings


class TTLCache:
    def __init__(self, ttl: int = settings.cache_ttl, max_items: int = settings.cache_max_items):
        self.ttl = ttl
        self.max_items = max_items
        self._store: dict[str, tuple[float, Any]] = {}
        self._pending: dict[str, asyncio.Task] = {}

    def get(self, key: str) -> tuple[bool, Any]:
        entry = self._store.get(key)
        if entry is not None and entry[0] > time.monotonic():
            return True, copy.deepcopy(entry[1])
        self._store.pop(key, None)
        return False, None

    def set(self, key: str, value: Any) -> None:
        if self.ttl <= 0:
            return
        self._store.pop(key, None)
        while len(self._store) >= self.max_items:
            self._store.pop(next(iter(self._store)))
        self._store[key] = (time.monotonic() + self.ttl, copy.deepcopy(value))

    def clear(self) -> None:
        self._store.clear()

    def invalidate_prefix(self, prefix: str) -> None:
        for key in list(self._store):
            if key.startswith(prefix):
                self._store.pop(key, None)

    async def get_or_load(
        self, key: str, loader: Callable[[], Awaitable[Any]], *, refresh: bool = False
    ) -> tuple[Any, bool]:
        if not refresh:
            hit, value = self.get(key)
            if hit:
                return value, True
        pending = self._pending.get(key)
        shared = pending is not None
        if pending is None:

            async def load() -> Any:
                try:
                    value = await loader()
                    self.set(key, value)
                    return value
                finally:
                    self._pending.pop(key, None)

            pending = asyncio.create_task(load())
            self._pending[key] = pending
        return copy.deepcopy(await pending), shared

    async def aclose(self) -> None:
        pending = list(self._pending.values())
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        self._pending.clear()
        self.clear()


cache = TTLCache()
