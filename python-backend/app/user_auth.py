from __future__ import annotations

import hashlib
import re
import secrets
import sqlite3
import unicodedata
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from fastapi import HTTPException, Request, status

from .admin_auth import (
    hash_admin_password,
    read_admin_session,
    require_admin_write_access,
    validate_admin_password,
    verify_password_hash,
)
from .db import (
    UserSecurityState,
    create_user,
    create_user_session,
    delete_user_session,
    get_user,
    get_user_authentication_state_by_username,
    get_user_by_session_hash,
    get_user_security_state,
    mark_user_login,
)
from .models import UserRecord
from .multi_user import DEFAULT_ADMIN_USER_ID, multi_user_enabled
from .registration import normalize_email

USER_TOKEN_HEADER = "X-QingJuan-User-Token"
USER_SESSION_TTL = timedelta(days=30)
_TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9_-]{32,256}$")
_DUMMY_PASSWORD_HASH = (
    "pbkdf2_sha256:600000:71696e676a75616e2d757365722d617574682d64756d6d792d73616c74:"
    "d19e0ddf48861adbd42c38ec1b4c2fb2a65ec801a60644b6e1ad1dd05b149d8c"
)


@dataclass(frozen=True, slots=True)
class UserAccess:
    user: UserRecord
    owner_id: str | None
    admin_view: bool = False


@dataclass(frozen=True, slots=True)
class AuthenticatedUser:
    user: UserRecord
    auth_epoch: int
    two_factor_enabled: bool


class AuthenticationStateChanged(RuntimeError):
    pass


def normalize_username(value: str) -> tuple[str, str]:
    username = unicodedata.normalize("NFKC", value).strip()
    if not 3 <= len(username) <= 32:
        raise ValueError("用户名长度需要在 3 到 32 个字符之间")
    if any(not (character.isalnum() or character in "._-") for character in username):
        raise ValueError("用户名只能包含文字、数字、点、下划线或连字符")
    return username, username.casefold()


def normalize_display_name(value: str | None, *, fallback: str) -> str:
    display_name = unicodedata.normalize("NFKC", value or "").strip() or fallback
    if len(display_name) > 64 or any(not character.isprintable() for character in display_name):
        raise ValueError("显示名称不能超过 64 个字符或包含控制字符")
    return display_name


def register_user(
    *,
    username: str,
    display_name: str | None,
    password: str,
    email: str | None = None,
    email_verification_code_hash: str | None = None,
) -> UserRecord:
    normalized, username_key = normalize_username(username)
    display = normalize_display_name(display_name, fallback=normalized)
    normalized_email: str | None = None
    email_key: str | None = None
    if email is not None:
        normalized_email, email_key = normalize_email(email)
    validate_admin_password(password)
    try:
        return create_user(
            user_id=f"user-{uuid4()}",
            username=normalized,
            username_key=username_key,
            email=normalized_email,
            email_key=email_key,
            email_verification_code_hash=email_verification_code_hash,
            display_name=display,
            password_hash=hash_admin_password(password),
        )
    except sqlite3.IntegrityError as error:
        if "email" in str(error).lower():
            raise ValueError("邮箱已被注册") from error
        raise ValueError("用户名已被注册") from error


def authenticate_user(
    username: str,
    password: str,
    *,
    mark_login: bool = True,
) -> UserRecord | None:
    authenticated = authenticate_user_state(username, password)
    if authenticated is None:
        return None
    if not mark_login:
        return authenticated.user
    return complete_user_login(authenticated.user)


def authenticate_user_state(username: str, password: str) -> AuthenticatedUser | None:
    try:
        _, username_key = normalize_username(username)
    except ValueError:
        return None
    state = get_user_authentication_state_by_username(username_key)
    if state is None:
        verify_password_hash(password, _DUMMY_PASSWORD_HASH)
        return None
    if not verify_password_hash(password, state.password_hash) or state.user.status != "active":
        return None
    return AuthenticatedUser(
        user=state.user,
        auth_epoch=state.auth_epoch,
        two_factor_enabled=bool(state.totp_secret_encrypted),
    )


def complete_user_login(user: UserRecord) -> UserRecord:
    login_at = _now()
    return mark_user_login(user.id, login_at) or user


def verify_current_user_password(user_id: str, password: str) -> bool:
    return verify_current_user_password_state(user_id, password) is not None


