from __future__ import annotations

import sqlite3
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime


def create_schema(conn: sqlite3.Connection) -> None:
    conn.execute("""
        CREATE TABLE IF NOT EXISTS site_plugin_packages (
            plugin_id TEXT PRIMARY KEY,
            manifest_json TEXT NOT NULL,
            package BLOB NOT NULL,
            sha256 TEXT NOT NULL,
            installed_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS site_plugin_package_history (
            plugin_id TEXT PRIMARY KEY REFERENCES site_plugin_packages(plugin_id) ON DELETE CASCADE,
            manifest_json TEXT NOT NULL,
            package BLOB NOT NULL,
            sha256 TEXT NOT NULL,
            saved_at TEXT NOT NULL
        )
    """)


@dataclass(frozen=True)
class StoredPackage:
    plugin_id: str
    manifest_json: str
    package: bytes
    sha256: str


def read_package(plugin_id: str, *, previous: bool = False) -> StoredPackage | None:
    from .. import db

    table = "site_plugin_package_history" if previous else "site_plugin_packages"
    with db.get_connection() as conn:
        row = conn.execute(
            f"SELECT plugin_id, manifest_json, package, sha256 FROM {table} WHERE plugin_id=?", (plugin_id,)
        ).fetchone()
    return StoredPackage(*row) if row else None


def read_packages() -> list[tuple]:
    from .. import db

    with db.get_connection() as conn:
        return conn.execute(
            "SELECT plugin_id, manifest_json, package, sha256 FROM site_plugin_packages ORDER BY plugin_id"
        ).fetchall()


def save_package(
    plugin_id: str,
    manifest_json: str,
    package: bytes,
    digest: str,
    enabled: bool,
    *,
    publish: Callable[[], None] | None = None,
) -> None:
    from .. import db

    now = datetime.now(UTC).isoformat().replace("+00:00", "Z")
    with db.get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        current = conn.execute(
            "SELECT manifest_json, package, sha256 FROM site_plugin_packages WHERE plugin_id=?", (plugin_id,)
        ).fetchone()
        if current is not None and current[2] != digest:
            conn.execute(
                """INSERT INTO site_plugin_package_history VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(plugin_id) DO UPDATE SET manifest_json=excluded.manifest_json,
                    package=excluded.package, sha256=excluded.sha256, saved_at=excluded.saved_at""",
                (plugin_id, current[0], current[1], current[2], now),
            )
        conn.execute(
            """
            INSERT INTO site_plugin_packages VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(plugin_id) DO UPDATE SET
                manifest_json = excluded.manifest_json, package = excluded.package,
                sha256 = excluded.sha256, updated_at = excluded.updated_at
        """,
            (plugin_id, manifest_json, package, digest, now, now),
        )
        conn.execute(
            """
            INSERT INTO site_plugin_settings (plugin_id, enabled, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(plugin_id) DO NOTHING
        """,
            (plugin_id, int(enabled), now),
        )
        if publish is not None:
            publish()
    db.invalidate_site_plugin_states()


def delete_package(plugin_id: str, *, publish: Callable[[], None] | None = None) -> None:
    from .. import db

    with db.get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("DELETE FROM site_plugin_packages WHERE plugin_id = ?", (plugin_id,))
        conn.execute("DELETE FROM site_plugin_settings WHERE plugin_id = ?", (plugin_id,))
        if publish is not None:
            publish()
    db.invalidate_site_plugin_states()
