from __future__ import annotations

import sqlite3
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


def read_packages() -> list[tuple]:
    from .. import db

    with db.get_connection() as conn:
        return conn.execute(
            "SELECT plugin_id, manifest_json, package, sha256 FROM site_plugin_packages ORDER BY plugin_id"
        ).fetchall()


def save_package(plugin_id: str, manifest_json: str, package: bytes, digest: str, enabled: bool) -> None:
    from .. import db

    now = datetime.now(UTC).isoformat().replace("+00:00", "Z")
    with db.get_connection() as conn:
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
    db.invalidate_site_plugin_states()


def delete_package(plugin_id: str) -> None:
    from .. import db

    with db.get_connection() as conn:
        conn.execute("DELETE FROM site_plugin_packages WHERE plugin_id = ?", (plugin_id,))
        conn.execute("DELETE FROM site_plugin_settings WHERE plugin_id = ?", (plugin_id,))
    db.invalidate_site_plugin_states()
