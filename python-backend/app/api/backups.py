from __future__ import annotations

import os
import secrets
from contextlib import contextmanager
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, Response, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, ConfigDict, Field

from ..admin_auth import require_admin_write_access
from ..backup_service import (
    BackupArtifact,
    BackupError,
    BackupInspection,
    BackupRestoreResult,
    BackupService,
    run_blocking,
)

router = APIRouter(tags=["backups"], dependencies=[Depends(require_admin_write_access)])
PRIVATE_HEADERS = {"Cache-Control": "no-store", "Pragma": "no-cache", "X-Content-Type-Options": "nosniff"}


class BackupCreatePayload(BaseModel):
    model_config = ConfigDict(extra="forbid")
    acknowledgeSensitiveData: Literal[True]


class BackupRestorePayload(BaseModel):
    model_config = ConfigDict(extra="forbid")
    restoreId: str = Field(pattern=r"^[0-9a-f]{32}$")
    confirmationToken: str = Field(pattern=r"^[0-9a-f]{64}$")


def _service(request: Request) -> BackupService:
    service = getattr(request.app.state, "backup_service", None)
    if not isinstance(service, BackupService):
        raise HTTPException(status_code=503, detail="备份服务尚未就绪，请稍后重试", headers=PRIVATE_HEADERS)
    return service


@contextmanager
def _errors():
    try:
        yield
    except BackupError as error:
        raise HTTPException(
            status_code=error.status_code, detail=str(error), headers=PRIVATE_HEADERS
        ) from None
    except (OSError, RuntimeError):
        raise HTTPException(
            status_code=500, detail="备份操作失败，请检查磁盘空间和服务状态后重试", headers=PRIVATE_HEADERS
        ) from None


@router.get("/backups", response_model=list[BackupArtifact])
async def list_backups(request: Request, response: Response) -> list[BackupArtifact]:
    response.headers.update(PRIVATE_HEADERS)
    with _errors():
        return await run_blocking(_service(request).list_artifacts)


@router.post("/backups", response_model=BackupArtifact, status_code=201)
async def create_backup(payload: BackupCreatePayload, request: Request, response: Response) -> BackupArtifact:
    response.headers.update(PRIVATE_HEADERS)
    with _errors():
        return await _service(request).create()


@router.post("/backups/{backup_id}/download")
async def download_backup(backup_id: str, request: Request) -> FileResponse:
    with _errors():
        path = _service(request).artifact_path(backup_id)
        return FileResponse(
            path,
            filename=f"qingjuan-backup-{backup_id}.zip",
            media_type="application/zip",
            headers=PRIVATE_HEADERS,
        )


@router.post("/backups/inspect", response_model=BackupInspection)
async def inspect_backup(
    request: Request,
    response: Response,
    file: Annotated[UploadFile, File()],
    mode: Annotated[Literal["replace", "migrate_local"], Form()] = "replace",
    migrationOwnerId: Annotated[str | None, Form(max_length=128)] = None,
) -> BackupInspection:
    response.headers.update(PRIVATE_HEADERS)
    with _errors():
        service = _service(request)
        service._ready()
        upload = service.storage / f"upload-{secrets.token_hex(16)}.zip"
        try:
            written = 0
            with upload.open("xb") as target:
                if os.name != "nt":
                    upload.chmod(0o600)
                while chunk := await file.read(1024 * 1024):
                    written += len(chunk)
                    if written > service.limits.archive_bytes:
                        raise BackupError("备份上传超过大小上限", 413)
                    await run_blocking(target.write, chunk)
            if written == 0:
                raise BackupError("请选择有效的备份文件")
            return await service.inspect(upload, mode=mode, migration_owner_id=migrationOwnerId)
        finally:
            await file.close()
            upload.unlink(missing_ok=True)


@router.post("/backups/restore", response_model=BackupRestoreResult)
async def restore_backup(
    payload: BackupRestorePayload, request: Request, response: Response
) -> BackupRestoreResult:
    response.headers.update(PRIVATE_HEADERS)
    with _errors():
        return await _service(request).restore(payload.restoreId, payload.confirmationToken)
