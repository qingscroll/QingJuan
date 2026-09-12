import sqlite3
from contextlib import contextmanager

from fastapi import APIRouter, HTTPException, Request, Response

from .. import db
from ..backup_format import BackupError
from ..backup_service import run_blocking
from ..maintenance import MaintenanceBusy
from ..process_lifecycle import require_business_service_running
from ..security import require_api_authentication
from ..storage_meter import measure_book_storage
from ..storage_models import (
    BookStorageReport,
    StorageCleanupPayload,
    StorageCleanupPreview,
    StorageCleanupResult,
    StorageError,
    StoragePreviewPayload,
)
from ..storage_service import StorageService
from ..user_auth import require_user_access

router = APIRouter(tags=["storage"])
cleanup_router = APIRouter(tags=["storage"])


def _book(request: Request, book_id: str):
    book = db.get_book(book_id, require_user_access(request).owner_id)
    if book is None:
        raise HTTPException(status_code=404, detail="未找到书籍")
    return book


def _service(request: Request):
    service = getattr(request.app.state, "storage_service", None)
    if not isinstance(service, StorageService):
        raise HTTPException(status_code=503, detail="空间管理尚未就绪，请稍后重试")
    return service


@contextmanager
def _errors(response: Response):
    response.headers["Cache-Control"] = "no-store"
    try:
        yield
    except (StorageError, BackupError) as error:
        raise HTTPException(status_code=error.status_code, detail=str(error),
            headers={"Cache-Control": "no-store"}) from None
    except MaintenanceBusy as error:
        raise HTTPException(status_code=409, detail=str(error)) from None
    except (OSError, sqlite3.Error):
        raise HTTPException(status_code=503, detail="无法访问存储，请检查磁盘或稍后重试") from None


@router.get("/books/{book_id}/storage", response_model=BookStorageReport)
async def read_storage(book_id: str, request: Request, response: Response):
    with _errors(response):
        return await run_blocking(measure_book_storage, _book(request, book_id))


@router.post("/books/{book_id}/storage/cleanup-preview", response_model=StorageCleanupPreview)
async def preview_cleanup(book_id: str, payload: StoragePreviewPayload, request: Request, response: Response):
    with _errors(response):
        return await run_blocking(_service(request).preview, _book(request, book_id), payload.categories)


@cleanup_router.post("/books/{book_id}/storage/cleanup", response_model=StorageCleanupResult)
async def clean_storage(book_id: str, payload: StorageCleanupPayload, request: Request, response: Response):
    with _errors(response):
        # This route is exempt from the outer writer admission so it can acquire
        # exclusive access later. Authentication may write device metadata and
        # therefore receives its own short admission before exclusive cleanup.
        gate = request.app.state.maintenance_gate
        async with gate.operation(wait=False):
            await require_api_authentication(request)
            await require_business_service_running(request)
            book = _book(request, book_id)
            service = _service(request)
        return await service.cleanup(book.id, book.ownerId, payload.cleanupId, payload.confirmationToken)
