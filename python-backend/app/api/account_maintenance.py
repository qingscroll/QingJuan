from __future__ import annotations

import asyncio
from typing import Literal

from fastapi import APIRouter, BackgroundTasks, HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, Field, SecretStr

from .. import account_maintenance as service
from .. import account_maintenance_repository as repository
from ..registration import load_registration_settings
from ..user_auth import read_user_session, read_user_session_hash, require_multi_user_mode

router = APIRouter()
_HEADERS = {"Cache-Control": "no-store", "Pragma": "no-cache"}


class ReauthenticationPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")
    password: SecretStr = Field(min_length=1, max_length=256)
    code: SecretStr | None = Field(default=None, min_length=6, max_length=32)


class PasswordChangePayload(BaseModel):
    model_config = ConfigDict(extra="forbid")
    currentPassword: SecretStr = Field(min_length=1, max_length=256)
    newPassword: SecretStr = Field(min_length=1, max_length=256)
    code: SecretStr | None = Field(default=None, min_length=6, max_length=32)


class ResetRequestPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")
    email: str = Field(min_length=3, max_length=254)


class EmailConfirmationPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")
    emailCode: SecretStr = Field(min_length=1, max_length=32)


class ResetConfirmationPayload(ResetRequestPayload, EmailConfirmationPayload):
    newPassword: SecretStr = Field(min_length=1, max_length=256)
    code: SecretStr | None = Field(default=None, min_length=6, max_length=32)


class EmailDispatchResponse(BaseModel):
    accepted: Literal[True] = True
    expiresInSeconds: int = service.CODE_TTL_SECONDS
    resendAfterSeconds: int = service.RESEND_SECONDS
    message: str = "如果该邮箱符合条件，验证码将发送到邮箱；请查看收件箱或稍后重试。"


class AccountMaintenanceResponse(BaseModel):
    email: str | None
    emailVerified: bool
    emailServiceAvailable: bool


class AccountSessionResponse(BaseModel):
    id: str
    platform: Literal["android", "windows", "linux", "macos", "ios", "other"]
    createdAt: str
    expiresAt: str
    lastSeenAt: str
    current: bool


class AccountSessionsResponse(BaseModel):
    sessions: list[AccountSessionResponse]


async def _call(function, *args, error_status=400, **kwargs):
    try:
        return await asyncio.to_thread(function, *args, **kwargs)
    except service.MaintenanceRateLimited as error:
        raise HTTPException(
            status_code=429, detail=str(error), headers={**_HEADERS, "Retry-After": str(error.retry_after)}
        ) from error
    except ValueError as error:
        raise HTTPException(status_code=error_status, detail=str(error), headers=_HEADERS) from error


async def _rate_ip(request: Request, action: str, *, limit=20):
    host = request.client.host if request.client else "unknown"
    await _call(service.check_rate, f"ip:{action}:{host}", limit=limit, seconds=900)


def _secret(value: SecretStr | None) -> str | None:
    return value.get_secret_value() if value else None


@router.get("/account/maintenance", response_model=AccountMaintenanceResponse)
async def get_account_maintenance(request: Request, response: Response):
    require_multi_user_mode()
    response.headers.update(_HEADERS)
    user = read_user_session(request)
    verified, settings = await asyncio.gather(
        asyncio.to_thread(repository.email_is_verified, user.id),
        asyncio.to_thread(load_registration_settings),
    )
    return AccountMaintenanceResponse(
        email=user.email, emailVerified=verified, emailServiceAvailable=settings.smtp_configured
    )


@router.post("/account/password", status_code=204)
async def post_account_password(payload: PasswordChangePayload, request: Request):
    require_multi_user_mode()
    user = read_user_session(request)
    await _call(
        service.update_password,
        user.id,
        payload.currentPassword.get_secret_value(),
        payload.newPassword.get_secret_value(),
        _secret(payload.code),
        error_status=403,
    )
    return Response(status_code=204, headers=_HEADERS)


@router.post("/account/email-verification/request", status_code=202, response_model=EmailDispatchResponse)
async def post_email_verification_request(
    payload: ReauthenticationPayload, request: Request, response: Response, background_tasks: BackgroundTasks
):
    require_multi_user_mode()
    response.headers.update(_HEADERS)
    user = read_user_session(request)
    if not user.email:
        raise HTTPException(status_code=409, detail="账号没有登记邮箱，请联系管理员", headers=_HEADERS)
    settings = await asyncio.to_thread(load_registration_settings)
    if not settings.smtp_configured:
        raise HTTPException(status_code=503, detail="邮件服务尚未配置，请联系管理员", headers=_HEADERS)
    await _rate_ip(request, "email-send", limit=10)
    await _call(
        service.confirm_password,
        user.id,
        payload.password.get_secret_value(),
        _secret(payload.code),
        error_status=403,
    )
    challenge, recipient, code = await _call(
        service.prepare_email_challenge, "verify", user.email, user_id=user.id
    )
    background_tasks.add_task(service.deliver_email_challenge, challenge, recipient, code)
    return EmailDispatchResponse()


@router.post("/account/email-verification/confirm", status_code=204)
async def post_email_verification_confirm(payload: EmailConfirmationPayload, request: Request):
    require_multi_user_mode()
    user = read_user_session(request)
    await _rate_ip(request, "email-confirm")
    await _call(service.verify_own_email, user.id, user.email or "", payload.emailCode.get_secret_value())
    return Response(status_code=204, headers=_HEADERS)


@router.post("/password-reset/request", status_code=202, response_model=EmailDispatchResponse)
async def post_password_reset_request(
    payload: ResetRequestPayload, request: Request, response: Response, background_tasks: BackgroundTasks
):
    require_multi_user_mode()
    response.headers.update(_HEADERS)
    await _rate_ip(request, "email-send", limit=10)
    challenge, recipient, code = await _call(service.prepare_email_challenge, "reset", payload.email)
    background_tasks.add_task(service.deliver_email_challenge, challenge, recipient, code)
    return EmailDispatchResponse()


@router.post("/password-reset/confirm", status_code=204)
async def post_password_reset_confirm(payload: ResetConfirmationPayload, request: Request):
    require_multi_user_mode()
    await _rate_ip(request, "password-reset-confirm")
    await _call(
        service.reset_password,
        payload.email,
        payload.emailCode.get_secret_value(),
        payload.newPassword.get_secret_value(),
        _secret(payload.code),
    )
    return Response(status_code=204, headers=_HEADERS)


@router.get("/account/sessions", response_model=AccountSessionsResponse)
async def get_account_sessions(request: Request, response: Response):
    require_multi_user_mode()
    response.headers.update(_HEADERS)
    user = read_user_session(request)
    token_hash = read_user_session_hash(request)
    await asyncio.to_thread(service.record_request_session, request, token_hash)
    sessions = await asyncio.to_thread(repository.list_sessions, user.id, token_hash)
    return AccountSessionsResponse(sessions=sessions)


@router.delete("/account/sessions/{session_id}", status_code=204)
async def delete_account_session(session_id: str, request: Request):
    require_multi_user_mode()
    user = read_user_session(request)
    if not await asyncio.to_thread(repository.revoke_session, user.id, session_id):
        raise HTTPException(status_code=404, detail="登录会话不存在或已经退出", headers=_HEADERS)
    return Response(status_code=204, headers=_HEADERS)
