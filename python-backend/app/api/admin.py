from __future__ import annotations

import asyncio
import logging
import time
from collections import deque
from datetime import UTC, datetime

from fastapi import APIRouter, HTTPException, Query, Request, Response, status
from pydantic import BaseModel, ConfigDict, Field

from ..admin_auth import (
    ADMIN_CSRF_HEADER,
    ADMIN_SESSION_COOKIE,
    ADMIN_SESSION_TTL_SECONDS,
    AdminSession,
    admin_cookie_secure,
    create_admin_session,
    hash_admin_password,
    require_admin_session,
    validate_admin_auth_configuration,
    validate_admin_password,
    verify_admin_password,
)
from ..backend_update import (
    BackendUpdateConflict,
    BackendUpdateDispatchError,
    BackendUpdateStartPayload,
    BackendUpdateStartResponse,
    BackendUpdateStatus,
    BackendUpdateUnsupported,
    check_for_backend_update,
    get_backend_update_status,
    queue_backend_update,
)
from ..connection_token import (
    ConnectionTokenUnavailable,
    get_connection_token_state,
    read_connection_token,
)
from ..db import (
    get_user,
    list_users,
    revoke_user_sessions,
    update_user_password,
    update_user_profile,
)
from ..models import AdminUserRecord, UserRole
from ..multi_user import DEFAULT_ADMIN_USER_ID
from ..process_lifecycle import (
    BackendServiceActionPayload,
    BackendServiceActionResponse,
    BackendServiceStatus,
    get_backend_service_controller,
)
from ..registration import (
    RegistrationSettingsPayload,
    RegistrationSettingsView,
    registration_settings_view,
    update_registration_settings,
)
from ..runtime_logs import RuntimeLogBatch, RuntimeLogReadError, read_runtime_logs
from ..service_diagnostics import ServiceDiagnosticsResponse, build_service_diagnostics
from ..user_auth import normalize_display_name, register_user, require_multi_user_mode

router = APIRouter(prefix="/admin/api", tags=["admin"])

_MAX_FAILED_ATTEMPTS = 5
_ATTEMPT_WINDOW_SECONDS = 5 * 60
_LOGGER = logging.getLogger("qingjuan.admin")


class AdminLoginPayload(BaseModel):
    password: str = Field(min_length=1, max_length=256)


class AdminSessionResponse(BaseModel):
    authenticated: bool = True
    expiresAt: str
    csrfToken: str
    csrfHeader: str = ADMIN_CSRF_HEADER


class ConnectionTokenStatusResponse(BaseModel):
    configured: bool
    revealAvailable: bool
    maskedToken: str | None
    fingerprint: str | None


class ConnectionTokenRevealResponse(BaseModel):
    token: str


class AdminUserCreatePayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    username: str = Field(min_length=1, max_length=32)
    displayName: str | None = Field(default=None, max_length=64)
    password: str = Field(min_length=1, max_length=256)


class AdminUserUpdatePayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    displayName: str | None = Field(default=None, max_length=64)
    status: str | None = Field(default=None, pattern="^(active|disabled)$")
    role: UserRole | None = None


class AdminUserPasswordPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    password: str = Field(min_length=1, max_length=256)


class SessionsRevokedResponse(BaseModel):
    revoked: int


class LoginAttemptLimiter:
    def __init__(self) -> None:
        self._failures: dict[str, deque[float]] = {}

    def is_blocked(self, client_key: str, *, now: float | None = None) -> bool:
        failures = self._active_failures(client_key, now=now)
        return len(failures) >= _MAX_FAILED_ATTEMPTS

    def record_failure(self, client_key: str, *, now: float | None = None) -> None:
        timestamp = time.monotonic() if now is None else now
        failures = self._active_failures(client_key, now=timestamp)
        failures.append(timestamp)

    def reset(self, client_key: str) -> None:
        self._failures.pop(client_key, None)

    def _active_failures(self, client_key: str, *, now: float | None = None) -> deque[float]:
        timestamp = time.monotonic() if now is None else now
        failures = self._failures.setdefault(client_key, deque())
        cutoff = timestamp - _ATTEMPT_WINDOW_SECONDS
        while failures and failures[0] <= cutoff:
            failures.popleft()
        if not failures:
            self._failures.pop(client_key, None)
            failures = self._failures.setdefault(client_key, deque())
        return failures


