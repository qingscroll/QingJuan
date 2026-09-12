"""Keep in-flight file writes inside their task's maintenance admission."""

import asyncio


async def drain_on_cancel(awaitable):
    operation = asyncio.ensure_future(awaitable)
    try:
        return await asyncio.shield(operation)
    except asyncio.CancelledError:
        while not operation.done():
            try:
                await asyncio.shield(operation)
            except asyncio.CancelledError:
                continue
            except Exception:
                break
        if not operation.cancelled():
            operation.exception()
        raise


async def blocking_write(function, *args, **kwargs):
    return await drain_on_cancel(asyncio.to_thread(function, *args, **kwargs))


async def cancel_and_drain(tasks):
    for task in tasks:
        if not task.done():
            task.cancel()
    await drain_on_cancel(asyncio.gather(*tasks, return_exceptions=True))
