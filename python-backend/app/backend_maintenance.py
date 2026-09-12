"""Compose snapshot maintenance with the application's worker lifecycle."""

from __future__ import annotations

from contextlib import asynccontextmanager

from .backup_format import BackupError
from .maintenance import MaintenanceBusy
from .runtime_bindings import RuntimeBindings


@asynccontextmanager
async def quiesce_backend(runtime: RuntimeBindings, operation: str):
    gate = runtime.app.state.maintenance_gate
    try:
        async with gate.exclusive():
            ready = False

            async def reload() -> None:
                nonlocal ready
                ready = False
                # A failed startup can already have created some workers.
                gate.failed = True
                await runtime._run_shutdown(runtime.app)
                runtime._reset_task_queue()
                try:
                    await runtime._run_startup(runtime.app)
                except BaseException:
                    await runtime._run_shutdown(runtime.app)
                    raise
                gate.failed = False
                ready = True

            await runtime._run_shutdown(runtime.app)
            try:
                yield reload
            finally:
                # Pre-swap validation failures also need the original workers back.
                if not ready:
                    await reload()
    except MaintenanceBusy as error:
        raise BackupError(str(error), 409) from error