def verify_current_user_password_state(
    user_id: str,
    password: str,
) -> UserSecurityState | None:
    state = get_user_security_state(user_id)
    password_hash = state.password_hash if state is not None else _DUMMY_PASSWORD_HASH
    valid = verify_password_hash(password, password_hash)
    if not valid or state is None or state.user.status != "active":
        return None
    return state


def issue_user_session(
    user: UserRecord,
    *,
    expected_auth_epoch: int | None = None,
    expected_two_factor_enabled: bool | None = None,
    mark_login: bool = False,
    github_config_revision: int | None = None,
    github_client_id: str | None = None,
) -> str:
    state = get_user_security_state(user.id)
    if state is None:
        raise AuthenticationStateChanged("用户认证状态已变更")
    auth_epoch = state.auth_epoch if expected_auth_epoch is None else expected_auth_epoch
    two_factor_enabled = (
        bool(state.totp_secret_encrypted)
        if expected_two_factor_enabled is None
        else expected_two_factor_enabled
    )
    token = secrets.token_urlsafe(32)
    created_at = datetime.now(UTC)
    login_at = _datetime_text(created_at) if mark_login else None
    created = create_user_session(
        token_hash=_token_hash(token),
        user_id=user.id,
        created_at=_datetime_text(created_at),
        expires_at=_datetime_text(created_at + USER_SESSION_TTL),
        expected_auth_epoch=auth_epoch,
        expected_two_factor_enabled=two_factor_enabled,
        login_at=login_at,
        github_config_revision=github_config_revision,
        github_client_id=github_client_id,
    )
    if not created:
        raise AuthenticationStateChanged("用户认证状态已变更")
    return token


def complete_authenticated_session(
    authenticated: AuthenticatedUser,
    *,
    github_config_revision: int | None = None,
    github_client_id: str | None = None,
) -> tuple[str, UserRecord]:
    token = issue_user_session(
        authenticated.user,
        expected_auth_epoch=authenticated.auth_epoch,
        expected_two_factor_enabled=authenticated.two_factor_enabled,
        mark_login=True,
        github_config_revision=github_config_revision,
        github_client_id=github_client_id,
    )
    return token, get_user(authenticated.user.id) or authenticated.user


def read_user_session_token(request: Request) -> str:
    token = request.headers.get(USER_TOKEN_HEADER, "").strip()
    if not token or not _TOKEN_PATTERN.fullmatch(token):
        raise _user_unauthorized()
    return token


def read_user_session(request: Request) -> UserRecord:
    token = read_user_session_token(request)
    user = get_user_by_session_hash(_token_hash(token), now=_now())
    if user is None or user.status != "active":
        raise _user_unauthorized()
    from .account_maintenance import record_request_session

    record_request_session(request, _token_hash(token))
    return user


def read_user_session_hash(request: Request) -> str:
    return _token_hash(read_user_session_token(request))


def logout_user_session(request: Request) -> None:
    token = read_user_session_token(request)
    delete_user_session(_token_hash(token))


def require_user_access(request: Request) -> UserAccess:
    admin_session = read_admin_session(request)
    if admin_session is not None:
        if request.method.upper() not in {"GET", "HEAD", "OPTIONS"}:
            require_admin_write_access(request)
        return UserAccess(user=_default_admin_user(), owner_id=None, admin_view=True)
    if not multi_user_enabled():
        return UserAccess(user=_default_admin_user(), owner_id=DEFAULT_ADMIN_USER_ID)
    user = read_user_session(request)
    return UserAccess(user=user, owner_id=user.id)


def require_admin_user_access(request: Request) -> UserAccess:
    access = require_user_access(request)
    if access.user.role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="仅管理员可以修改全局服务配置",
        )
    return access


def require_multi_user_mode() -> None:
    if not multi_user_enabled():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="多用户功能未启用",
            headers=_no_store_headers(),
        )


def _default_admin_user() -> UserRecord:
    try:
        stored = get_user(DEFAULT_ADMIN_USER_ID)
    except sqlite3.OperationalError:
        stored = None
    if stored is not None:
        return stored
    return UserRecord(
        id=DEFAULT_ADMIN_USER_ID,
        username="admin",
        displayName="管理员",
        role="admin",
        status="active",
        createdAt=_now(),
    )


def _user_unauthorized() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="用户会话已失效，请重新登录",
        headers=_no_store_headers(),
    )


def _no_store_headers() -> dict[str, str]:
    return {"Cache-Control": "no-store", "Pragma": "no-cache"}


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _datetime_text(value: datetime) -> str:
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def _now() -> str:
    return _datetime_text(datetime.now(UTC))
