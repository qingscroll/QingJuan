from __future__ import annotations

import asyncio
import threading
import time
from collections import deque

from fastapi import APIRouter, HTTPException, Request, Response, status
from pydantic import BaseModel, ConfigDict, Field, SecretStr

from ..db import get_user_by_email_key
from ..models import UserRecord
from ..registration import (
    EMAIL_CODE_RESEND_SECONDS,
    EMAIL_CODE_TTL_SECONDS,
    EmailCodeRateLimited,
    RegistrationPolicy,
    activate_email_code,
    discard_email_code,
    generate_email_code,
    load_registration_settings,
    normalize_email,
    registration_policy,
    reserve_email_code,
    send_verification_email,
    verify_email_code,
    verify_identity_badge,
)
from ..user_auth import (
    AuthenticationStateChanged,
    authenticate_user_state,
    issue_user_session,
    logout_user_session,
    normalize_username,
    read_user_session,
    register_user,
    require_multi_user_mode,
)
from .account_maintenance import router as account_maintenance_router
from .auth_security import (
    PasswordLoginResponse,
    finalize_or_challenge,
)
from .auth_security import (
    router as auth_security_router,
)

router = APIRouter(prefix="/auth", tags=["auth"])
_MAX_FAILED_ATTEMPTS = 5
_ATTEMPT_WINDOW_SECONDS = 5 * 60
_MAX_EMAIL_SENDS_PER_IP = 5
_EMAIL_SEND_WINDOW_SECONDS = 60 * 60
_MAX_REGISTRATION_FAILURES = 10
_REGISTRATION_FAILURE_WINDOW_SECONDS = 15 * 60


class UserLoginAttemptLimiter:
    def __init__(self) -> None:
        self._failures: dict[str, deque[float]] = {}
        self._lock = threading.Lock()

    def reserve(self, key: str) -> int | None:
        with self._lock:
            failures = self._active(key)
            now = time.monotonic()
            if len(failures) >= _MAX_FAILED_ATTEMPTS:
                return max(1, int(_ATTEMPT_WINDOW_SECONDS - (now - failures[0])))
            failures.append(now)
            return None

    def reset(self, key: str) -> None:
        with self._lock:
            self._failures.pop(key, None)

    def _active(self, key: str) -> deque[float]:
        now = time.monotonic()
        failures = self._failures.setdefault(key, deque())
        cutoff = now - _ATTEMPT_WINDOW_SECONDS
        while failures and failures[0] <= cutoff:
            failures.popleft()
        return failures


class EmailCodeSendLimiter:
    def __init__(self) -> None:
        self._attempts: dict[str, deque[float]] = {}

    def reserve(self, key: str) -> int | None:
        attempts = self._active(key)
        if len(attempts) >= _MAX_EMAIL_SENDS_PER_IP:
            return max(1, int(_EMAIL_SEND_WINDOW_SECONDS - (time.monotonic() - attempts[0])))
        attempts.append(time.monotonic())
        return None

    def _active(self, key: str) -> deque[float]:
        now = time.monotonic()
        attempts = self._attempts.setdefault(key, deque())
        cutoff = now - _EMAIL_SEND_WINDOW_SECONDS
        while attempts and attempts[0] <= cutoff:
            attempts.popleft()
        return attempts


class RegistrationAttemptLimiter:
    def __init__(self) -> None:
        self._failures: dict[str, deque[float]] = {}

    def reserve(self, key: str) -> int | None:
        failures = self._active(key)
        now = time.monotonic()
        if len(failures) >= _MAX_REGISTRATION_FAILURES:
            return max(1, int(_REGISTRATION_FAILURE_WINDOW_SECONDS - (now - failures[0])))
        failures.append(now)
        return None

    def reset(self, key: str) -> None:
        self._failures.pop(key, None)

    def _active(self, key: str) -> deque[float]:
        now = time.monotonic()
        failures = self._failures.setdefault(key, deque())
        cutoff = now - _REGISTRATION_FAILURE_WINDOW_SECONDS
        while failures and failures[0] <= cutoff:
            failures.popleft()
        return failures


class UserRegistrationPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    username: str = Field(min_length=1, max_length=32)
    email: str = Field(min_length=3, max_length=254)
    displayName: str | None = Field(default=None, max_length=64)
    password: SecretStr = Field(min_length=1, max_length=256)
    emailCode: SecretStr | None = Field(default=None, min_length=1, max_length=6)
    identityBadge: SecretStr | None = Field(default=None, min_length=1, max_length=128)


class UserLoginPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    username: str = Field(min_length=1, max_length=32)
    password: SecretStr = Field(min_length=1, max_length=256)


class UserSessionResponse(BaseModel):
    token: str
    user: UserRecord


class EmailCodePayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    email: str = Field(min_length=3, max_length=254)


class EmailCodeDispatchResponse(BaseModel):
    accepted: bool = True
    expiresInSeconds: int = EMAIL_CODE_TTL_SECONDS
    resendAfterSeconds: int = EMAIL_CODE_RESEND_SECONDS


@router.get("/registration-policy", response_model=RegistrationPolicy)
async def get_registration_policy(response: Response) -> RegistrationPolicy:
    require_multi_user_mode()
    _no_store(response)
    return registration_policy()


@router.post(
    "/email-code",
    response_model=EmailCodeDispatchResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
async def post_email_code(
    payload: EmailCodePayload,
    request: Request,
    response: Response,
) -> EmailCodeDispatchResponse:
    require_multi_user_mode()
    _no_store(response)
    settings = load_registration_settings()
    if not settings.email_verification_required:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="管理员尚未启用邮箱验证码注册",
        )
    if not settings.smtp_configured:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="邮件服务暂不可用，请联系管理员",
        )
    try:
        email, email_key = normalize_email(payload.email)
    except ValueError as error:
        raise _registration_error(error) from error

    client_host = request.client.host if request.client is not None else "unknown"
    retry_after = _email_code_limiter(request).reserve(client_host)
    if retry_after is not None:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="验证码发送过于频繁，请稍后再试",
            headers={"Retry-After": str(retry_after)},
        )
    code = generate_email_code()
    try:
        code_hash = await asyncio.to_thread(reserve_email_code, email_key, code)
    except EmailCodeRateLimited as error:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=str(error),
            headers={"Retry-After": str(error.retry_after)},
        ) from error
    if get_user_by_email_key(email_key) is not None:
        return EmailCodeDispatchResponse()
    try:
        await asyncio.to_thread(
            send_verification_email,
            settings,
            recipient=email,
            code=code,
        )
    except Exception as error:
        await _discard_email_code_safely(email_key, code_hash)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="验证码发送失败，请稍后再试或联系管理员",
        ) from error
    try:
        activated = await asyncio.to_thread(activate_email_code, email_key, code_hash)
    except Exception as error:
        await _discard_email_code_safely(email_key, code_hash)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="验证码暂时无法保存，请重试",
        ) from error
    if not activated:
        await _discard_email_code_safely(email_key, code_hash)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="验证码暂时无法保存，请重试",
        )
    return EmailCodeDispatchResponse()


@router.post("/register", response_model=UserSessionResponse, status_code=status.HTTP_201_CREATED)
async def register(
    payload: UserRegistrationPayload,
    request: Request,
    response: Response,
) -> UserSessionResponse:
    require_multi_user_mode()
    _no_store(response)
    client_host = request.client.host if request.client is not None else "unknown"
    limiter = _registration_limiter(request)
    retry_after = limiter.reserve(client_host)
    if retry_after is not None:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="注册验证失败次数过多，请稍后再试",
            headers={"Retry-After": str(retry_after)},
        )
    try:
        email, email_key = normalize_email(payload.email)
        settings = load_registration_settings()
        verified_code_hash: str | None = None
        if settings.email_verification_required:
            if payload.emailCode is None:
                raise ValueError("请输入邮箱验证码")
            email_code = payload.emailCode.get_secret_value()
            if len(email_code) != 6 or any(character not in "0123456789" for character in email_code):
                raise ValueError("邮箱验证码必须为 6 位数字")
            verified_code_hash = await asyncio.to_thread(verify_email_code, email_key, email_code)
            if verified_code_hash is None:
                raise ValueError("邮箱验证码错误或已过期")
        identity_badge = (
            payload.identityBadge.get_secret_value() if payload.identityBadge is not None else None
        )
        if settings.identity_badge_required and (
            identity_badge is None
            or not await asyncio.to_thread(verify_identity_badge, identity_badge, settings)
        ):
            raise ValueError("身份牌验证失败")
        if get_user_by_email_key(email_key) is not None:
            raise ValueError("邮箱已被注册")
        user = await asyncio.to_thread(
            register_user,
            username=payload.username,
            display_name=payload.displayName,
            password=payload.password.get_secret_value(),
            email=email,
            email_verification_code_hash=verified_code_hash,
        )
    except ValueError as error:
        raise _registration_error(error) from error
    limiter.reset(client_host)
    try:
        token = await asyncio.to_thread(
            issue_user_session,
            user,
            expected_auth_epoch=0,
            expected_two_factor_enabled=False,
        )
    except AuthenticationStateChanged as error:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="用户认证状态已变更，请重新登录",
        ) from error
    return UserSessionResponse(token=token, user=user)


