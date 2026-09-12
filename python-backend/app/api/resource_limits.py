from fastapi import APIRouter, HTTPException, Request, Response

from ..admin_auth import require_admin_session
from ..backup_service import run_blocking
from ..resource_limits import ResourceLimitError, ResourceLimitPatch, ResourceUsage, get_usage, update_limit
from ..user_auth import require_multi_user_mode, require_user_access

router = APIRouter(tags=["resource-limits"])
admin_router = APIRouter(prefix="/admin/api", tags=["admin"])


async def _usage(owner_id: str, response: Response):
    response.headers["Cache-Control"] = "no-store"
    try:
        return await run_blocking(get_usage, owner_id)
    except ResourceLimitError as error:
        raise HTTPException(status_code=error.status_code, detail=str(error)) from None


@router.get("/resources/usage", response_model=ResourceUsage)
async def read_own_usage(request: Request, response: Response):
    return await _usage(require_user_access(request).user.id, response)


@admin_router.get("/users/{owner_id}/resources", response_model=ResourceUsage)
async def read_user_usage(owner_id: str, request: Request, response: Response):
    require_multi_user_mode()
    require_admin_session(request)
    return await _usage(owner_id, response)


@admin_router.put("/users/{owner_id}/resources", response_model=ResourceUsage)
async def write_user_limits(owner_id: str, payload: ResourceLimitPatch, request: Request, response: Response):
    require_multi_user_mode()
    require_admin_session(request, require_csrf=True)
    try:
        update_limit(owner_id, payload)
    except ResourceLimitError as error:
        raise HTTPException(status_code=error.status_code, detail=str(error)) from None
    return await _usage(owner_id, response)