@router.post("/login", response_model=AdminSessionResponse)
async def login(payload: AdminLoginPayload, request: Request, response: Response) -> AdminSessionResponse:
    _no_store(response)
    limiter = _login_limiter(request)
    client_key = request.client.host if request.client is not None else "unknown"
    if limiter.is_blocked(client_key):
        _LOGGER.warning("管理登录已限速，来源=%s", client_key)
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="登录尝试过于频繁，请稍后再试",
            headers={"Retry-After": str(_ATTEMPT_WINDOW_SECONDS)},
        )
    if not validate_admin_auth_configuration() or not verify_admin_password(payload.password):
        limiter.record_failure(client_key)
        _LOGGER.warning("管理登录失败，来源=%s", client_key)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="管理密码错误",
        )

    limiter.reset(client_key)
    _LOGGER.info("管理登录成功，来源=%s", client_key)
    session = create_admin_session()
    response.set_cookie(
        key=ADMIN_SESSION_COOKIE,
        value=session.token,
        max_age=ADMIN_SESSION_TTL_SECONDS,
        httponly=True,
        secure=admin_cookie_secure(request),
        samesite="strict",
        path="/",
    )
    return _session_response(session)


@router.get("/session", response_model=AdminSessionResponse)
async def get_session(request: Request, response: Response) -> AdminSessionResponse:
    _no_store(response)
    return _session_response(require_admin_session(request))


@router.get("/connection-token", response_model=ConnectionTokenStatusResponse)
async def get_connection_token_status(
    request: Request,
    response: Response,
) -> ConnectionTokenStatusResponse:
    require_admin_session(request)
    _no_store(response)
    token_state = await asyncio.to_thread(get_connection_token_state)
    return ConnectionTokenStatusResponse(
        configured=token_state.configured,
        revealAvailable=token_state.reveal_available,
        maskedToken=token_state.masked_token,
        fingerprint=token_state.fingerprint,
    )


@router.post("/connection-token/reveal", response_model=ConnectionTokenRevealResponse)
async def reveal_connection_token(
    request: Request,
    response: Response,
) -> ConnectionTokenRevealResponse:
    require_admin_session(request, require_csrf=True)
    _no_store(response)
    try:
        token = await asyncio.to_thread(read_connection_token)
    except ConnectionTokenUnavailable as error:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="当前部署无法显示连接 Token，请先在服务器运行更新脚本",
        ) from error
    client_key = request.client.host if request.client is not None else "unknown"
    _LOGGER.info("管理员按需显示连接 Token，来源=%s", client_key)
    return ConnectionTokenRevealResponse(token=token)


@router.get("/runtime-logs", response_model=RuntimeLogBatch)
async def get_runtime_log_batch(
    request: Request,
    response: Response,
    limit: int = Query(default=500, ge=50, le=1000),
) -> RuntimeLogBatch:
    require_admin_session(request)
    _no_store(response)
    try:
        return await asyncio.to_thread(read_runtime_logs, limit=limit)
    except RuntimeLogReadError as error:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="运行日志暂时不可读取",
        ) from error


@router.get("/diagnostics", response_model=ServiceDiagnosticsResponse)
async def get_service_diagnostics(
    request: Request,
    response: Response,
) -> ServiceDiagnosticsResponse:
    require_admin_session(request)
    _no_store(response)
    return await asyncio.to_thread(build_service_diagnostics, request.app)


@router.get("/backend-service", response_model=BackendServiceStatus)
async def get_backend_service(
    request: Request,
    response: Response,
) -> BackendServiceStatus:
    require_admin_session(request)
    _no_store(response)
    return get_backend_service_controller(request).status()


@router.post("/backend-service/actions", response_model=BackendServiceActionResponse)
async def post_backend_service_action(
    payload: BackendServiceActionPayload,
    request: Request,
    response: Response,
) -> BackendServiceActionResponse:
    require_admin_session(request, require_csrf=True)
    _no_store(response)
    client_key = request.client.host if request.client is not None else "unknown"
    _LOGGER.warning("管理员请求%s后端业务服务，来源=%s", payload.action, client_key)
    return await get_backend_service_controller(request).apply(payload.action)


@router.get("/backend-update", response_model=BackendUpdateStatus)
async def get_backend_update(
    request: Request,
    response: Response,
) -> BackendUpdateStatus:
    require_admin_session(request)
    _no_store(response)
    return await asyncio.to_thread(get_backend_update_status)


@router.post("/backend-update/check", response_model=BackendUpdateStatus)
async def post_backend_update_check(
    request: Request,
    response: Response,
) -> BackendUpdateStatus:
    require_admin_session(request, require_csrf=True)
    _no_store(response)
    try:
        return await asyncio.to_thread(check_for_backend_update)
    except BackendUpdateUnsupported as error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    except BackendUpdateConflict as error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error


@router.post(
    "/backend-update",
    response_model=BackendUpdateStartResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
async def post_backend_update(
    payload: BackendUpdateStartPayload,
    request: Request,
    response: Response,
) -> BackendUpdateStartResponse:
    require_admin_session(request, require_csrf=True)
    _no_store(response)
    try:
        result, _ = await asyncio.to_thread(queue_backend_update, payload)
    except BackendUpdateUnsupported as error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    except BackendUpdateConflict as error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    except BackendUpdateDispatchError as error:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(error)) from error
    response.headers["Location"] = "/admin/api/backend-update"
    response.headers["Retry-After"] = "2"
    return result


