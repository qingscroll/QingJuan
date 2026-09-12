from fastapi import APIRouter, HTTPException, Request

from ..models import TaskRecord
from ..task_control import TaskAction, TaskConflict, change_task
from ..user_auth import require_user_access

router = APIRouter()


@router.post("/tasks/{task_id}/control/{action}", response_model=TaskRecord)
async def control_task(task_id: str, action: TaskAction, request: Request) -> TaskRecord:
    owner_id = require_user_access(request).owner_id
    queue = getattr(request.app.state, "task_queue", None)
    if queue is None:
        raise HTTPException(status_code=503, detail="任务执行器尚未就绪，请稍后重试")
    try:
        task, enqueue = change_task(task_id, owner_id, action)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="未找到任务") from exc
    except TaskConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if enqueue:
        queue.put_nowait(task.id)
    return task
