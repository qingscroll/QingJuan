from contextlib import asynccontextmanager

from .maintenance import MaintenanceBusy
from .storage_models import StorageError


@asynccontextmanager
async def quiesce_storage(gate, _operation: str):
    async def unchanged():
        pass

    try:
        async with gate.exclusive():
            yield unchanged
    except MaintenanceBusy as error:
        raise StorageError(str(error), 409) from None