@router.get("/users", response_model=list[AdminUserRecord])
async def get_users(request: Request, response: Response) -> list[AdminUserRecord]:
    require_multi_user_mode()
    require_admin_session(request)
    _no_store(response)
    return list_users()


@router.get("/registration-settings", response_model=RegistrationSettingsView)
async def get_registration_settings(
    request: Request,
    response: Response,
) -> RegistrationSettingsView:
    require_multi_user_mode()
    require_admin_session(request)
    _no_store(response)
    return await asyncio.to_thread(registration_settings_view)


@router.put("/registration-settings", response_model=RegistrationSettingsView)
async def put_registration_settings(
    payload: RegistrationSettingsPayload,
    request: Request,
    response: Response,
) -> RegistrationSettingsView:
    require_multi_user_mode()
    require_admin_session(request, require_csrf=True)
    _no_store(response)
    try:
        return await asyncio.to_thread(update_registration_settings, payload)
    except ValueError as error:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(error)) from error


@router.post("/users", response_model=AdminUserRecord, status_code=status.HTTP_201_CREATED)
async def post_user(
    payload: AdminUserCreatePayload,
    request: Request,
    response: Response,
) -> AdminUserRecord:
    require_multi_user_mode()
    require_admin_session(request, require_csrf=True)
    _no_store(response)
    try:
        user = register_user(
            username=payload.username,
            display_name=payload.displayName,
            password=payload.password,
        )
    except ValueError as error:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(error)) from error
    return user


@router.patch("/users/{user_id}", response_model=AdminUserRecord)
async def patch_user(
    user_id: str,
    payload: AdminUserUpdatePayload,
    request: Request,
    response: Response,
) -> AdminUserRecord:
    require_multi_user_mode()
    require_admin_session(request, require_csrf=True)
    _no_store(response)
    current = get_user(user_id)
    if current is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="用户不存在")
    display_name = payload.displayName
    if display_name is not None:
        try:
            display_name = normalize_display_name(display_name, fallback=current.username)
        except ValueError as error:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(error)) from error
    try:
        updated = update_user_profile(
            user_id,
            display_name=display_name,
            role=payload.role,
            status=payload.status,
        )
    except ValueError as error:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(error)) from error
    if updated is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="用户不存在")
    return updated


@router.put("/users/{user_id}/password", status_code=status.HTTP_204_NO_CONTENT)
async def put_user_password(
    user_id: str,
    payload: AdminUserPasswordPayload,
    request: Request,
) -> Response:
    require_multi_user_mode()
    require_admin_session(request, require_csrf=True)
    if get_user(user_id) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="用户不存在")
    if user_id == DEFAULT_ADMIN_USER_ID:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="默认管理员密码请使用 qingjuan-password 修改",
        )
    try:
        validate_admin_password(payload.password)
    except ValueError as error:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(error)) from error
    update_user_password(
        user_id,
        hash_admin_password(payload.password),
        revoke_sessions=True,
    )
    response = Response(status_code=status.HTTP_204_NO_CONTENT)
    _no_store(response)
    return response


@router.post("/users/{user_id}/sessions/revoke", response_model=SessionsRevokedResponse)
async def post_revoke_user_sessions(
    user_id: str,
    request: Request,
    response: Response,
) -> SessionsRevokedResponse:
    require_multi_user_mode()
    require_admin_session(request, require_csrf=True)
    _no_store(response)
    if get_user(user_id) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="用户不存在")
    return SessionsRevokedResponse(revoked=revoke_user_sessions(user_id))


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(request: Request) -> Response:
    require_admin_session(request, require_csrf=True)
    response = Response(status_code=status.HTTP_204_NO_CONTENT)
    response.delete_cookie(
        key=ADMIN_SESSION_COOKIE,
        httponly=True,
        secure=admin_cookie_secure(request),
        samesite="strict",
        path="/",
    )
    _no_store(response)
    client_key = request.client.host if request.client is not None else "unknown"
    _LOGGER.info("管理会话已退出，来源=%s", client_key)
    return response


def _login_limiter(request: Request) -> LoginAttemptLimiter:
    limiter = getattr(request.app.state, "admin_login_limiter", None)
    if not isinstance(limiter, LoginAttemptLimiter):
        limiter = LoginAttemptLimiter()
        request.app.state.admin_login_limiter = limiter
    return limiter


def _session_response(session: AdminSession) -> AdminSessionResponse:
    expires_at = datetime.fromtimestamp(session.expires_at, tz=UTC).isoformat().replace("+00:00", "Z")
    return AdminSessionResponse(expiresAt=expires_at, csrfToken=session.csrf_token)


def _no_store(response: Response) -> None:
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