@router.post("/login", response_model=PasswordLoginResponse)
async def login(
    payload: UserLoginPayload,
    request: Request,
    response: Response,
) -> PasswordLoginResponse:
    require_multi_user_mode()
    _no_store(response)
    client_host = request.client.host if request.client is not None else "unknown"
    try:
        _, username_key = normalize_username(payload.username)
    except ValueError:
        username_key = "<invalid>"
    limiter_key = f"{client_host}:{username_key}"
    limiter = _login_limiter(request)
    retry_after = limiter.reserve(limiter_key)
    if retry_after is not None:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="登录尝试过于频繁，请稍后再试",
            headers={
                "Cache-Control": "no-store",
                "Pragma": "no-cache",
                "Retry-After": str(retry_after),
            },
        )
    authenticated = await asyncio.to_thread(
        authenticate_user_state,
        payload.username,
        payload.password.get_secret_value(),
    )
    if authenticated is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="用户名或密码错误",
            headers={"Cache-Control": "no-store", "Pragma": "no-cache"},
        )
    limiter.reset(limiter_key)
    return await finalize_or_challenge(request, authenticated)


@router.get("/session", response_model=UserRecord)
async def session(request: Request, response: Response) -> UserRecord:
    require_multi_user_mode()
    _no_store(response)
    return read_user_session(request)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(request: Request) -> Response:
    require_multi_user_mode()
    logout_user_session(request)
    response = Response(status_code=status.HTTP_204_NO_CONTENT)
    _no_store(response)
    return response


def _no_store(response: Response) -> None:
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"


def _login_limiter(request: Request) -> UserLoginAttemptLimiter:
    limiter = getattr(request.app.state, "user_login_limiter", None)
    if not isinstance(limiter, UserLoginAttemptLimiter):
        limiter = UserLoginAttemptLimiter()
        request.app.state.user_login_limiter = limiter
    return limiter


def _email_code_limiter(request: Request) -> EmailCodeSendLimiter:
    limiter = getattr(request.app.state, "email_code_send_limiter", None)
    if not isinstance(limiter, EmailCodeSendLimiter):
        limiter = EmailCodeSendLimiter()
        request.app.state.email_code_send_limiter = limiter
    return limiter


def _registration_limiter(request: Request) -> RegistrationAttemptLimiter:
    limiter = getattr(request.app.state, "registration_attempt_limiter", None)
    if not isinstance(limiter, RegistrationAttemptLimiter):
        limiter = RegistrationAttemptLimiter()
        request.app.state.registration_attempt_limiter = limiter
    return limiter


def _registration_error(error: ValueError) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_400_BAD_REQUEST,
        detail=str(error),
        headers={"Cache-Control": "no-store", "Pragma": "no-cache"},
    )


async def _discard_email_code_safely(email_key: str, code_hash: str) -> None:
    try:
        await asyncio.to_thread(discard_email_code, email_key, code_hash)
    except Exception:
        # A pending row is inactive and cannot validate; cleanup must not expose the SMTP failure.
        return


router.include_router(auth_security_router)
router.include_router(account_maintenance_router)
