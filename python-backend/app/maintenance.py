"""Drain HTTP and background writers before taking or restoring a snapshot."""

from __future__ import annotations

import asyncio
import re
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from contextvars import ContextVar

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send


class MaintenanceBusy(RuntimeError):
    pass


class MaintenanceGate:
    def __init__(self) -> None:
        self.closed = False
        self.failed = False
        self.active_count = 0
        self._open = asyncio.Event()
        self._open.set()
        self._drained = asyncio.Event()
        self._drained.set()
        self._exclusive = asyncio.Lock()
        self._roots: dict[object, int] = {}
        self._root: ContextVar[object | None] = ContextVar('maintenance_root', default=None)

    @asynccontextmanager
    async def operation(self, *, wait: bool = True) -> AsyncIterator[None]:
        # An already admitted request may finish its child writes while closing.
        # Children count separately, including when their parent has returned.
        root = self._root.get()
        while self.closed and root not in self._roots:
            if not wait:
                raise MaintenanceBusy('正在备份或恢复数据，请稍后重试')
            await self._open.wait()
        if root not in self._roots:
            root = object()
        token = self._root.set(root)
        self._roots[root] = self._roots.get(root, 0) + 1
        self.active_count += 1
        self._drained.clear()
        try:
            yield
        finally:
            self._root.reset(token)
            self._roots[root] -= 1
            if not self._roots[root]:
                del self._roots[root]
            self.active_count -= 1
            if self.active_count == 0:
                self._drained.set()

    @asynccontextmanager
    async def exclusive(self, *, timeout: float = 30) -> AsyncIterator[None]:
        async with self._exclusive:
            self.closed = True
            self._open.clear()
            try:
                try:
                    await asyncio.wait_for(self._drained.wait(), timeout=timeout)
                except TimeoutError as error:
                    raise MaintenanceBusy('仍有任务或文件操作正在执行，请暂停任务并稍后重试') from error
                yield
            finally:
                self.closed = self.failed
                if not self.closed:
                    self._open.set()


class MaintenanceMiddleware:
    def __init__(self, app: ASGIApp, *, gate: MaintenanceGate, backup_prefix: str) -> None:
        self.app = app
        self.gate = gate
        self.backup_prefix = backup_prefix
        self.storage_cleanup = re.compile(
            re.escape(backup_prefix.removesuffix('/backups')) + r'/books/[^/]+/storage/cleanup'
        )

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        path = scope.get('path', '')
        exempt = path in {'/healthz', '/health', self.backup_prefix} or path.startswith(
            f'{self.backup_prefix}/'
        )
        exempt = exempt or (scope.get('method') == 'POST' and self.storage_cleanup.fullmatch(path) is not None)
        if scope['type'] != 'http' or exempt:
            await self.app(scope, receive, send)
            return
        async def handle() -> None:
            async with self.gate.operation(wait=False):
                # Wrap the complete ASGI lifetime, including streamed files.
                await self.app(scope, receive, send)

        task = asyncio.create_task(handle())
        try:
            await asyncio.shield(task)
        except asyncio.CancelledError:
            # A disconnected request may have a to_thread writer still running.
            # Keep it admitted until the handler and its background work settle.
            await asyncio.gather(task, return_exceptions=True)
            raise
        except MaintenanceBusy as error:
            response = JSONResponse(
                {'detail': str(error)}, status_code=503,
                headers={'Retry-After': '5', 'Cache-Control': 'no-store'},
            )
            await response(scope, receive, send)
