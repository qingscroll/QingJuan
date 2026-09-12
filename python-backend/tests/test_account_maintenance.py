from __future__ import annotations

import hashlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import account_maintenance as maintenance
from app import db
from app.account_maintenance import send_account_email as deliver_account_email
from app.admin_auth import hash_admin_password
from app.api.account_maintenance import router
from app.api.auth import router as auth_router
from app.application import create_application
from app.security import API_PREFIX
from app.two_factor import TWO_FACTOR_ENCRYPTION_KEY_ENV, encrypt_totp_secret
from app.user_auth import issue_user_session, verify_current_user_password

PASSWORD = "existing-password-123"
NEW_PASSWORD = "replacement-password-456"


@pytest.fixture
def database(monkeypatch: pytest.MonkeyPatch, tmp_path: Path):
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "1")
    monkeypatch.setenv(TWO_FACTOR_ENCRYPTION_KEY_ENV, "33" * 32)
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "account.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    monkeypatch.setattr(db, "_SITE_PLUGIN_STATE_CACHE", None)
    db.init_db()
    with db.get_connection() as conn:
        maintenance.ensure_account_maintenance_schema(conn)
        conn.execute(
            "UPDATE registration_settings SET smtp_host='smtp.example.test', smtp_from_address='sender@example.test'"
        )
    for name in ("alice", "bob"):
        db.create_user(
            user_id=name,
            username=name,
            username_key=name,
            email=f"{name}@example.test",
            email_key=f"{name}@example.test",
            display_name=name,
            password_hash=hash_admin_password(PASSWORD, iterations=100_000),
        )
    sent = []
    monkeypatch.setattr(maintenance, "send_account_email", lambda settings, **kw: sent.append(kw))
    return sent


def _client():
    # Mount separately so the feature remains testable before shared router integration.
    from fastapi import APIRouter

    root = APIRouter(prefix="/auth")
    root.include_router(router)
    return TestClient(create_application(routers=[auth_router, root], api_prefix=API_PREFIX))


def _headers(name="alice"):
    user = db.get_user(name)
    assert user is not None
    return {"X-QingJuan-User-Token": issue_user_session(user)}


def _verified(name="alice"):
    with db.get_connection() as conn:
        conn.execute(
            "INSERT INTO account_verified_emails VALUES (?, ?, ?)",
            (name, f"{name}@example.test", "2026-01-01T00:00:00Z"),
        )


def test_password_change_checks_password_and_revokes_every_session(database):
    first, second = _headers(), _headers()
    with _client() as client:
        wrong = client.post(
            f"{API_PREFIX}/auth/account/password",
            headers=first,
            json={"currentPassword": "wrong", "newPassword": NEW_PASSWORD},
        )
        assert wrong.status_code == 403
        assert verify_current_user_password("alice", PASSWORD)
        changed = client.post(
            f"{API_PREFIX}/auth/account/password",
            headers=first,
            json={"currentPassword": PASSWORD, "newPassword": NEW_PASSWORD},
        )
        assert changed.status_code == 204, changed.text
        assert changed.headers["cache-control"] == "no-store"
        assert verify_current_user_password("alice", NEW_PASSWORD)
        for headers in (first, second):
            assert client.get(f"{API_PREFIX}/auth/session", headers=headers).status_code == 401


def test_default_admin_password_change_does_not_report_temporary_success(database, monkeypatch):
    monkeypatch.setenv("QINGJUAN_ADMIN_PASSWORD_HASH", hash_admin_password(PASSWORD, iterations=100_000))
    db.init_db()
    headers = _headers(db.DEFAULT_ADMIN_USER_ID)
    with _client() as client:
        response = client.post(
            f"{API_PREFIX}/auth/account/password",
            headers=headers,
            json={"currentPassword": PASSWORD, "newPassword": NEW_PASSWORD},
        )
        assert response.status_code == 403
        assert "qingjuan-password" in response.json()["detail"]
        assert verify_current_user_password(db.DEFAULT_ADMIN_USER_ID, PASSWORD)
        assert not verify_current_user_password(db.DEFAULT_ADMIN_USER_ID, NEW_PASSWORD)
        db.init_db()
        assert verify_current_user_password(db.DEFAULT_ADMIN_USER_ID, PASSWORD)
        assert client.get(f"{API_PREFIX}/auth/session", headers=headers).status_code == 200


