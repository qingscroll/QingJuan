from fastapi import APIRouter, HTTPException, Request, Response

from ..models import ChapterContentResponse
from ..multi_user import DEFAULT_ADMIN_USER_ID
from ..preview_reading import PreviewChapterRequest, PreviewReadingError, PreviewReadingService
from ..user_auth import require_user_access

router = APIRouter()
_HEADERS = {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"}


def _service(request: Request) -> PreviewReadingService:
    service = getattr(request.app.state, "preview_reading", None)
    if service is None:
        raise HTTPException(status_code=503, detail="试读服务尚未就绪", headers=_HEADERS)
    return service


def _error(error: Exception) -> HTTPException:
    return HTTPException(
        status_code=error.status_code if isinstance(error, PreviewReadingError) else 400,
        detail=str(error) if isinstance(error, ValueError) else "试读内容加载失败，请稍后重试",
        headers=_HEADERS,
    )


@router.post("/books/preview/chapter", response_model=ChapterContentResponse)
async def preview_chapter(payload: PreviewChapterRequest, request: Request, response: Response):
    owner_id = require_user_access(request).owner_id or DEFAULT_ADMIN_USER_ID
    response.headers.update(_HEADERS)
    try:
        return await _service(request).read(owner_id, payload)
    except HTTPException:
        raise
    except Exception as error:
        raise _error(error) from error


@router.get("/books/preview/assets/{token}/{index}")
async def preview_image(token: str, index: int, request: Request):
    owner_id = require_user_access(request).owner_id or DEFAULT_ADMIN_USER_ID
    try:
        content, media_type = await _service(request).image(owner_id, token, index)
        return Response(content=content, media_type=media_type, headers=_HEADERS)
    except HTTPException:
        raise
    except Exception as error:
        raise _error(error) from error
