from fastapi import APIRouter, Query, Request

from ..admin_auth import require_admin_write_access
from ..db import load_settings
from ..resource_limits import resource_actor
from ..translation_model_health import (
    TranslationModelCheckResponse,
    check_translation_model,
    get_translation_model_check_snapshot,
)
from ..user_auth import require_user_access

router = APIRouter(tags=["translation-model"])


@router.post("/translation-model/check", response_model=TranslationModelCheckResponse)
async def post_translation_model_check(
    request: Request,
    force: bool = Query(default=False),
) -> TranslationModelCheckResponse:
    access = require_user_access(request)
    if force:
        require_admin_write_access(request)
        with resource_actor(access.user.id):
            return await check_translation_model(load_settings(), force=True)
    return get_translation_model_check_snapshot(load_settings())
