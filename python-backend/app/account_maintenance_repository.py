from __future__ import annotations

import hashlib
import secrets
import sqlite3
import time
from dataclasses import dataclass
from datetime import UTC, datetime


def ensure_account_maintenance_schema(conn: sqlite3.Connection) -> None:
    for statement in (
        """CREATE TABLE IF NOT EXISTS account_verified_emails (
            user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
            email_key TEXT NOT NULL, verified_at TEXT NOT NULL)""",
        """CREATE TABLE IF NOT EXISTS account_email_challenges (
            purpose TEXT NOT NULL CHECK(purpose IN ('verify','reset')),
            email_hash TEXT NOT NULL, code_hash TEXT NOT NULL,
            user_id TEXT REFERENCES users(id) ON DELETE CASCADE, auth_epoch INTEGER,
            expires_at REAL NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
            active INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(purpose,email_hash))""",
        """CREATE TABLE IF NOT EXISTS account_attempt_windows (
            key_hash TEXT PRIMARY KEY, started_at REAL NOT NULL,
            expires_at REAL NOT NULL, attempts INTEGER NOT NULL)""",
        """CREATE TABLE IF NOT EXISTS account_session_metadata (
            token_hash TEXT PRIMARY KEY REFERENCES user_sessions(token_hash) ON DELETE CASCADE,
            public_id TEXT NOT NULL UNIQUE, platform TEXT NOT NULL DEFAULT 'other',
            last_seen_at TEXT NOT NULL)""",
        "CREATE INDEX IF NOT EXISTS idx_account_windows_expiry ON account_attempt_windows(expires_at)",
    ):
        conn.execute(statement)


def _connection():
    from .db import get_connection

    return get_connection()


def _now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def mark_registration_email_verified(
    conn: sqlite3.Connection,
    user_id: str,
    email_key: str,
    code_hash: str,
) -> None:
    """Consume the validated registration code in the same transaction as user creation."""
    consumed = conn.execute(
        """DELETE FROM email_verification_codes WHERE email_key=? AND code_hash=?
           AND active=1 AND attempts_remaining>0 AND expires_at>?""",
        (email_key, code_hash, _now()),
    )
    if consumed.rowcount != 1:
        raise ValueError("邮箱验证码错误或已过期")
    conn.execute(
        "INSERT INTO account_verified_emails(user_id,email_key,verified_at) VALUES(?,?,?)",
        (user_id, email_key, _now()),
    )


def email_is_verified(user_id: str) -> bool:
    with _connection() as conn:
        return (
            conn.execute(
                """SELECT 1 FROM account_verified_emails v JOIN users u ON u.id=v.user_id
               WHERE u.id=? AND v.email_key=u.email_key""",
                (user_id,),
            ).fetchone()
            is not None
        )


def reserve_rate(key: str, *, limit: int, seconds: int) -> int | None:
    now = time.time()
    with _connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("DELETE FROM account_attempt_windows WHERE expires_at<=?", (now,))
        hashed = digest(key)
        row = conn.execute(
            "SELECT expires_at,attempts FROM account_attempt_windows WHERE key_hash=?",
            (hashed,),
        ).fetchone()
        if row and int(row[1]) >= limit:
            return max(1, int(float(row[0]) - now + 0.999))
        conn.execute(
            """INSERT INTO account_attempt_windows VALUES(?,?,?,1)
               ON CONFLICT(key_hash) DO UPDATE SET attempts=attempts+1""",
            (hashed, now, now + seconds),
        )
    return None


@dataclass(frozen=True)
class EmailChallenge:
    purpose: str
    email_hash: str
    code_hash: str
    user_id: str | None
    auth_epoch: int | None


def save_challenge(
    purpose: str, email_key: str, code_hash: str, *, user_id: str | None = None
) -> EmailChallenge:
    with _connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("DELETE FROM account_email_challenges WHERE expires_at<=?", (time.time(),))
        if purpose == "reset":
            row = conn.execute(
                """SELECT u.id,u.auth_epoch FROM users u JOIN account_verified_emails v ON v.user_id=u.id
                   WHERE u.email_key=? AND v.email_key=u.email_key AND u.status='active'""",
                (email_key,),
            ).fetchone()
        else:
            row = conn.execute(
                "SELECT id,auth_epoch FROM users WHERE id=? AND email_key=? AND status='active'",
                (user_id, email_key),
            ).fetchone()
        challenge = EmailChallenge(
            purpose, digest(email_key), code_hash, str(row[0]) if row else None, int(row[1]) if row else None
        )
        conn.execute(
            """INSERT OR REPLACE INTO account_email_challenges
               (purpose,email_hash,code_hash,user_id,auth_epoch,expires_at,attempts,active)
               VALUES(?,?,?,?,?,?,0,0)""",
            (
                purpose,
                challenge.email_hash,
                code_hash,
                challenge.user_id,
                challenge.auth_epoch,
                time.time() + 600,
            ),
        )
    return challenge


def activate_challenge(challenge: EmailChallenge) -> None:
    with _connection() as conn:
        conn.execute(
            """UPDATE account_email_challenges SET active=1
               WHERE purpose=? AND email_hash=? AND code_hash=? AND expires_at>?""",
            (challenge.purpose, challenge.email_hash, challenge.code_hash, time.time()),
        )


def discard_challenge(challenge: EmailChallenge) -> None:
    with _connection() as conn:
        conn.execute(
            "DELETE FROM account_email_challenges WHERE purpose=? AND email_hash=? AND code_hash=?",
            (challenge.purpose, challenge.email_hash, challenge.code_hash),
        )