def test_default_admin_email_reset_also_requires_deployment_password_command(database, monkeypatch):
    from app.account_security import generate_recovery_code_material

    monkeypatch.setenv("QINGJUAN_ADMIN_PASSWORD_HASH", hash_admin_password(PASSWORD, iterations=100_000))
    db.init_db()
    admin_id = db.DEFAULT_ADMIN_USER_ID
    with db.get_connection() as conn:
        conn.execute("UPDATE users SET email=?,email_key=? WHERE id=?",
                     (f"{admin_id}@example.test", f"{admin_id}@example.test", admin_id))
    _verified(admin_id)
    codes, hashes = generate_recovery_code_material()
    db.enable_user_two_factor(
        admin_id, encrypted_secret=encrypt_totp_secret("JBSWY3DPEHPK3PXP"),
        accepted_counter=0, recovery_code_hashes=hashes,
        keep_session_hash=None, expected_auth_epoch=db.get_user_security_state(admin_id).auth_epoch,
    )
    with _client() as client:
        client.post(f"{API_PREFIX}/auth/password-reset/request", json={"email": f"{admin_id}@example.test"})
        response = client.post(f"{API_PREFIX}/auth/password-reset/confirm", json={
            "email": f"{admin_id}@example.test", "emailCode": database[-1]["code"], "newPassword": NEW_PASSWORD,
            "code": codes[0],
        })
        assert response.status_code == 400
        assert "qingjuan-password" in response.json()["detail"]
    assert verify_current_user_password(admin_id, PASSWORD)
    assert db.count_user_recovery_codes(admin_id) == len(codes)


def test_old_email_requires_explicit_verification_then_can_reset(database):
    headers = _headers()
    with _client() as client:
        result = client.get(f"{API_PREFIX}/auth/account/maintenance", headers=headers)
        assert result.json()["emailVerified"] is False
        request = client.post(
            f"{API_PREFIX}/auth/account/email-verification/request",
            headers=headers,
            json={"password": PASSWORD},
        )
        assert request.status_code == 202, request.text
        code = database[-1]["code"]
        assert database[-1]["purpose"] == "verify"
        result = client.post(
            f"{API_PREFIX}/auth/account/email-verification/confirm", headers=headers, json={"emailCode": code}
        )
        assert result.status_code == 204, result.text
        assert (
            client.get(f"{API_PREFIX}/auth/account/maintenance", headers=headers).json()["emailVerified"]
            is True
        )
        repeat = client.post(
            f"{API_PREFIX}/auth/account/email-verification/confirm", headers=headers, json={"emailCode": code}
        )
        assert repeat.status_code == 400


def test_reset_non_enumeration_and_single_use(database):
    _verified()
    session = _headers()
    with _client() as client:
        responses = [
            client.post(f"{API_PREFIX}/auth/password-reset/request", json={"email": address})
            for address in ("alice@example.test", "bob@example.test", "absent@example.test")
        ]
        assert all(response.status_code == 202 for response in responses)
        assert all(response.json() == responses[0].json() for response in responses)
        assert len(database) == 1
        code = database[0]["code"]
        assert code not in str(responses[0].json())
        with db.get_connection() as conn:
            stored = conn.execute("SELECT code_hash FROM account_email_challenges").fetchall()
        assert all(code not in value[0] for value in stored)
        payload = {"email": "alice@example.test", "emailCode": code, "newPassword": NEW_PASSWORD}
        reset = client.post(f"{API_PREFIX}/auth/password-reset/confirm", json=payload)
        assert reset.status_code == 204, reset.text
        assert verify_current_user_password("alice", NEW_PASSWORD)
        assert client.get(f"{API_PREFIX}/auth/session", headers=session).status_code == 401
        assert client.post(f"{API_PREFIX}/auth/password-reset/confirm", json=payload).status_code == 400


