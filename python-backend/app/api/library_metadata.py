from fastapi import APIRouter, HTTPException, Request, Response

from ..db import get_book
from ..library_metadata import BookMetadata, BookMetadataPatch, get_book_metadata, update_book_metadata
from ..library_metadata_repository import MetadataConflict
from ..user_auth import require_user_access

router = APIRouter()


def _book(request: Request, book_id: str):
    book = get_book(book_id, require_user_access(request).owner_id)
    if book is None:
        raise HTTPException(status_code=404, detail="未找到书籍")
    return book


@router.get("/books/{book_id}/metadata", response_model=BookMetadata)
def get_metadata(book_id: str, request: Request, response: Response):
    response.headers["Cache-Control"] = "no-store"
    return get_book_metadata(_book(request, book_id))


@router.patch("/books/{book_id}/metadata", response_model=BookMetadata)
def patch_metadata(book_id: str, payload: BookMetadataPatch, request: Request, response: Response):
    book = _book(request, book_id)
    response.headers["Cache-Control"] = "no-store"
    try:
        return update_book_metadata(book, payload)
    except MetadataConflict as error:
        raise HTTPException(
            status_code=409, detail=str(error), headers={"Cache-Control": "no-store"}
        ) from None
    except KeyError:
        raise HTTPException(status_code=404, detail="未找到书籍") from None
