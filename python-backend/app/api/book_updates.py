from fastapi import APIRouter, HTTPException, Request, Response

from ..book_updates import BookUpdateService
from ..book_updates_models import BookUpdateAck, BookUpdateSettings, BookUpdateState
from ..book_updates_repository import CheckThrottled, UpdateConflict
from ..db import get_book
from ..user_auth import require_user_access

router = APIRouter()


def _service(request: Request) -> BookUpdateService:
    service = getattr(request.app.state, "book_updates", None)
    if service is None:
        raise HTTPException(status_code=503, detail="追更服务尚未就绪，请稍后重试")
    return service


def _error(error):
    status = (
        404
        if isinstance(error, KeyError)
        else 429
        if isinstance(error, CheckThrottled)
        else 409
        if isinstance(error, UpdateConflict)
        else 400
    )
    return HTTPException(
        status_code=status,
        detail="未找到书籍" if isinstance(error, KeyError) else str(error),
        headers={"Cache-Control": "no-store"},
    )


def _book_owner(request: Request, book_id: str) -> str:
    # Admin/desktop access uses None as an unrestricted *lookup scope*. The
    # tracking repository needs the saved book's owner, never that scope value.
    book = get_book(book_id, require_user_access(request).owner_id)
    if book is None:
        raise _error(KeyError(book_id))
    return book.ownerId


@router.get("/book-updates", response_model=list[BookUpdateState])
async def list_updates(request: Request, response: Response):
    response.headers["Cache-Control"] = "no-store"
    return _service(request).list_states(require_user_access(request).owner_id)


@router.get("/books/{book_id}/updates", response_model=BookUpdateState)
async def get_updates(book_id: str, request: Request, response: Response):
    owner_id = _book_owner(request, book_id)
    response.headers["Cache-Control"] = "no-store"
    try:
        return _service(request).state(book_id, owner_id)
    except (KeyError, ValueError) as error:
        raise _error(error) from None


@router.put("/books/{book_id}/updates", response_model=BookUpdateState)
async def configure_updates(book_id: str, payload: BookUpdateSettings, request: Request, response: Response):
    owner_id = _book_owner(request, book_id)
    response.headers["Cache-Control"] = "no-store"
    try:
        return _service(request).configure(book_id, owner_id, payload)
    except (KeyError, ValueError) as error:
        raise _error(error) from None


@router.post("/books/{book_id}/updates/check", response_model=BookUpdateState)
async def check_updates(book_id: str, request: Request, response: Response):
    owner_id = _book_owner(request, book_id)
    response.headers["Cache-Control"] = "no-store"
    try:
        return await _service(request).check(book_id, owner_id)
    except (KeyError, ValueError) as error:
        raise _error(error) from None


@router.post("/books/{book_id}/updates/ack", response_model=BookUpdateState)
async def acknowledge_updates(book_id: str, payload: BookUpdateAck, request: Request, response: Response):
    owner_id = _book_owner(request, book_id)
    response.headers["Cache-Control"] = "no-store"
    try:
        return _service(request).acknowledge(book_id, owner_id, payload.throughChapterIndex)
    except (KeyError, ValueError) as error:
        raise _error(error) from None