def test_reset_never_disables_or_bypasses_two_factor(database):
    _verified()
    from app.account_security import generate_recovery_code_material

    codes, hashes = generate_recovery_code_material()
    db.enable_user_two_factor(
        "alice",
        encrypted_secret=encrypt_totp_secret("JBSWY3DPEHPK3PXP"),
        accepted_counter=0,
        recovery_code_hashes=hashes,
        keep_session_hash=None,
        expected_auth_epoch=0,
    )
    with _client() as client:
        client.post(f"{API_PREFIX}/auth/password-reset/request", json={"email": "alice@example.test"})
        payload = {
            "email": "alice@example.test",
            "emailCode": database[0]["code"],
            "newPassword": NEW_PASSWORD,
        }
        assert client.post(f"{API_PREFIX}/auth/password-reset/confirm", json=payload).status_code == 400
        assert verify_current_user_password("alice", PASSWORD)
        result = client.post(f"{API_PREFIX}/auth/password-reset/confirm", json={**payload, "code": codes[0]})
        assert result.status_code == 204, result.text
        assert db.get_user_security_state("alice").totp_secret_encrypted is not None
        login = client.post(f"{API_PREFIX}/auth/login", json={"username": "alice", "password": NEW_PASSWORD})
        assert login.json()["requiresTwoFactor"] is True


def test_reset_attempt_limit_and_resend_limit_persist_across_clients(database):
    _verified()
    with _client() as client:
        assert (
            client.post(
                f"{API_PREFIX}/auth/password-reset/request", json={"email": "alice@example.test"}
            ).status_code
            == 202
        )
        code = database[0]["code"]
        for _ in range(5):
            response = client.post(
                f"{API_PREFIX}/auth/password-reset/confirm",
                json={"email": "alice@example.test", "emailCode": "wrong-code", "newPassword": NEW_PASSWORD},
            )
            assert response.status_code == 400
    with _client() as client:
        response = client.post(
            f"{API_PREFIX}/auth/password-reset/confirm",
            json={"email": "alice@example.test", "emailCode": code, "newPassword": NEW_PASSWORD},
        )
        assert response.status_code == 400
        assert (
            client.post(
                f"{API_PREFIX}/auth/password-reset/request", json={"email": "alice@example.test"}
            ).status_code
            == 429
        )


def test_expired_or_epoch_changed_reset_cannot_mutate_password(database):
    _verified()
    with _client() as client:
        client.post(f"{API_PREFIX}/auth/password-reset/request", json={"email": "alice@example.test"})
        payload = {
            "email": "alice@example.test",
            "emailCode": database[0]["code"],
            "newPassword": NEW_PASSWORD,
        }
        with db.get_connection() as conn:
            conn.execute("UPDATE account_email_challenges SET expires_at = 0")
        assert client.post(f"{API_PREFIX}/auth/password-reset/confirm", json=payload).status_code == 400
    assert verify_current_user_password("alice", PASSWORD)


def test_sessions_are_owner_scoped_and_never_expose_tokens(database):
    first, second, other = _headers(), _headers(), _headers("bob")
    with _client() as client:
        result = client.get(f"{API_PREFIX}/auth/account/sessions", headers=first)
        assert result.status_code == 200, result.text
        sessions = result.json()["sessions"]
        assert len(sessions) == 2 and sum(item["current"] for item in sessions) == 1
        for item in sessions:
            assert set(item) == {"id", "platform", "createdAt", "expiresAt", "lastSeenAt", "current"}
        assert first["X-QingJuan-User-Token"] not in result.text
        assert hashlib.sha256(first["X-QingJuan-User-Token"].encode()).hexdigest() not in result.text
        other_session = client.get(f"{API_PREFIX}/auth/account/sessions", headers=other).json()["sessions"][0]
        assert (
            client.delete(
                f"{API_PREFIX}/auth/account/sessions/{other_session['id']}", headers=first
            ).status_code
            == 404
        )
        target = next(item for item in sessions if not item["current"])
        assert (
            client.delete(f"{API_PREFIX}/auth/account/sessions/{target['id']}", headers=first).status_code
            == 204
        )
        assert client.get(f"{API_PREFIX}/auth/session", headers=second).status_code == 401
        assert client.get(f"{API_PREFIX}/auth/session", headers=first).status_code == 200


