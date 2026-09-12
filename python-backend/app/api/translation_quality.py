from __future__ import annotations

import sqlite3
from collections.abc import Callable

from fastapi import APIRouter, HTTPException, Request, Response

from .. import db
from ..resource_limits import ResourceLimitError
from ..storage_models import StorageError
from ..translation_quality_models import (
    BookGlossary,
    ChapterTranslation,
    GlossaryPatch,
    RetranslateSelection,
    TranslationEdit,
    TranslationQualityError,
    TranslationRestore,
    TranslationRevision,
    TranslationSuggestion,
    TranslationUsage,
)
from ..translation_quality_retranslate import retranslate
from ..translation_quality_service import (
    get_chapter,
    get_glossary,
    get_history,
    restore_chapter,
    save_chapter,
    save_glossary,
)
from ..translation_quality_usage import list_usage
from ..user_auth import require_user_access

router = APIRouter(tags=["translation-quality"])


def _book(request: Request, book_id: str):
    book = db.get_book(book_id, require_user_access(request).owner_id)
    if book is None:
        raise HTTPException(status_code=404, detail="未找到书籍")
    return book


def _invoke(response: Response, function: Callable, *args):
    response.headers["Cache-Control"] = "no-store"
    try:
        return function(*args)
    except (TranslationQualityError, ResourceLimitError, StorageError) as error:
        raise HTTPException(
            status_code=error.status_code, detail=str(error), headers={"Cache-Control": "no-store"}
        ) from None
    except (OSError, sqlite3.Error):
        raise HTTPException(status_code=503, detail="译文存储暂时不可用，请检查存储后重试") from None


@router.get("/books/{book_id}/glossary", response_model=BookGlossary)
def read_glossary(book_id: str, request: Request, response: Response):
    return _invoke(response, get_glossary, _book(request, book_id))


@router.put("/books/{book_id}/glossary", response_model=BookGlossary)
def write_glossary(book_id: str, payload: GlossaryPatch, request: Request, response: Response):
    return _invoke(response, save_glossary, _book(request, book_id), payload)


@router.get("/books/{book_id}/translation/chapters/{index}", response_model=ChapterTranslation)
def read_chapter(book_id: str, index: int, request: Request, response: Response):
    return _invoke(response, get_chapter, _book(request, book_id), index)


@router.put("/books/{book_id}/translation/chapters/{index}", response_model=ChapterTranslation)
def write_chapter(book_id: str, index: int, payload: TranslationEdit, request: Request, response: Response):
    return _invoke(response, save_chapter, _book(request, book_id), index, payload)


@router.get(
    "/books/{book_id}/translation/chapters/{index}/history/{history_id}", response_model=TranslationRevision
)
def read_history(book_id: str, index: int, history_id: str, request: Request, response: Response):
    return _invoke(response, get_history, _book(request, book_id), index, history_id)


@router.post("/books/{book_id}/translation/chapters/{index}/restore", response_model=ChapterTranslation)
def restore_history(
    book_id: str, index: int, payload: TranslationRestore, request: Request, response: Response
):
    return _invoke(response, restore_chapter, _book(request, book_id), index, payload)


@router.post(
    "/books/{book_id}/translation/chapters/{index}/retranslate", response_model=TranslationSuggestion
)
async def retranslate_selection(
    book_id: str, index: int, payload: RetranslateSelection, request: Request, response: Response
):
    book = _book(request, book_id)
    response.headers["Cache-Control"] = "no-store"
    try:
        return await retranslate(book, index, payload)
    except (TranslationQualityError, ResourceLimitError, StorageError) as error:
        raise HTTPException(
            status_code=error.status_code, detail=str(error), headers={"Cache-Control": "no-store"}
        ) from None
    except (OSError, sqlite3.Error):
        raise HTTPException(status_code=503, detail="译文存储暂时不可用，请检查存储后重试") from None


@router.get("/books/{book_id}/translation/usage", response_model=list[TranslationUsage])
def read_usage(book_id: str, request: Request, response: Response):
    return _invoke(response, list_usage, _book(request, book_id))