def reserve_challenge(purpose: str, email_key: str) -> EmailChallenge | None:
    hashed = digest(email_key)
    with _connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            """SELECT code_hash,user_id,auth_epoch FROM account_email_challenges
               WHERE purpose=? AND email_hash=? AND active=1 AND attempts<5 AND expires_at>?""",
            (purpose, hashed, time.time()),
        ).fetchone()
        if row is None:
            return None
        conn.execute(
            "UPDATE account_email_challenges SET attempts=attempts+1 WHERE purpose=? AND email_hash=?",
            (purpose, hashed),
        )
    return EmailChallenge(purpose, hashed, str(row[0]), row[1], row[2])


def _consume_challenge(conn: sqlite3.Connection, challenge: EmailChallenge) -> bool:
    return (
        conn.execute(
            """DELETE FROM account_email_challenges WHERE purpose=? AND email_hash=? AND code_hash=?
           AND user_id=? AND auth_epoch=? AND expires_at>? AND active=1 AND attempts<=5""",
            (
                challenge.purpose,
                challenge.email_hash,
                challenge.code_hash,
                challenge.user_id,
                challenge.auth_epoch,
                time.time(),
            ),
        ).rowcount
        == 1
    )


def confirm_verified_email(challenge: EmailChallenge, *, email_key: str, user_id: str) -> bool:
    with _connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        state = conn.execute(
            "SELECT 1 FROM users WHERE id=? AND email_key=? AND auth_epoch=? AND status='active'",
            (user_id, email_key, challenge.auth_epoch),
        ).fetchone()
        if challenge.user_id != user_id or not state or not _consume_challenge(conn, challenge):
            return False
        conn.execute(
            "INSERT OR REPLACE INTO account_verified_emails VALUES(?,?,?)",
            (user_id, email_key, _now()),
        )
    return True


def change_password(
    user_id: str,
    password_hash: str,
    *,
    expected_auth_epoch: int,
    challenge: EmailChallenge | None = None,
    email_key: str | None = None,
) -> bool:
    with _connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        state = conn.execute(
            "SELECT 1 FROM users WHERE id=? AND status='active' AND auth_epoch=?",
            (user_id, expected_auth_epoch),
        ).fetchone()
        if not state:
            return False
        if challenge is not None:
            verified = conn.execute(
                """SELECT 1 FROM users u JOIN account_verified_emails v ON v.user_id=u.id
                   WHERE u.id=? AND u.email_key=? AND v.email_key=u.email_key""",
                (user_id, email_key),
            ).fetchone()
            if not verified or challenge.user_id != user_id or not _consume_challenge(conn, challenge):
                return False
        conn.execute(
            "UPDATE users SET password_hash=?,auth_epoch=auth_epoch+1,updated_at=? WHERE id=?",
            (password_hash, _now(), user_id),
        )
        conn.execute("DELETE FROM user_sessions WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM account_email_challenges WHERE user_id=?", (user_id,))
    return True


def record_session(token_hash: str, platform: str = "other") -> None:
    if platform not in {"android", "windows", "linux", "macos", "ios", "other"}:
        platform = "other"
    with _connection() as conn:
        conn.execute(
            """INSERT INTO account_session_metadata(token_hash,public_id,platform,last_seen_at)
               SELECT token_hash,?,?,? FROM user_sessions WHERE token_hash=? AND expires_at>?
               ON CONFLICT(token_hash) DO UPDATE SET
                 platform=CASE WHEN excluded.platform='other' THEN account_session_metadata.platform ELSE excluded.platform END,
                 last_seen_at=excluded.last_seen_at""",
            (secrets.token_urlsafe(18), platform, _now(), token_hash, _now()),
        )


def list_sessions(user_id: str, current_hash: str) -> list[dict]:
    with _connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        rows = conn.execute(
            """SELECT s.token_hash,s.created_at FROM user_sessions s JOIN users u ON u.id=s.user_id
               WHERE s.user_id=? AND s.expires_at>? AND s.auth_epoch=u.auth_epoch""",
            (user_id, _now()),
        ).fetchall()
        for token_hash, created in rows:
            conn.execute(
                "INSERT OR IGNORE INTO account_session_metadata VALUES(?,?,?,?)",
                (token_hash, secrets.token_urlsafe(18), "other", created),
            )
        sessions = conn.execute(
            """SELECT m.public_id,m.platform,s.created_at,s.expires_at,m.last_seen_at,s.token_hash
               FROM user_sessions s JOIN account_session_metadata m ON m.token_hash=s.token_hash
               JOIN users u ON u.id=s.user_id
               WHERE s.user_id=? AND s.expires_at>? AND s.auth_epoch=u.auth_epoch
               ORDER BY m.last_seen_at DESC,m.public_id""",
            (user_id, _now()),
        ).fetchall()
    return [
        dict(
            id=r[0],
            platform=r[1],
            createdAt=r[2],
            expiresAt=r[3],
            lastSeenAt=r[4],
            current=r[5] == current_hash,
        )
        for r in sessions
    ]


def revoke_session(user_id: str, public_id: str) -> bool:
    with _connection() as conn:
        return (
            conn.execute(
                """DELETE FROM user_sessions WHERE user_id=? AND token_hash=(
               SELECT token_hash FROM account_session_metadata WHERE public_id=?)""",
                (user_id, public_id),
            ).rowcount
            == 1
        )
