from __future__ import annotations

import hashlib
import secrets
import smtplib
import ssl
from contextlib import suppress
from email.message import EmailMessage
from email.utils import formataddr

from fastapi import Request

from . import account_maintenance_repository as repository
from .account_maintenance_repository import (  # noqa: F401 - public database integration hooks
    ensure_account_maintenance_schema,
    mark_registration_email_verified,
)
from .account_security import verify_second_factor_code
from .admin_auth import hash_admin_password, validate_admin_password, verify_password_hash
from .db import DEFAULT_ADMIN_USER_ID, get_user_security_state
from .device_registry import parse_request_device
from .registration import StoredRegistrationSettings, load_registration_settings, normalize_email
from .user_auth import verify_current_user_password_state

CODE_TTL_SECONDS = 600
RESEND_SECONDS = 60
_DUMMY_CODE_HASH = (
    "pbkdf2_sha256:150000:6163636f756e742d6d61696c2d636f6465:"
    "840efab8ca81c4bc3f892b9ffad9f325023f7798bc918f0c270636f5484f67e4"
)


class MaintenanceError(ValueError):
    pass


class MaintenanceRateLimited(MaintenanceError):
    def __init__(self, retry_after: int):
        super().__init__("操作过于频繁，请稍后再试")
        self.retry_after = retry_after


def check_rate(key: str, *, limit: int, seconds: int) -> None:
    wait = repository.reserve_rate(key, limit=limit, seconds=seconds)
    if wait is not None:
        raise MaintenanceRateLimited(wait)


def confirm_password(user_id: str, password: str, code: str | None):
    check_rate(f"reauth:{user_id}", limit=5, seconds=300)
    state = verify_current_user_password_state(user_id, password)
    if state is None or (state.totp_secret_encrypted and not verify_second_factor_code(user_id, code or "")):
        raise MaintenanceError("密码、动态验证码或恢复码不正确")
    return state


def update_password(user_id: str, password: str, replacement: str, code: str | None) -> None:
    if user_id == DEFAULT_ADMIN_USER_ID:
        raise MaintenanceError("默认管理员密码请使用 qingjuan-password 修改")
    validate_admin_password(replacement)
    state = confirm_password(user_id, password, code)
    password_hash = hash_admin_password(replacement)
    if not repository.change_password(user_id, password_hash, expected_auth_epoch=state.auth_epoch):
        raise MaintenanceError("账号状态已变更，请重新登录后再试")


def prepare_email_challenge(purpose: str, email: str, *, user_id: str | None = None):
    normalized, key = normalize_email(email)
    check_rate(f"email:{purpose}:{key}", limit=1, seconds=RESEND_SECONDS)
    check_rate(f"email-hour:{purpose}:{key}", limit=5, seconds=3600)
    code = f"{secrets.randbelow(100_000_000):08d}"
    salt = secrets.token_bytes(16)
    hashed = hashlib.pbkdf2_hmac("sha256", code.encode(), salt, 150_000)
    code_hash = f"pbkdf2_sha256:150000:{salt.hex()}:{hashed.hex()}"
    challenge = repository.save_challenge(purpose, key, code_hash, user_id=user_id)
    return challenge, normalized, code


def deliver_email_challenge(challenge: repository.EmailChallenge, recipient: str, code: str) -> None:
    # Queued identically for known and unknown accounts; errors never alter the public response.
    if challenge.user_id is None:
        return
    try:
        settings = load_registration_settings()
        if not settings.smtp_configured:
            return
        send_account_email(settings, recipient=recipient, code=code, purpose=challenge.purpose)
        repository.activate_challenge(challenge)
    except Exception:
        # An inactive row cannot validate and will expire automatically.
        with suppress(Exception):
            repository.discard_challenge(challenge)


def verify_mailbox_code(purpose: str, email_key: str, code: str) -> repository.EmailChallenge:
    challenge = repository.reserve_challenge(purpose, email_key)
    valid = verify_password_hash(code, challenge.code_hash if challenge else _DUMMY_CODE_HASH)
    if challenge is None or not valid or challenge.user_id is None:
        raise MaintenanceError("验证信息错误或已过期，请重新获取验证码")
    return challenge


def verify_own_email(user_id: str, email: str, code: str) -> None:
    _, key = normalize_email(email)
    challenge = verify_mailbox_code("verify", key, code)
    if not repository.confirm_verified_email(challenge, email_key=key, user_id=user_id):
        raise MaintenanceError("验证信息错误或已过期，请重新获取验证码")


def reset_password(email: str, email_code: str, replacement: str, code: str | None) -> None:
    validate_admin_password(replacement)
    _, key = normalize_email(email)
    challenge = verify_mailbox_code("reset", key, email_code)
    state = get_user_security_state(challenge.user_id)
    if (
        state is None
        or state.user.status != "active"
        or state.auth_epoch != challenge.auth_epoch
    ):
        raise MaintenanceError("验证信息错误或已过期，请重新获取验证码")
    if state.user.id == DEFAULT_ADMIN_USER_ID:
        raise MaintenanceError("默认管理员密码请使用 qingjuan-password 修改")
    if state.totp_secret_encrypted and not verify_second_factor_code(state.user.id, code or ""):
        raise MaintenanceError("验证信息错误或已过期，请重新获取验证码")
    password_hash = hash_admin_password(replacement)
    if not repository.change_password(
        state.user.id, password_hash, expected_auth_epoch=state.auth_epoch, challenge=challenge, email_key=key
    ):
        raise MaintenanceError("验证信息错误或已过期，请重新获取验证码")


def record_request_session(request: Request, token_hash: str) -> None:
    device = parse_request_device(request)
    repository.record_session(token_hash, device.platform if device else "other")


def send_account_email(
    settings: StoredRegistrationSettings, *, recipient: str, code: str, purpose: str
) -> None:
    action = "找回密码" if purpose == "reset" else "验证邮箱"
    message = EmailMessage()
    message["Subject"] = f"青卷{action}验证码"
    message["From"] = formataddr((settings.smtp_from_name, settings.smtp_from_address))
    message["To"] = recipient
    message.set_content(
        f"您的青卷{action}验证码是：{code}\n\n验证码 10 分钟内有效。"
        "已启用两步验证的账号仍需验证器代码或恢复码。\n如非本人操作，请忽略此邮件。"
    )
    context = ssl.create_default_context()
    if settings.smtp_security == "ssl":
        with smtplib.SMTP_SSL(settings.smtp_host, settings.smtp_port, timeout=15, context=context) as client:
            _deliver(client, settings, message)
    else:
        with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=15) as client:
            client.ehlo()
            if settings.smtp_security == "starttls":
                client.starttls(context=context)
                client.ehlo()
            _deliver(client, settings, message)


def _deliver(client, settings: StoredRegistrationSettings, message: EmailMessage):
    if settings.smtp_username:
        client.login(settings.smtp_username, settings.smtp_password)
    client.send_message(message)