def test_failed_mail_does_not_reveal_account_or_leave_usable_challenge(database, monkeypatch):
    _verified()

    def fail(*args, **kwargs):
        raise RuntimeError("smtp-secret-do-not-expose")

    monkeypatch.setattr(maintenance, "send_account_email", fail)
    with _client() as client:
        known = client.post(f"{API_PREFIX}/auth/password-reset/request", json={"email": "alice@example.test"})
        unknown = client.post(
            f"{API_PREFIX}/auth/password-reset/request", json={"email": "missing@example.test"}
        )
        assert known.status_code == unknown.status_code == 202
        assert known.json() == unknown.json()
        with db.get_connection() as conn:
            assert not conn.execute("SELECT 1 FROM account_email_challenges WHERE active=1").fetchone()


def test_single_user_mode_hides_all_maintenance_routes(database, monkeypatch):
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "0")
    with _client() as client:
        assert client.get(f"{API_PREFIX}/auth/account/maintenance").status_code == 404
        assert (
            client.post(
                f"{API_PREFIX}/auth/password-reset/request", json={"email": "alice@example.test"}
            ).status_code
            == 404
        )


def test_concurrent_reset_consumes_one_code_and_rejects_stale_auth_epoch(database):
    _verified()
    challenge, recipient, code = maintenance.prepare_email_challenge("reset", "alice@example.test")
    maintenance.deliver_email_challenge(challenge, recipient, code)

    def reset():
        try:
            maintenance.reset_password(recipient, code, NEW_PASSWORD, None)
            return True
        except maintenance.MaintenanceError:
            return False

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(lambda _: reset(), range(2))) == [False, True]
    from app import account_maintenance_repository as repository

    assert not repository.change_password("alice", hash_admin_password(PASSWORD), expected_auth_epoch=0)
    assert verify_current_user_password("alice", NEW_PASSWORD)


def test_password_change_requires_enabled_second_factor(database):
    from app.account_security import generate_recovery_code_material

    codes, hashes = generate_recovery_code_material()
    db.enable_user_two_factor(
        "alice",
        encrypted_secret=encrypt_totp_secret("JBSWY3DPEHPK3PXP"),
        accepted_counter=0,
        recovery_code_hashes=hashes,
        keep_session_hash=None,
        expected_auth_epoch=0,
    )
    headers = _headers()
    with _client() as client:
        payload = {"currentPassword": PASSWORD, "newPassword": NEW_PASSWORD}
        assert (
            client.post(f"{API_PREFIX}/auth/account/password", headers=headers, json=payload).status_code
            == 403
        )
        assert (
            client.post(
                f"{API_PREFIX}/auth/account/password", headers=headers, json={**payload, "code": codes[0]}
            ).status_code
            == 204
        )
    assert db.get_user_security_state("alice").totp_secret_encrypted is not None
    assert db.count_user_recovery_codes("alice") == len(codes) - 1


def test_registration_verification_marker_and_code_consumption_are_atomic(database):
    from app.registration import activate_email_code, reserve_email_code

    email_key = "carol@example.test"
    code_hash = reserve_email_code(email_key, "123456")
    activate_email_code(email_key, code_hash)
    user = db.create_user(
        user_id="carol",
        username="carol",
        username_key="carol",
        email=email_key,
        email_key=email_key,
        display_name="Carol",
        password_hash=hash_admin_password(PASSWORD),
        email_verification_code_hash=code_hash,
    )
    from app import account_maintenance_repository as repository

    assert repository.email_is_verified(user.id)
    with db.get_connection() as conn:
        assert not conn.execute(
            "SELECT 1 FROM email_verification_codes WHERE email_key=?", (email_key,)
        ).fetchone()
    with pytest.raises(ValueError):
        db.create_user(
            user_id="dora",
            username="dora",
            username_key="dora",
            email="dora@example.test",
            email_key="dora@example.test",
            display_name="Dora",
            password_hash=hash_admin_password(PASSWORD),
            email_verification_code_hash=code_hash,
        )
    assert db.get_user("dora") is None


