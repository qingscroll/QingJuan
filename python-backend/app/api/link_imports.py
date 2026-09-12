from fastapi import APIRouter, HTTPException, Query, Request

from ..models import PublicLinkJobRecord
from ..user_auth import require_user_access

router = APIRouter()


@router.get("/link-jobs", response_model=list[PublicLinkJobRecord])
async def list_link_jobs(request: Request, limit: int = Query(50, ge=1, le=100), offset: int = Query(0, ge=0), activeOnly: bool = False):
    owner_id = require_user_access(request).owner_id
    store = getattr(request.app.state, "link_job_store", None)
    if store is None:
        raise HTTPException(status_code=503, detail="导入记录尚未就绪，请稍后重试")
    return store.list(owner_id, limit=limit, offset=offset, active_only=activeOnly)


@router.post("/link-jobs/{job_id}/retry", response_model=PublicLinkJobRecord)
async def retry_link_job(job_id: str, request: Request):
    owner_id = require_user_access(request).owner_id
    store = getattr(request.app.state, "link_job_store", None)
    schedule = getattr(request.app.state, "schedule_link_job", None)
    if store is None or schedule is None:
        raise HTTPException(status_code=503, detail="导入任务执行器尚未就绪，请稍后重试")
    try:
        job, enqueue = store.retry(job_id, owner_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="未找到链接任务") from exc
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if enqueue:
        schedule(job.id)
    return job
