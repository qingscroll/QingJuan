from fastapi import APIRouter, HTTPException, Request, Response

from ..db import get_book
from ..models import ReadingProgressRecord
from ..reading_progress_repository import load_progress
from ..user_auth import require_user_access

router = APIRouter()


@router.get("/books/{book_id}/progress", response_model=ReadingProgressRecord)
async def get_reading_progress(book_id: str, request: Request, response: Response):
    book = get_book(book_id, require_user_access(request).owner_id)
    if book is None:
        raise HTTPException(status_code=404, detail="未找到书籍")
    response.headers["Cache-Control"] = "no-store"
    return load_progress(book.id, book.ownerId)