def test_session_platform_metadata_is_limited_and_schema_upgrade_is_repeatable(database):
    headers = {
        **_headers(),
        "X-QingJuan-Device-ID": "a" * 32,
        "X-QingJuan-Device-Platform": "windows",
        "X-QingJuan-Device-Name": "private-hostname",
    }
    with db.get_connection() as conn:
        maintenance.ensure_account_maintenance_schema(conn)
        maintenance.ensure_account_maintenance_schema(conn)
    with _client() as client:
        result = client.get(f"{API_PREFIX}/auth/account/sessions", headers=headers)
        assert result.status_code == 200
        assert result.json()["sessions"][0]["platform"] == "windows"
        assert "private-hostname" not in result.text
        assert "a" * 32 not in result.text


def test_unknown_email_confirm_still_performs_password_hash_work(database, monkeypatch):
    performed = []
    original = maintenance.verify_password_hash

    def check(candidate, digest):
        performed.append(True)
        return original(candidate, digest)

    monkeypatch.setattr(maintenance, "verify_password_hash", check)
    with pytest.raises(maintenance.MaintenanceError):
        maintenance.reset_password("missing@example.test", "00000000", NEW_PASSWORD, None)
    assert performed == [True]


def test_reset_code_is_invalid_after_security_epoch_change(database):
    _verified()
    challenge, recipient, code = maintenance.prepare_email_challenge("reset", "alice@example.test")
    maintenance.deliver_email_challenge(challenge, recipient, code)
    db.revoke_user_sessions("alice")
    with pytest.raises(maintenance.MaintenanceError):
        maintenance.reset_password(recipient, code, NEW_PASSWORD, None)
    assert verify_current_user_password("alice", PASSWORD)


def test_email_send_rate_limit_survives_app_restart_for_unknown_accounts(database):
    with _client() as client:
        for number in range(10):
            assert (
                client.post(
                    f"{API_PREFIX}/auth/password-reset/request",
                    json={"email": f"missing{number}@example.test"},
                ).status_code
                == 202
            )
    with _client() as client:
        response = client.post(
            f"{API_PREFIX}/auth/password-reset/request", json={"email": "another@example.test"}
        )
        assert response.status_code == 429
        assert int(response.headers["retry-after"]) > 0
    with db.get_connection() as conn:
        stored_keys = str(conn.execute("SELECT key_hash FROM account_attempt_windows").fetchall())
    assert "example.test" not in stored_keys and "testclient" not in stored_keys


def test_mail_uses_configured_smtp_with_tls_and_no_real_delivery(database, monkeypatch):
    from dataclasses import replace

    from app.registration import load_registration_settings

    events = []

    class SMTP:
        def __init__(self, host, port, *, timeout):
            assert host == "smtp.example.test" and port == 587 and timeout == 15

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def ehlo(self):
            events.append("ehlo")

        def starttls(self, *, context):
            assert context.check_hostname
            events.append("tls")

        def login(self, username, password):
            assert username == "sender" and password == "local-test-secret"
            events.append("login")

        def send_message(self, message):
            assert message["To"] == "reader@example.test"
            assert message["Subject"] == "青卷找回密码验证码"
            assert "12345678" in message.get_content()
            assert "local-test-secret" not in message.as_string()
            events.append("send")

    monkeypatch.setattr(maintenance.smtplib, "SMTP", SMTP)
    settings = replace(
        load_registration_settings(), smtp_username="sender", smtp_password="local-test-secret"
    )
    deliver_account_email(settings, recipient="reader@example.test", code="12345678", purpose="reset")
    assert events == ["ehlo", "tls", "ehlo", "login", "send"]
