import asyncio
from typing import Literal

from fastapi import APIRouter, HTTPException, Query, Request, Response

from .. import annotations as service
from .. import annotations_repository as repository
from ..annotations_models import (
    AnnotationCreate,
    AnnotationPatch,
    CachedTextQuery,
    CachedTextResults,
    ReadingAnnotation,
)
from ..cached_text import search_cached_text
from ..db import get_book
from ..user_auth import require_user_access

router = APIRouter()


def _book(request: Request, book_id: str):
    book = get_book(book_id, require_user_access(request).owner_id)
    if book is None:
        raise HTTPException(status_code=404, detail="未找到书籍")
    return book


def _error(error):
    return HTTPException(
        status_code=404
        if isinstance(error, KeyError)
        else 409
        if isinstance(error, repository.AnnotationConflict)
        else 400,
        detail="未找到书签或笔记" if isinstance(error, KeyError) else str(error),
        headers={"Cache-Control": "no-store"},
    )


@router.get("/books/{book_id}/annotations", response_model=list[ReadingAnnotation])
async def list_annotations(
    book_id: str,
    request: Request,
    response: Response,
    limit: int = Query(50, ge=1, le=100),
    offset: int = Query(0, ge=0),
    kind: Literal["bookmark", "note"] | None = None,
    chapterIndex: int | None = Query(None, ge=1),
    mode: Literal["original", "translated"] | None = None,
):
    book = _book(request, book_id)
    response.headers["Cache-Control"] = "no-store"
    return service.list_annotations(
        book, limit=limit, offset=offset, kind=kind, chapter_index=chapterIndex, mode=mode
    )


@router.post("/books/{book_id}/annotations", response_model=ReadingAnnotation)
async def create_annotation(book_id: str, payload: AnnotationCreate, request: Request, response: Response):
    book = _book(request, book_id)
    response.headers["Cache-Control"] = "no-store"
    try:
        return service.create_annotation(book, payload)
    except (KeyError, ValueError) as error:
        raise _error(error) from None


@router.patch("/books/{book_id}/annotations/{annotation_id}", response_model=ReadingAnnotation)
async def update_annotation(
    book_id: str, annotation_id: str, payload: AnnotationPatch, request: Request, response: Response
):
    book = _book(request, book_id)
    response.headers["Cache-Control"] = "no-store"
    try:
        return service.update_annotation(book, annotation_id, payload)
    except (KeyError, ValueError) as error:
        raise _error(error) from None


@router.delete("/books/{book_id}/annotations/{annotation_id}")
async def delete_annotation(
    book_id: str,
    annotation_id: str,
    request: Request,
    response: Response,
    expectedRevision: int = Query(ge=0),
):
    book = _book(request, book_id)
    response.headers["Cache-Control"] = "no-store"
    try:
        repository.delete_annotation(book.id, book.ownerId, annotation_id, expectedRevision)
        return {"status": "ok"}
    except (KeyError, ValueError) as error:
        raise _error(error) from None


@router.post("/books/{book_id}/search-text", response_model=CachedTextResults)
async def search_text(book_id: str, payload: CachedTextQuery, request: Request, response: Response):
    book = _book(request, book_id)
    response.headers["Cache-Control"] = "no-store"
    slots = getattr(request.app.state, "cached_text_slots", None)
    if slots is None:
        slots = request.app.state.cached_text_slots = asyncio.Semaphore(2)
    try:
        async with slots:
            operation = asyncio.create_task(asyncio.to_thread(search_cached_text, book, payload))
            try:
                return await asyncio.shield(operation)
            except asyncio.CancelledError:
                await asyncio.gather(operation, return_exceptions=True)
                raise
    except (ValueError, OSError) as error:
        raise _error(error) from None
