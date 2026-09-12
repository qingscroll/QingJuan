from contextlib import asynccontextmanager

from fastapi import APIRouter, HTTPException, Query, Request

from ..discovery import registry, service
from ..discovery.models import ChannelResult, SitesResponse
from ..user_auth import require_user_access


@asynccontextmanager
async def lifespan(_application):
    try:
        yield
    finally:
        await service.shutdown()


router = APIRouter(prefix="/discovery", tags=["discovery"], lifespan=lifespan)


@router.get("/sites", response_model=SitesResponse)
async def list_sites(request: Request) -> SitesResponse:
    require_user_access(request)
    return SitesResponse(sites=registry.list_sites())


@router.get("/sites/{site}/channels/{channel}", response_model=ChannelResult)
async def get_channel(
    request: Request,
    site: str,
    channel: str,
    page: int = Query(default=1, ge=1, le=1000),
    limit: int = Query(default=20, ge=1, le=100),
    refresh: bool = Query(default=False),
) -> ChannelResult:
    require_user_access(request)
    try:
        return await service.fetch_channel(site, channel, page=page, limit=limit, refresh=refresh)
    except service.UnknownDiscoveryChannel as error:
        raise HTTPException(status_code=404, detail=str(error)) from None
