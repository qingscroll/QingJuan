from __future__ import annotations

import json
import os
import shutil
import sqlite3
import sys
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

from .admin_auth import configured_admin_password_hash
from .models import (
    AdminUserRecord,
    BookRecord,
    BookSourceRecord,
    ComicSourceConfig,
    DeviceRecord,
    DeviceView,
    MangaOcrConfig,
    OpenAICompatibleConfig,
    ReadingProgressRecord,
    TaskLogRecord,
    TaskRecord,
    TranslationSettings,
    UserRecord,
)
from .multi_user import DEFAULT_ADMIN_USER_ID
from .plugin_system.repository import create_schema as create_plugin_package_schema
from .site_plugins import get_site_plugin, list_site_plugins

BASE_DIR = Path(__file__).resolve().parent.parent
LEGACY_DATA_DIR = BASE_DIR / "data"
APP_DIR_NAME = "QingJuan"


@dataclass(frozen=True, slots=True)
class UserSecurityState:
    user: UserRecord
    password_hash: str
    github_user_id: str | None
    github_login: str | None
    totp_secret_encrypted: str | None
    totp_last_counter: int | None
    auth_epoch: int


class AuthenticationStateConflict(RuntimeError):
    pass


class GitHubConfigurationConflict(RuntimeError):
    pass


def _resolve_platform_data_dirs() -> list[Path]:
    candidates: list[Path] = []
    if os.name == "nt":
        for env_name in ("LOCALAPPDATA", "APPDATA"):
            base = os.getenv(env_name, "").strip()
            if base:
                candidates.append((Path(base) / APP_DIR_NAME / "data").resolve())
    else:
        xdg_data_home = os.getenv("XDG_DATA_HOME", "").strip()
        if xdg_data_home:
            candidates.append((Path(xdg_data_home) / "qingjuan").resolve())
        candidates.append((Path.home() / ".local" / "share" / "qingjuan").resolve())
    return candidates


def _resolve_default_data_dir() -> Path:
    if getattr(sys, "frozen", False):
        return (Path(sys.executable).resolve().parent / "data").resolve()
    return LEGACY_DATA_DIR.resolve()


def _resolve_data_dir() -> Path:
    override = os.getenv("QINGJUAN_DATA_DIR", "").strip()
    if override:
        return Path(override).expanduser().resolve()
    return _resolve_default_data_dir()


DATA_DIR = _resolve_data_dir()
DB_PATH = DATA_DIR / "qingjuan.db"
_DATA_DIR_READY = False
_SITE_PLUGIN_STATE_LOCK = threading.RLock()
_SITE_PLUGIN_STATE_CACHE: tuple[Path, dict[str, bool]] | None = None

DEFAULT_SETTINGS = TranslationSettings(
    autoTranslateNextChapters=0,
    translationModel=OpenAICompatibleConfig(
        enabled=False,
        baseUrl="https://api.openai.com/v1",
        model="gpt-5.4",
        supportsVision=False,
    ),
    # 默认使用本机 Windows 系统 OCR（离线、免外部服务）；密钥留空即用默认语言优先级。
    mangaOcr=MangaOcrConfig(enabled=True, baseUrl="windows"),
    bika=ComicSourceConfig(),
)

DEFAULT_BOOK_SOURCES = [
    BookSourceRecord(
        id="source-builtin-fanqie",
        name="番茄小说",
        baseUrl="https://fanqienovel.com",
        description="番茄中文网络小说，可搜索、按作品链接导入或同步当前登录账号书架。",
        bookKind="长小说",
        language="中文",
        sampleUrl="https://fanqienovel.com",
        tags=["中文", "连载", "账号书架"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-qidian",
        name="起点中文网",
        baseUrl="https://www.qidian.com",
        description="可匿名搜索并导入起点作品、完整目录和可取得的章节正文，也可同步当前登录账号书架。",
        bookKind="长小说",
        language="中文",
        sampleUrl="https://www.qidian.com/book/1209977/",
        tags=["中文", "匿名搜索", "账号书架"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-biqvge",
        name="笔趣阁",
        baseUrl="https://www.b520.cc",
        description=(
            "聚合八零小说网、笔趣阁 5200 与笔趣看：八零自动发现最新搜索入口；"
            "镜像站使用目录索引，b520 目录可能不完整，笔趣看可能受区域限制。"
        ),
        bookKind="长小说",
        language="中文",
        sampleUrl="https://www.b520.cc/2_2157/",
        tags=["中文", "动态搜索", "镜像目录索引"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-ciweimao",
        name="刺猬猫阅读",
        baseUrl="https://www.ciweimao.com",
        description="可搜索并导入刺猬猫作品、完整分卷目录和可取得的章节正文。",
        bookKind="轻小说",
        language="中文",
        sampleUrl="https://www.ciweimao.com/book/100495948",
        tags=["中文", "轻小说", "章节解析"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-sfacg",
        name="SF 轻小说",
        baseUrl="https://book.sfacg.com",
        description="可搜索并导入菠萝包/SF 轻小说作品、完整目录和可取得的章节正文。",
        bookKind="轻小说",
        language="中文",
        sampleUrl="https://book.sfacg.com/Novel/465469/",
        tags=["中文", "轻小说", "菠萝包"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-shaoniandream",
        name="少年梦阅读",
        baseUrl="https://www.shaoniandream.com",
        description="可搜索并导入少年梦作品、完整分卷目录和可取得的章节正文。",
        bookKind="长小说",
        language="中文",
        sampleUrl="https://www.shaoniandream.com/book_detail/3490",
        tags=["中文", "原创小说", "章节解析"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-linovelib",
        name="Linovelib",
        baseUrl="https://www.linovelib.com",
        description="轻小说文库站点，适合轻小说与插图内容导入。",
        bookKind="轻小说",
        language="日文",
        sampleUrl="https://www.linovelib.com",
        tags=["轻小说", "插图"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-kakuyomu",
        name="Kakuyomu",
        baseUrl="https://kakuyomu.jp",
        description="角川旗下小说平台，适合在线轻小说与原创长篇导入。",
        bookKind="轻小说",
        language="日文",
        sampleUrl="https://kakuyomu.jp",
        tags=["轻小说", "连载"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-syosetu",
        name="Syosetu",
        baseUrl="https://syosetu.com",
        description="小説家になろう系列站点，适合日文网络小说导入。",
        bookKind="长小说",
        language="日文",
        sampleUrl="https://syosetu.com",
        tags=["网络小说", "日文"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-novel18",
        name="Novel18",
        baseUrl="https://novel18.syosetu.com",
        description="成人向小说站点，适合已成年用户按作品链接导入。",
        bookKind="长小说",
        language="日文",
        sampleUrl="https://novel18.syosetu.com",
        tags=["R18", "小说"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-pixiv",
        name="Pixiv Novels",
        baseUrl="https://www.pixiv.net",
        description="Pixiv 小说与系列作品入口，适合按 series / novel 链接导入。",
        bookKind="长小说",
        language="日文",
        sampleUrl="https://www.pixiv.net/novel",
        tags=["Pixiv", "系列"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-hameln",
        name="Hameln",
        baseUrl="https://syosetu.org",
        description="同人小说站点，部分环境可能触发挑战页，导入前建议先做检测。",
        bookKind="长小说",
        language="日文",
        sampleUrl="https://syosetu.org",
        tags=["同人", "小说"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-alphapolis",
        name="Alphapolis",
        baseUrl="https://www.alphapolis.co.jp",
        description="综合小说平台，当前部分环境会触发 WAF，建议先检测再导入。",
        bookKind="长小说",
        language="日文",
        sampleUrl="https://www.alphapolis.co.jp",
        tags=["网站", "小说"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-novelup",
        name="Novelup",
        baseUrl="https://novelup.plus",
        description="小说投稿平台，当前环境下可能受 CloudFront 限制。",
        bookKind="长小说",
        language="日文",
        sampleUrl="https://novelup.plus",
        tags=["投稿", "小说"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-18comic",
        name="18Comic",
        baseUrl="https://18comic.vip",
        description="支持输入禁漫本子号或专辑链接，获取章节与还原后的漫画图片并加入书架。",
        bookKind="漫画",
        language="中文",
        sampleUrl="https://18comic.vip",
        tags=["漫画", "站点"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-ehentai",
        name="E-Hentai",
        baseUrl="https://e-hentai.org",
        description="可搜索并导入 E-Hentai 公开画廊；一本画廊作为一个漫画章节保存。",
        bookKind="漫画",
        language="日文",
        sampleUrl="https://e-hentai.org",
        tags=["漫画", "画廊", "R18"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-bikawebapp",
        name="Bika Web App",
        baseUrl="https://bikawebapp.com",
        description="哔咔漫画 Web App，导入前请先在设置中确认账号凭证。",
        bookKind="漫画",
        language="中文",
        sampleUrl="https://bikawebapp.com",
        tags=["漫画", "Bika"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-quark",
        name="夸克小说",
        baseUrl="https://www.shuqi.com",
        description="通过书旗网页内核搜索并导入夸克小说作品、完整目录和可取得的章节正文。",
        bookKind="长小说",
        language="中文",
        sampleUrl="https://www.shuqi.com/book/46543.html",
        tags=["中文", "夸克", "章节解析"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-copymanga",
        name="拷贝漫画 (CopyManga)",
        baseUrl="https://www.mangacopy.com",
        description="可搜索并导入作品、完整分组目录和可取得的漫画页面。",
        bookKind="漫画",
        language="中文",
        sampleUrl="https://www.mangacopy.com/comic/grandblue",
        tags=["漫画", "公开接口"],
        origin="builtin",
    ),
    BookSourceRecord(
        id="source-builtin-comicores",
        name="COMICORES 漫核",
        baseUrl="https://www.comicores.cc",
        description="搜索和预览作品元数据；当前解析器尚未实现章节资源解析。",
        bookKind="漫画",
        language="中文",
        sampleUrl="https://www.comicores.cc",
        tags=["漫画", "公开元数据"],
        origin="builtin",
    ),
]


@contextmanager
def get_connection() -> Iterator[sqlite3.Connection]:
    ensure_data_dir()
    connection = sqlite3.connect(DB_PATH, timeout=5)
    try:
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 5000")
        connection.execute("PRAGMA journal_mode = WAL")
        with connection:
            yield connection
    finally:
        connection.close()


def ensure_data_dir() -> None:
    global _DATA_DIR_READY
    if _DATA_DIR_READY:
        return

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    _migrate_legacy_data()
    _DATA_DIR_READY = True


def _migrate_legacy_data() -> None:
    if any(DATA_DIR.iterdir()):
        return
    migration_sources: list[Path] = []
    migration_sources.extend(_resolve_platform_data_dirs())
    migration_sources.append(LEGACY_DATA_DIR.resolve())

    seen_sources: set[Path] = set()
    for source_dir in migration_sources:
        if source_dir in seen_sources or source_dir == DATA_DIR:
            continue
        seen_sources.add(source_dir)
        if not source_dir.exists():
            continue
        if not any(source_dir.iterdir()):
            continue
        shutil.copytree(source_dir, DATA_DIR, dirs_exist_ok=True)
        break


def init_db() -> None:
    global _SITE_PLUGIN_STATE_CACHE
    with get_connection() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                username TEXT NOT NULL,
                username_key TEXT NOT NULL UNIQUE,
                email TEXT,
                email_key TEXT,
                github_user_id TEXT,
                github_login TEXT,
                totp_secret_encrypted TEXT,
                totp_last_counter INTEGER,
                auth_epoch INTEGER NOT NULL DEFAULT 0,
                display_name TEXT NOT NULL,
                password_hash TEXT NOT NULL,
                role TEXT NOT NULL CHECK (role IN ('admin', 'user')),
                status TEXT NOT NULL CHECK (status IN ('active', 'disabled')),
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                last_login_at TEXT
            )
            """
        )
        _ensure_user_role_column(conn)
        _ensure_user_email_columns(conn)
        _ensure_user_security_columns(conn)
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS user_sessions (
                token_hash TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                created_at TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                auth_epoch INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
            )
            """
        )
        _ensure_user_session_columns(conn)
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_user_sessions_user_expiry
            ON user_sessions (user_id, expires_at)
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS registration_settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                email_verification_required INTEGER NOT NULL DEFAULT 0,
                identity_badge_required INTEGER NOT NULL DEFAULT 0,
                smtp_host TEXT NOT NULL DEFAULT '',
                smtp_port INTEGER NOT NULL DEFAULT 587,
                smtp_security TEXT NOT NULL DEFAULT 'starttls',
                smtp_username TEXT NOT NULL DEFAULT '',
                smtp_password TEXT NOT NULL DEFAULT '',
                smtp_from_address TEXT NOT NULL DEFAULT '',
                smtp_from_name TEXT NOT NULL DEFAULT '青卷',
                identity_badge_hash TEXT NOT NULL DEFAULT '',
                github_enabled INTEGER NOT NULL DEFAULT 0,
                github_client_id TEXT NOT NULL DEFAULT '',
                github_config_revision INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL
            )
            """
        )
        _ensure_registration_settings_columns(conn)
        conn.execute(
            """
            INSERT OR IGNORE INTO registration_settings (id, updated_at)
            VALUES (1, ?)
            """,
            (_datetime_text(datetime.now(UTC)),),
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS email_verification_codes (
                email_key TEXT PRIMARY KEY,
                code_hash TEXT NOT NULL,
                code_salt TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                attempts_remaining INTEGER NOT NULL,
                last_sent_at TEXT NOT NULL,
                active INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS user_recovery_codes (
                user_id TEXT NOT NULL,
                code_hash TEXT NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY (user_id, code_hash),
                FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
            )
            """
        )
        _seed_default_admin_user(conn)
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS books (
                owner_id TEXT NOT NULL DEFAULT 'user-admin',
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                source_url TEXT NOT NULL,
                book_kind TEXT NOT NULL,
                language TEXT NOT NULL,
                status TEXT NOT NULL,
                chapter_count INTEGER NOT NULL,
                translated INTEGER NOT NULL,
                local_path TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                synopsis TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                payload TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS reading_progress (
                owner_id TEXT NOT NULL DEFAULT 'user-admin',
                book_id TEXT PRIMARY KEY,
                last_chapter_index INTEGER NOT NULL,
                last_scroll_ratio REAL NOT NULL DEFAULT 0,
                last_anchor_type TEXT NOT NULL DEFAULT 'top',
                last_anchor_index INTEGER NOT NULL DEFAULT 0,
                last_anchor_offset_ratio REAL NOT NULL DEFAULT 0,
                last_read_at TEXT,
                last_page_index INTEGER,
                last_page_count INTEGER,
                last_layout_key TEXT,
                last_content_mode TEXT,
                last_character_offset INTEGER
            )
            """
        )
        _ensure_reading_progress_columns(conn)
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS tasks (
                owner_id TEXT NOT NULL DEFAULT 'user-admin',
                id TEXT PRIMARY KEY,
                book_id TEXT NOT NULL,
                task_type TEXT NOT NULL,
                chapter_indexes TEXT NOT NULL,
                status TEXT NOT NULL,
                total_count INTEGER NOT NULL,
                completed_count INTEGER NOT NULL,
                progress REAL NOT NULL,
                message TEXT NOT NULL,
                error TEXT,
                attempts INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        _ensure_owner_columns(conn)
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_books_owner_updated
            ON books (owner_id, updated_at DESC)
            """
        )
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_tasks_owner_updated
            ON tasks (owner_id, updated_at DESC)
            """
        )
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_reading_progress_owner_book
            ON reading_progress (owner_id, book_id)
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS task_logs (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id TEXT NOT NULL,
                level TEXT NOT NULL,
                message TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_task_logs_task_sequence
            ON task_logs (task_id, sequence)
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS book_sources (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                base_url TEXT NOT NULL UNIQUE,
                description TEXT NOT NULL,
                book_kind TEXT,
                language TEXT,
                enabled INTEGER NOT NULL DEFAULT 1,
                supported INTEGER NOT NULL DEFAULT 1,
                sample_url TEXT,
                tags TEXT NOT NULL,
                origin TEXT NOT NULL,
                import_url TEXT,
                status TEXT NOT NULL DEFAULT 'unknown',
                status_message TEXT NOT NULL DEFAULT '',
                last_checked_at TEXT,
                rule_payload TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        _ensure_book_source_columns(conn)
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_book_sources_origin_name
            ON book_sources (origin, name)
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS site_plugin_settings (
                plugin_id TEXT PRIMARY KEY,
                enabled INTEGER NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS devices (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                platform TEXT NOT NULL,
                ip_address TEXT NOT NULL,
                first_seen_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL,
                banned INTEGER NOT NULL DEFAULT 0,
                banned_at TEXT
            )
            """
        )
        conn.execute(
            """
            CREATE INDEX IF NOT EXISTS idx_devices_last_seen
            ON devices (last_seen_at DESC)
            """
        )
        create_plugin_package_schema(conn)
        _seed_builtin_book_sources(conn)
        _seed_site_plugin_settings(conn)
    with _SITE_PLUGIN_STATE_LOCK:
        _SITE_PLUGIN_STATE_CACHE = None


def _ensure_reading_progress_columns(conn: sqlite3.Connection) -> None:
    existing_columns = {row[1] for row in conn.execute("PRAGMA table_info(reading_progress)").fetchall()}
    required_columns = {
        "last_scroll_ratio": "ALTER TABLE reading_progress ADD COLUMN last_scroll_ratio REAL NOT NULL DEFAULT 0",
        "last_anchor_type": "ALTER TABLE reading_progress ADD COLUMN last_anchor_type TEXT NOT NULL DEFAULT 'top'",
        "last_anchor_index": "ALTER TABLE reading_progress ADD COLUMN last_anchor_index INTEGER NOT NULL DEFAULT 0",
        "last_anchor_offset_ratio": "ALTER TABLE reading_progress ADD COLUMN last_anchor_offset_ratio REAL NOT NULL DEFAULT 0",
        "last_page_index": "ALTER TABLE reading_progress ADD COLUMN last_page_index INTEGER",
        "last_page_count": "ALTER TABLE reading_progress ADD COLUMN last_page_count INTEGER",
        "last_layout_key": "ALTER TABLE reading_progress ADD COLUMN last_layout_key TEXT",
        "last_content_mode": "ALTER TABLE reading_progress ADD COLUMN last_content_mode TEXT",
        "last_character_offset": "ALTER TABLE reading_progress ADD COLUMN last_character_offset INTEGER",
    }
    for column_name, statement in required_columns.items():
        if column_name not in existing_columns:
            conn.execute(statement)


def _ensure_user_role_column(conn: sqlite3.Connection) -> None:
    existing_columns = {row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()}
    if "role" not in existing_columns:
        conn.execute(
            "ALTER TABLE users ADD COLUMN role TEXT NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user'))"
        )
    conn.execute("UPDATE users SET role = 'user' WHERE role NOT IN ('admin', 'user') OR role IS NULL")
    conn.execute(
        "UPDATE users SET role = 'admin' WHERE id = ?",
        (DEFAULT_ADMIN_USER_ID,),
    )


def _ensure_user_email_columns(conn: sqlite3.Connection) -> None:
    existing_columns = {row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()}
    if "email" not in existing_columns:
        conn.execute("ALTER TABLE users ADD COLUMN email TEXT")
    if "email_key" not in existing_columns:
        conn.execute("ALTER TABLE users ADD COLUMN email_key TEXT")
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_key ON users (email_key) "
        "WHERE email_key IS NOT NULL"
    )


def _ensure_user_security_columns(conn: sqlite3.Connection) -> None:
    existing_columns = {row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()}
    required_columns = {
        "github_user_id": "ALTER TABLE users ADD COLUMN github_user_id TEXT",
        "github_login": "ALTER TABLE users ADD COLUMN github_login TEXT",
        "totp_secret_encrypted": "ALTER TABLE users ADD COLUMN totp_secret_encrypted TEXT",
        "totp_last_counter": "ALTER TABLE users ADD COLUMN totp_last_counter INTEGER",
        "auth_epoch": "ALTER TABLE users ADD COLUMN auth_epoch INTEGER NOT NULL DEFAULT 0",
    }
    for column_name, statement in required_columns.items():
        if column_name not in existing_columns:
            conn.execute(statement)
    conn.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_github_user_id "
        "ON users (github_user_id) WHERE github_user_id IS NOT NULL"
    )


def _ensure_user_session_columns(conn: sqlite3.Connection) -> None:
    existing_columns = {row[1] for row in conn.execute("PRAGMA table_info(user_sessions)").fetchall()}
    if "auth_epoch" not in existing_columns:
        conn.execute("ALTER TABLE user_sessions ADD COLUMN auth_epoch INTEGER NOT NULL DEFAULT 0")


def _ensure_registration_settings_columns(conn: sqlite3.Connection) -> None:
    existing_columns = {row[1] for row in conn.execute("PRAGMA table_info(registration_settings)").fetchall()}
    if "github_enabled" not in existing_columns:
        conn.execute("ALTER TABLE registration_settings ADD COLUMN github_enabled INTEGER NOT NULL DEFAULT 0")
    if "github_client_id" not in existing_columns:
        conn.execute("ALTER TABLE registration_settings ADD COLUMN github_client_id TEXT NOT NULL DEFAULT ''")
    if "github_config_revision" not in existing_columns:
        conn.execute(
            "ALTER TABLE registration_settings ADD COLUMN github_config_revision INTEGER NOT NULL DEFAULT 0"
        )


def _ensure_owner_columns(conn: sqlite3.Connection) -> None:
    for table_name in ("books", "reading_progress", "tasks"):
        columns = {row[1] for row in conn.execute(f"PRAGMA table_info({table_name})").fetchall()}
        if "owner_id" not in columns:
            conn.execute(
                f"ALTER TABLE {table_name} "
                f"ADD COLUMN owner_id TEXT NOT NULL DEFAULT '{DEFAULT_ADMIN_USER_ID}'"
            )


def _seed_default_admin_user(conn: sqlite3.Connection) -> None:
    timestamp = _datetime_text(datetime.now(UTC))
    configured_hash = configured_admin_password_hash()
    existing = conn.execute(
        "SELECT password_hash, auth_epoch FROM users WHERE id = ?",
        (DEFAULT_ADMIN_USER_ID,),
    ).fetchone()
    password_hash = configured_hash or "!local-desktop-only"
    conn.execute(
        """
        INSERT INTO users (
            id, username, username_key, email, email_key, display_name, password_hash,
            role, status, created_at, updated_at, last_login_at
        )
        VALUES (?, 'admin', 'admin', NULL, NULL, '管理员', ?, 'admin', 'active', ?, ?, NULL)
        ON CONFLICT(id) DO UPDATE SET
            username = 'admin',
            username_key = 'admin',
            display_name = CASE
                WHEN users.display_name = '' THEN '管理员'
                ELSE users.display_name
            END,
            password_hash = CASE
                WHEN excluded.password_hash = '!local-desktop-only' THEN users.password_hash
                ELSE excluded.password_hash
            END,
            role = 'admin',
            status = 'active',
            updated_at = excluded.updated_at
        """,
        (DEFAULT_ADMIN_USER_ID, password_hash, timestamp, timestamp),
    )
    if configured_hash is not None and existing is not None and existing[0] != configured_hash:
        conn.execute(
            "UPDATE users SET auth_epoch = auth_epoch + 1 WHERE id = ?",
            (DEFAULT_ADMIN_USER_ID,),
        )
        conn.execute(
            "DELETE FROM user_sessions WHERE user_id = ?",
            (DEFAULT_ADMIN_USER_ID,),
        )


def list_users() -> list[AdminUserRecord]:
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT u.id, u.username, u.display_name, u.role, u.status,
                   u.created_at, u.last_login_at, COUNT(b.id), u.email,
                   u.github_login, (u.totp_secret_encrypted IS NOT NULL)
            FROM users u
            LEFT JOIN books b ON b.owner_id = u.id
            GROUP BY u.id
            ORDER BY CASE WHEN u.role = 'admin' THEN 0 ELSE 1 END,
                     lower(u.username), u.created_at
            """
        ).fetchall()
    return [_row_to_user(row) for row in rows]


def get_user(user_id: str) -> AdminUserRecord | None:
    with get_connection() as conn:
        row = conn.execute(
            """
            SELECT u.id, u.username, u.display_name, u.role, u.status,
                   u.created_at, u.last_login_at, COUNT(b.id), u.email,
                   u.github_login, (u.totp_secret_encrypted IS NOT NULL)
            FROM users u
            LEFT JOIN books b ON b.owner_id = u.id
            WHERE u.id = ?
            GROUP BY u.id
            """,
            (user_id,),
        ).fetchone()
    return _row_to_user(row) if row is not None else None


def get_user_credentials_by_username(username_key: str) -> tuple[UserRecord, str] | None:
    with get_connection() as conn:
        row = conn.execute(
            """
            SELECT id, username, display_name, role, status, created_at,
                   last_login_at, password_hash, email
            FROM users
            WHERE username_key = ?
            """,
            (username_key,),
        ).fetchone()
    if row is None:
        return None
    user = UserRecord(
        id=row[0],
        username=row[1],
        email=row[8],
        displayName=row[2],
        role=row[3],
        status=row[4],
        createdAt=row[5],
        lastLoginAt=row[6],
    )
    return user, str(row[7])


def get_user_authentication_state_by_username(username_key: str) -> UserSecurityState | None:
    with get_connection() as conn:
        row = conn.execute(
            """
            SELECT id, username, email, display_name, role, status, created_at,
                   last_login_at, password_hash, github_user_id, github_login,
                   totp_secret_encrypted, totp_last_counter, auth_epoch
            FROM users
            WHERE username_key = ?
            """,
            (username_key,),
        ).fetchone()
    return _row_to_user_security_state(row) if row is not None else None


def get_user_security_state(user_id: str) -> UserSecurityState | None:
    with get_connection() as conn:
        row = conn.execute(
            """
            SELECT id, username, email, display_name, role, status, created_at,
                   last_login_at, password_hash, github_user_id, github_login,
                   totp_secret_encrypted, totp_last_counter, auth_epoch
            FROM users
            WHERE id = ?
            """,
            (user_id,),
        ).fetchone()
    return _row_to_user_security_state(row) if row is not None else None


def _row_to_user_security_state(row: sqlite3.Row | tuple) -> UserSecurityState:
    return UserSecurityState(
        user=UserRecord(
            id=row[0],
            username=row[1],
            email=row[2],
            displayName=row[3],
            role=row[4],
            status=row[5],
            createdAt=row[6],
            lastLoginAt=row[7],
        ),
        password_hash=str(row[8]),
        github_user_id=str(row[9]) if row[9] is not None else None,
        github_login=str(row[10]) if row[10] is not None else None,
        totp_secret_encrypted=str(row[11]) if row[11] is not None else None,
        totp_last_counter=int(row[12]) if row[12] is not None else None,
        auth_epoch=int(row[13]),
    )


def get_user_by_github_id(github_user_id: str) -> UserRecord | None:
    with get_connection() as conn:
        row = conn.execute(
            "SELECT id FROM users WHERE github_user_id = ?",
            (github_user_id,),
        ).fetchone()
    return get_user(str(row[0])) if row is not None else None


def refresh_github_login(github_user_id: str, github_login: str) -> UserRecord | None:
    with get_connection() as conn:
        row = conn.execute(
            "SELECT id, github_login FROM users WHERE github_user_id = ?",
            (github_user_id,),
        ).fetchone()
        if row is None:
            return None
        user_id = str(row[0])
        if str(row[1] or "") != github_login:
            conn.execute(
                "UPDATE users SET github_login = ?, updated_at = ? WHERE id = ? AND github_user_id = ?",
                (github_login, _datetime_text(datetime.now(UTC)), user_id, github_user_id),
            )
    return get_user(user_id)


def bind_github_identity(
    user_id: str,
    github_user_id: str,
    github_login: str,
    *,
    expected_auth_epoch: int | None = None,
    expected_config_revision: int | None = None,
    expected_client_id: str | None = None,
    keep_session_hash: str | None = None,
) -> UserRecord | None:
    timestamp = _datetime_text(datetime.now(UTC))
    with get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        _require_github_configuration(
            conn,
            expected_revision=expected_config_revision,
            expected_client_id=expected_client_id,
        )
        current_epoch = _current_auth_epoch(conn, user_id)
        if current_epoch is None:
            return None
        if expected_auth_epoch is not None and current_epoch != expected_auth_epoch:
            raise AuthenticationStateConflict("用户认证状态已变更")
        cursor = conn.execute(
            """
            UPDATE users
            SET github_user_id = ?, github_login = ?, auth_epoch = auth_epoch + 1,
                updated_at = ?
            WHERE id = ? AND github_user_id IS NULL AND auth_epoch = ?
            """,
            (github_user_id, github_login, timestamp, user_id, current_epoch),
        )
        if cursor.rowcount == 1:
            _synchronize_sessions_after_auth_change(
                conn,
                user_id,
                current_epoch + 1,
                keep_session_hash,
            )
    return get_user(user_id) if cursor.rowcount == 1 else None


def unbind_github_identity(
    user_id: str,
    *,
    expected_auth_epoch: int | None = None,
    keep_session_hash: str | None = None,
) -> bool:
    with get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        current_epoch = _current_auth_epoch(conn, user_id)
        if current_epoch is None:
            return False
        if expected_auth_epoch is not None and current_epoch != expected_auth_epoch:
            raise AuthenticationStateConflict("用户认证状态已变更")
        cursor = conn.execute(
            """
            UPDATE users
            SET github_user_id = NULL, github_login = NULL,
                auth_epoch = auth_epoch + 1, updated_at = ?
            WHERE id = ? AND github_user_id IS NOT NULL AND auth_epoch = ?
            """,
            (_datetime_text(datetime.now(UTC)), user_id, current_epoch),
        )
        if cursor.rowcount == 1:
            _synchronize_sessions_after_auth_change(
                conn,
                user_id,
                current_epoch + 1,
                keep_session_hash,
            )
    return cursor.rowcount == 1


def enable_user_two_factor(
    user_id: str,
    *,
    encrypted_secret: str,
    accepted_counter: int,
    recovery_code_hashes: list[str],
    keep_session_hash: str | None,
    expected_auth_epoch: int | None = None,
) -> bool:
    timestamp = _datetime_text(datetime.now(UTC))
    with get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        current_epoch = _current_auth_epoch(conn, user_id)
        if current_epoch is None:
            return False
        if expected_auth_epoch is not None and current_epoch != expected_auth_epoch:
            raise AuthenticationStateConflict("用户认证状态已变更")
        cursor = conn.execute(
            """
            UPDATE users
            SET totp_secret_encrypted = ?, totp_last_counter = ?,
                auth_epoch = auth_epoch + 1, updated_at = ?
            WHERE id = ? AND totp_secret_encrypted IS NULL AND auth_epoch = ?
            """,
            (encrypted_secret, accepted_counter, timestamp, user_id, current_epoch),
        )
        if cursor.rowcount != 1:
            return False
        conn.execute("DELETE FROM user_recovery_codes WHERE user_id = ?", (user_id,))
        conn.executemany(
            """
            INSERT INTO user_recovery_codes (user_id, code_hash, created_at)
            VALUES (?, ?, ?)
            """,
            [(user_id, code_hash, timestamp) for code_hash in recovery_code_hashes],
        )
        _synchronize_sessions_after_auth_change(
            conn,
            user_id,
            current_epoch + 1,
            keep_session_hash,
        )
    return True


def disable_user_two_factor(
    user_id: str,
    *,
    keep_session_hash: str | None,
    expected_auth_epoch: int | None = None,
) -> bool:
    with get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        current_epoch = _current_auth_epoch(conn, user_id)
        if current_epoch is None:
            return False
        if expected_auth_epoch is not None and current_epoch != expected_auth_epoch:
            raise AuthenticationStateConflict("用户认证状态已变更")
        cursor = conn.execute(
            """
            UPDATE users
            SET totp_secret_encrypted = NULL, totp_last_counter = NULL,
                auth_epoch = auth_epoch + 1, updated_at = ?
            WHERE id = ? AND totp_secret_encrypted IS NOT NULL AND auth_epoch = ?
            """,
            (_datetime_text(datetime.now(UTC)), user_id, current_epoch),
        )
        if cursor.rowcount == 1:
            conn.execute("DELETE FROM user_recovery_codes WHERE user_id = ?", (user_id,))
            _synchronize_sessions_after_auth_change(
                conn,
                user_id,
                current_epoch + 1,
                keep_session_hash,
            )
    return cursor.rowcount == 1


def _synchronize_sessions_after_auth_change(
    conn: sqlite3.Connection,
    user_id: str,
    auth_epoch: int,
    keep_session_hash: str | None,
) -> None:
    if keep_session_hash is None:
        conn.execute("DELETE FROM user_sessions WHERE user_id = ?", (user_id,))
        return
    conn.execute(
        "UPDATE user_sessions SET auth_epoch = ? WHERE user_id = ? AND token_hash = ?",
        (auth_epoch, user_id, keep_session_hash),
    )
    conn.execute(
        "DELETE FROM user_sessions WHERE user_id = ? AND token_hash != ?",
        (user_id, keep_session_hash),
    )


def _current_auth_epoch(conn: sqlite3.Connection, user_id: str) -> int | None:
    row = conn.execute("SELECT auth_epoch FROM users WHERE id = ?", (user_id,)).fetchone()
    return int(row[0]) if row is not None else None


def _require_github_configuration(
    conn: sqlite3.Connection,
    *,
    expected_revision: int | None,
    expected_client_id: str | None,
) -> None:
    if expected_revision is None and expected_client_id is None:
        return
    row = conn.execute(
        """
        SELECT github_enabled, github_client_id, github_config_revision
        FROM registration_settings WHERE id = 1
        """
    ).fetchone()
    if (
        row is None
        or not bool(row[0])
        or str(row[1] or "") != expected_client_id
        or int(row[2] or 0) != expected_revision
    ):
        raise GitHubConfigurationConflict("GitHub 登录配置已变更")


def accept_user_totp_counter(user_id: str, counter: int) -> bool:
    with get_connection() as conn:
        cursor = conn.execute(
            """
            UPDATE users
            SET totp_last_counter = ?, updated_at = ?
            WHERE id = ? AND totp_secret_encrypted IS NOT NULL
              AND (totp_last_counter IS NULL OR totp_last_counter < ?)
            """,
            (counter, _datetime_text(datetime.now(UTC)), user_id, counter),
        )
    return cursor.rowcount == 1


def replace_user_recovery_codes(
    user_id: str,
    recovery_code_hashes: list[str],
    *,
    expected_auth_epoch: int | None = None,
    keep_session_hash: str | None = None,
) -> bool:
    timestamp = _datetime_text(datetime.now(UTC))
    with get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        enabled = conn.execute(
            "SELECT auth_epoch FROM users WHERE id = ? AND totp_secret_encrypted IS NOT NULL",
            (user_id,),
        ).fetchone()
        if enabled is None:
            return False
        current_epoch = int(enabled[0])
        if expected_auth_epoch is not None and current_epoch != expected_auth_epoch:
            raise AuthenticationStateConflict("用户认证状态已变更")
        conn.execute("DELETE FROM user_recovery_codes WHERE user_id = ?", (user_id,))
        conn.executemany(
            """
            INSERT INTO user_recovery_codes (user_id, code_hash, created_at)
            VALUES (?, ?, ?)
            """,
            [(user_id, code_hash, timestamp) for code_hash in recovery_code_hashes],
        )
        cursor = conn.execute(
            "UPDATE users SET auth_epoch = auth_epoch + 1, updated_at = ? "
            "WHERE id = ? AND auth_epoch = ? AND totp_secret_encrypted IS NOT NULL",
            (timestamp, user_id, current_epoch),
        )
        if cursor.rowcount != 1:
            raise AuthenticationStateConflict("用户认证状态已变更")
        _synchronize_sessions_after_auth_change(
            conn,
            user_id,
            current_epoch + 1,
            keep_session_hash,
        )
    return True


def consume_user_recovery_code(user_id: str, code_hash: str) -> bool:
    with get_connection() as conn:
        cursor = conn.execute(
            "DELETE FROM user_recovery_codes WHERE user_id = ? AND code_hash = ?",
            (user_id, code_hash),
        )
    return cursor.rowcount == 1


def count_user_recovery_codes(user_id: str) -> int:
    with get_connection() as conn:
        row = conn.execute(
            "SELECT COUNT(*) FROM user_recovery_codes WHERE user_id = ?",
            (user_id,),
        ).fetchone()
    return int(row[0]) if row is not None else 0


def get_user_by_email_key(email_key: str) -> UserRecord | None:
    with get_connection() as conn:
        row = conn.execute(
            """
            SELECT u.id, u.username, u.display_name, u.role, u.status,
                   u.created_at, u.last_login_at,
                   (SELECT COUNT(*) FROM books b WHERE b.owner_id = u.id), u.email,
                   u.github_login, (u.totp_secret_encrypted IS NOT NULL)
            FROM users u
            WHERE u.email_key = ?
            """,
            (email_key,),
        ).fetchone()
    return _row_to_user(row) if row is not None else None


def create_user(
    *,
    user_id: str,
    username: str,
    username_key: str,
    email: str | None = None,
    email_key: str | None = None,
    display_name: str,
    password_hash: str,
    role: str = "user",
) -> UserRecord:
    timestamp = _datetime_text(datetime.now(UTC))
    with get_connection() as conn:
        conn.execute(
            """
            INSERT INTO users (
                id, username, username_key, email, email_key, display_name, password_hash,
                role, status, created_at, updated_at, last_login_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, NULL)
            """,
            (
                user_id,
                username,
                username_key,
                email,
                email_key,
                display_name,
                password_hash,
                role,
                timestamp,
                timestamp,
            ),
        )
    created = get_user(user_id)
    if created is None:
        raise RuntimeError("用户创建失败")
    return created


def update_user_profile(
    user_id: str,
    *,
    display_name: str | None = None,
    role: str | None = None,
    status: str | None = None,
) -> UserRecord | None:
    if role is not None and role not in {"admin", "user"}:
        raise ValueError("用户角色无效")
    if status is not None and status not in {"active", "disabled"}:
        raise ValueError("用户状态无效")
    assignments: list[str] = []
    values: list[object] = []
    for column, value in (
        ("display_name", display_name),
        ("role", role),
        ("status", status),
    ):
        if value is not None:
            assignments.append(f"{column} = ?")
            values.append(value)
    if not assignments:
        return get_user(user_id)
    assignments.append("updated_at = ?")
    values.append(_datetime_text(datetime.now(UTC)))
    values.append(user_id)
    with get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        current = conn.execute(
            "SELECT role, status FROM users WHERE id = ?",
            (user_id,),
        ).fetchone()
        if current is None:
            return None
        current_role = str(current[0])
        current_status = str(current[1])
        next_role = role if role is not None else current_role
        next_status = status if status is not None else current_status
        if user_id == DEFAULT_ADMIN_USER_ID:
            if next_role != "admin":
                raise ValueError("内置管理员不能降权")
            if next_status != "active":
                raise ValueError("内置管理员不能停用")
        if (
            role == "admin"
            and current_role != "admin"
            and (current_status != "active" or next_status != "active")
        ):
            raise ValueError("请先启用用户，再授予管理员角色")
        removes_active_admin = (
            current_role == "admin"
            and current_status == "active"
            and (next_role != "admin" or next_status != "active")
        )
        if removes_active_admin:
            active_admin_count = conn.execute(
                "SELECT COUNT(*) FROM users WHERE id != ? AND role = 'admin' AND status = 'active'",
                (user_id,),
            ).fetchone()[0]
            if int(active_admin_count) == 0:
                raise ValueError("必须保留至少一个已启用的管理员")
        cursor = conn.execute(
            f"UPDATE users SET {', '.join(assignments)} WHERE id = ?",
            tuple(values),
        )
        if cursor.rowcount == 0:
            return None
        if next_status != current_status or next_role != current_role:
            conn.execute(
                "UPDATE users SET auth_epoch = auth_epoch + 1 WHERE id = ?",
                (user_id,),
            )
            conn.execute("DELETE FROM user_sessions WHERE user_id = ?", (user_id,))
    return get_user(user_id)


def update_user_password(
    user_id: str,
    password_hash: str,
    *,
    revoke_sessions: bool = False,
) -> bool:
    with get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        cursor = conn.execute(
            "UPDATE users SET password_hash = ?, auth_epoch = auth_epoch + 1, updated_at = ? WHERE id = ?",
            (password_hash, _datetime_text(datetime.now(UTC)), user_id),
        )
        if cursor.rowcount > 0 and revoke_sessions:
            conn.execute("DELETE FROM user_sessions WHERE user_id = ?", (user_id,))
    return cursor.rowcount > 0


def mark_user_login(user_id: str, login_at: str) -> UserRecord | None:
    with get_connection() as conn:
        cursor = conn.execute(
            "UPDATE users SET last_login_at = ?, updated_at = ? WHERE id = ?",
            (login_at, login_at, user_id),
        )
        if cursor.rowcount == 0:
            return None
    return get_user(user_id)


def create_user_session(
    *,
    token_hash: str,
    user_id: str,
    created_at: str,
    expires_at: str,
    expected_auth_epoch: int,
    expected_two_factor_enabled: bool,
    login_at: str | None = None,
    github_config_revision: int | None = None,
    github_client_id: str | None = None,
) -> bool:
    with get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        _require_github_configuration(
            conn,
            expected_revision=github_config_revision,
            expected_client_id=github_client_id,
        )
        conn.execute("DELETE FROM user_sessions WHERE expires_at <= ?", (created_at,))
        cursor = conn.execute(
            """
            INSERT INTO user_sessions (
                token_hash, user_id, created_at, expires_at, auth_epoch
            )
            SELECT ?, id, ?, ?, auth_epoch
            FROM users
            WHERE id = ? AND status = 'active' AND auth_epoch = ?
              AND (totp_secret_encrypted IS NOT NULL) = ?
            """,
            (
                token_hash,
                created_at,
                expires_at,
                user_id,
                expected_auth_epoch,
                int(expected_two_factor_enabled),
            ),
        )
        if cursor.rowcount != 1:
            return False
        if login_at is not None:
            conn.execute(
                "UPDATE users SET last_login_at = ?, updated_at = ? WHERE id = ? AND auth_epoch = ?",
                (login_at, login_at, user_id, expected_auth_epoch),
            )
    return True


def get_user_by_session_hash(token_hash: str, *, now: str) -> UserRecord | None:
    with get_connection() as conn:
        row = conn.execute(
            """
            SELECT u.id, u.username, u.display_name, u.role, u.status,
                   u.created_at, u.last_login_at,
                   (SELECT COUNT(*) FROM books b WHERE b.owner_id = u.id), u.email,
                   u.github_login, (u.totp_secret_encrypted IS NOT NULL)
            FROM user_sessions s
            JOIN users u ON u.id = s.user_id
            WHERE s.token_hash = ? AND s.expires_at > ?
              AND s.auth_epoch = u.auth_epoch
            """,
            (token_hash, now),
        ).fetchone()
        if row is None:
            conn.execute("DELETE FROM user_sessions WHERE token_hash = ?", (token_hash,))
            return None
    return _row_to_user(row)


def delete_user_session(token_hash: str) -> None:
    with get_connection() as conn:
        conn.execute("DELETE FROM user_sessions WHERE token_hash = ?", (token_hash,))


def revoke_user_sessions(user_id: str) -> int:
    with get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        conn.execute(
            "UPDATE users SET auth_epoch = auth_epoch + 1, updated_at = ? WHERE id = ?",
            (_datetime_text(datetime.now(UTC)), user_id),
        )
        cursor = conn.execute("DELETE FROM user_sessions WHERE user_id = ?", (user_id,))
    return max(0, int(cursor.rowcount))


def _ensure_book_source_columns(conn: sqlite3.Connection) -> None:
    existing_columns = {row[1] for row in conn.execute("PRAGMA table_info(book_sources)").fetchall()}
    if "rule_payload" not in existing_columns:
        conn.execute("ALTER TABLE book_sources ADD COLUMN rule_payload TEXT")


DEVICE_ONLINE_WINDOW_SECONDS = 120
DEVICE_TOUCH_INTERVAL_SECONDS = 30


def touch_device(
    *,
    device_id: str,
    name: str,
    platform: str,
    ip_address: str,
    seen_at: datetime | None = None,
) -> DeviceRecord:
    timestamp = seen_at or datetime.now(UTC)
    timestamp_text = _datetime_text(timestamp)
    update_before = _datetime_text(timestamp - timedelta(seconds=DEVICE_TOUCH_INTERVAL_SECONDS))
    with get_connection() as conn:
        row = conn.execute(
            """
            SELECT id, name, platform, ip_address, first_seen_at, last_seen_at,
                   banned, banned_at
            FROM devices
            WHERE id = ?
            """,
            (device_id,),
        ).fetchone()
        if row is None:
            conn.execute(
                """
                INSERT INTO devices (
                    id, name, platform, ip_address, first_seen_at, last_seen_at,
                    banned, banned_at
                )
                VALUES (?, ?, ?, ?, ?, ?, 0, NULL)
                """,
                (device_id, name, platform, ip_address, timestamp_text, timestamp_text),
            )
        elif not bool(row[6]) and (
            row[1] != name or row[2] != platform or row[3] != ip_address or row[5] <= update_before
        ):
            conn.execute(
                """
                UPDATE devices
                SET name = ?, platform = ?, ip_address = ?, last_seen_at = ?
                WHERE id = ?
                """,
                (name, platform, ip_address, timestamp_text, device_id),
            )
        refreshed = conn.execute(
            """
            SELECT id, name, platform, ip_address, first_seen_at, last_seen_at,
                   banned, banned_at
            FROM devices
            WHERE id = ?
            """,
            (device_id,),
        ).fetchone()
    if refreshed is None:
        raise RuntimeError("设备登记失败")
    return _row_to_device(refreshed)


def list_devices(*, now: datetime | None = None) -> list[DeviceView]:
    current_time = now or datetime.now(UTC)
    online_after = current_time - timedelta(seconds=DEVICE_ONLINE_WINDOW_SECONDS)
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT id, name, platform, ip_address, first_seen_at, last_seen_at,
                   banned, banned_at
            FROM devices
            ORDER BY banned ASC, last_seen_at DESC, first_seen_at DESC
            """
        ).fetchall()
    devices: list[DeviceView] = []
    for row in rows:
        record = _row_to_device(row)
        devices.append(
            DeviceView(
                **record.model_dump(),
                online=not record.banned and _parse_datetime(record.lastSeenAt) >= online_after,
            )
        )
    return devices


def set_device_banned(
    device_id: str,
    *,
    banned: bool,
    changed_at: datetime | None = None,
) -> DeviceView | None:
    timestamp_text = _datetime_text(changed_at or datetime.now(UTC))
    with get_connection() as conn:
        cursor = conn.execute(
            """
            UPDATE devices
            SET banned = ?, banned_at = ?
            WHERE id = ?
            """,
            (int(banned), timestamp_text if banned else None, device_id),
        )
        if cursor.rowcount == 0:
            return None
    return next((device for device in list_devices() if device.id == device_id), None)


def list_books(owner_id: str | None = None) -> list[BookRecord]:
    where_clause = "WHERE b.owner_id = ?" if owner_id is not None else ""
    params: tuple[str, ...] = (owner_id,) if owner_id is not None else ()
    with get_connection() as conn:
        rows = conn.execute(
            f"""
            SELECT b.owner_id, b.id, b.title, b.source_url, b.book_kind, b.language, b.status,
                   b.chapter_count, b.translated, b.local_path, b.updated_at, b.synopsis,
                   COALESCE(rp.last_chapter_index, 0), rp.last_read_at,
                   rp.last_page_index, rp.last_page_count
            FROM books b
            LEFT JOIN reading_progress rp
              ON rp.book_id = b.id AND rp.owner_id = b.owner_id
            {where_clause}
            ORDER BY b.updated_at DESC
            """,
            params,
        ).fetchall()

    return [_row_to_book(row) for row in rows]


def get_book(book_id: str, owner_id: str | None = None) -> BookRecord | None:
    owner_clause = " AND b.owner_id = ?" if owner_id is not None else ""
    params = (book_id, owner_id) if owner_id is not None else (book_id,)
    with get_connection() as conn:
        row = conn.execute(
            f"""
            SELECT b.owner_id, b.id, b.title, b.source_url, b.book_kind, b.language, b.status,
                   b.chapter_count, b.translated, b.local_path, b.updated_at, b.synopsis,
                   COALESCE(rp.last_chapter_index, 0), rp.last_read_at,
                   rp.last_page_index, rp.last_page_count
            FROM books b
            LEFT JOIN reading_progress rp
              ON rp.book_id = b.id AND rp.owner_id = b.owner_id
            WHERE b.id = ?{owner_clause}
            """,
            params,
        ).fetchone()

    if row is None:
        return None

    return _row_to_book(row)


def save_book(book: BookRecord) -> None:
    with get_connection() as conn:
        conn.execute(
            """
            INSERT INTO books (
                owner_id, id, title, source_url, book_kind, language, status,
                chapter_count, translated, local_path, updated_at, synopsis
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                owner_id = excluded.owner_id,
                title = excluded.title,
                source_url = excluded.source_url,
                book_kind = excluded.book_kind,
                language = excluded.language,
                status = excluded.status,
                chapter_count = excluded.chapter_count,
                translated = excluded.translated,
                local_path = excluded.local_path,
                updated_at = excluded.updated_at,
                synopsis = excluded.synopsis
            """,
            (
                book.ownerId,
                book.id,
                book.title,
                book.sourceUrl,
                book.bookKind,
                book.language,
                book.status,
                book.chapterCount,
                int(book.translated),
                book.localPath,
                book.updatedAt,
                book.synopsis,
            ),
        )


def delete_book(book_id: str, owner_id: str | None = None) -> bool:
    with get_connection() as conn:
        owner_clause = " AND owner_id = ?" if owner_id is not None else ""
        params = (book_id, owner_id) if owner_id is not None else (book_id,)
        if conn.execute(f"SELECT 1 FROM books WHERE id = ?{owner_clause}", params).fetchone() is None:
            return False
        conn.execute(
            """
            DELETE FROM task_logs
            WHERE task_id IN (SELECT id FROM tasks WHERE book_id = ?)
            """,
            (book_id,),
        )
        conn.execute("DELETE FROM tasks WHERE book_id = ?", (book_id,))
        conn.execute("DELETE FROM reading_progress WHERE book_id = ?", (book_id,))
        conn.execute("DELETE FROM books WHERE id = ?", (book_id,))
    return True


def list_book_sources() -> list[BookSourceRecord]:
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT
                id, name, base_url, description, book_kind, language,
                enabled, supported, sample_url, tags, origin, import_url,
                status, status_message, last_checked_at, rule_payload, created_at, updated_at
            FROM book_sources
            WHERE origin != 'builtin'
            ORDER BY lower(name) ASC, created_at DESC
            """
        ).fetchall()
    return [_row_to_book_source(row) for row in rows]


def list_builtin_book_source_base_urls() -> list[str]:
    """返回内置书源的 base_url 列表。

    导入 Legado 书源时，book_sources 表的 base_url 唯一约束会同时覆盖内置书源，
    但 list_book_sources 只返回非内置书源，导致去重逻辑看不到内置站点。
    此处单独提供内置 base_url，供导入流程跳过与内置站点 URL 冲突的条目。
    """
    with get_connection() as conn:
        rows = conn.execute("SELECT base_url FROM book_sources WHERE origin = 'builtin'").fetchall()
    return [row[0] for row in rows]


def get_book_source(source_id: str) -> BookSourceRecord | None:
    with get_connection() as conn:
        row = conn.execute(
            """
            SELECT
                id, name, base_url, description, book_kind, language,
                enabled, supported, sample_url, tags, origin, import_url,
                status, status_message, last_checked_at, rule_payload, created_at, updated_at
            FROM book_sources
            WHERE id = ?
            """,
            (source_id,),
        ).fetchone()
    if row is None:
        return None
    return _row_to_book_source(row)


def save_book_source(source: BookSourceRecord) -> BookSourceRecord:
    with get_connection() as conn:
        conn.execute(
            """
            INSERT INTO book_sources (
                id, name, base_url, description, book_kind, language,
                enabled, supported, sample_url, tags, origin, import_url,
                status, status_message, last_checked_at, rule_payload, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                base_url = excluded.base_url,
                description = excluded.description,
                book_kind = excluded.book_kind,
                language = excluded.language,
                enabled = excluded.enabled,
                supported = excluded.supported,
                sample_url = excluded.sample_url,
                tags = excluded.tags,
                origin = excluded.origin,
                import_url = excluded.import_url,
                status = excluded.status,
                status_message = excluded.status_message,
                last_checked_at = excluded.last_checked_at,
                rule_payload = excluded.rule_payload,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at
            """,
            (
                source.id,
                source.name,
                source.baseUrl,
                source.description,
                source.bookKind,
                source.language,
                int(source.enabled),
                int(source.supported),
                source.sampleUrl,
                json_dumps(source.tags),
                source.origin,
                source.importUrl,
                source.status,
                source.statusMessage,
                source.lastCheckedAt,
                json_dumps(source.rulePayload) if source.rulePayload else None,
                source.createdAt,
                source.updatedAt,
            ),
        )
    return source


def delete_book_source(source_id: str) -> None:
    with get_connection() as conn:
        conn.execute("DELETE FROM book_sources WHERE id = ?", (source_id,))


def invalidate_site_plugin_states() -> None:
    global _SITE_PLUGIN_STATE_CACHE
    with _SITE_PLUGIN_STATE_LOCK:
        _SITE_PLUGIN_STATE_CACHE = None


def list_site_plugin_enabled_states() -> dict[str, bool]:
    global _SITE_PLUGIN_STATE_CACHE
    with _SITE_PLUGIN_STATE_LOCK:
        if _SITE_PLUGIN_STATE_CACHE is not None and _SITE_PLUGIN_STATE_CACHE[0] == DB_PATH:
            return dict(_SITE_PLUGIN_STATE_CACHE[1])

    states = {plugin.id: plugin.default_enabled for plugin in list_site_plugins()}
    try:
        with get_connection() as conn:
            rows = conn.execute("SELECT plugin_id, enabled FROM site_plugin_settings").fetchall()
    except sqlite3.OperationalError as exc:
        error_text = str(exc).lower()
        if "no such table" not in error_text or "site_plugin_settings" not in error_text:
            raise
        # 启动迁移前可以暂用代码默认值，但不能缓存；否则后续建表或一次临时锁库
        # 都可能让停用状态在当前进程中永久回退为默认启用。
        return dict(states)
    for plugin_id, enabled in rows:
        if plugin_id in states:
            states[str(plugin_id)] = bool(enabled)
    with _SITE_PLUGIN_STATE_LOCK:
        _SITE_PLUGIN_STATE_CACHE = (DB_PATH, dict(states))
    return dict(states)


def is_site_plugin_enabled(plugin_id: str) -> bool:
    plugin = get_site_plugin(plugin_id)
    if plugin is None:
        return False
    return list_site_plugin_enabled_states().get(plugin_id, plugin.default_enabled)


def save_site_plugin_enabled(plugin_id: str, enabled: bool) -> None:
    global _SITE_PLUGIN_STATE_CACHE
    if get_site_plugin(plugin_id) is None:
        raise ValueError(f"未知站点插件：{plugin_id}")
    with get_connection() as conn:
        conn.execute(
            """
            INSERT INTO site_plugin_settings (plugin_id, enabled, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(plugin_id) DO UPDATE SET
                enabled = excluded.enabled,
                updated_at = excluded.updated_at
            """,
            (
                plugin_id,
                int(enabled),
                datetime.now(UTC).isoformat().replace("+00:00", "Z"),
            ),
        )
    with _SITE_PLUGIN_STATE_LOCK:
        if _SITE_PLUGIN_STATE_CACHE is not None and _SITE_PLUGIN_STATE_CACHE[0] == DB_PATH:
            states = dict(_SITE_PLUGIN_STATE_CACHE[1])
            states[plugin_id] = enabled
            _SITE_PLUGIN_STATE_CACHE = (DB_PATH, states)


def load_reading_progress(
    book_id: str,
    owner_id: str | None = None,
) -> ReadingProgressRecord:
    owner_clause = " AND owner_id = ?" if owner_id is not None else ""
    params = (book_id, owner_id) if owner_id is not None else (book_id,)
    with get_connection() as conn:
        row = conn.execute(
            f"""
            SELECT
                owner_id,
                book_id,
                last_chapter_index,
                last_scroll_ratio,
                last_anchor_type,
                last_anchor_index,
                last_anchor_offset_ratio,
                last_read_at,
                last_page_index,
                last_page_count,
                last_layout_key,
                last_content_mode,
                last_character_offset
            FROM reading_progress
            WHERE book_id = ?{owner_clause}
            """,
            params,
        ).fetchone()

    if row is None:
        return ReadingProgressRecord(
            ownerId=owner_id or DEFAULT_ADMIN_USER_ID,
            bookId=book_id,
            lastChapterIndex=0,
            lastReadAt=None,
        )

    return ReadingProgressRecord(
        ownerId=row[0],
        bookId=row[1],
        lastChapterIndex=row[2],
        lastScrollRatio=row[3],
        lastAnchorType=row[4],
        lastAnchorIndex=row[5],
        lastAnchorOffsetRatio=row[6],
        lastReadAt=row[7],
        lastPageIndex=row[8],
        lastPageCount=row[9],
        lastLayoutKey=row[10],
        lastContentMode=row[11],
        lastCharacterOffset=row[12],
    )


def save_reading_progress(progress: ReadingProgressRecord) -> ReadingProgressRecord:
    with get_connection() as conn:
        conn.execute(
            """
            INSERT INTO reading_progress (
                owner_id,
                book_id,
                last_chapter_index,
                last_scroll_ratio,
                last_anchor_type,
                last_anchor_index,
                last_anchor_offset_ratio,
                last_read_at,
                last_page_index,
                last_page_count,
                last_layout_key,
                last_content_mode,
                last_character_offset
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET
                owner_id = excluded.owner_id,
                last_chapter_index = excluded.last_chapter_index,
                last_scroll_ratio = excluded.last_scroll_ratio,
                last_anchor_type = excluded.last_anchor_type,
                last_anchor_index = excluded.last_anchor_index,
                last_anchor_offset_ratio = excluded.last_anchor_offset_ratio,
                last_read_at = excluded.last_read_at,
                last_page_index = excluded.last_page_index,
                last_page_count = excluded.last_page_count,
                last_layout_key = excluded.last_layout_key,
                last_content_mode = excluded.last_content_mode,
                last_character_offset = excluded.last_character_offset
            """,
            (
                progress.ownerId,
                progress.bookId,
                progress.lastChapterIndex,
                progress.lastScrollRatio,
                progress.lastAnchorType,
                progress.lastAnchorIndex,
                progress.lastAnchorOffsetRatio,
                progress.lastReadAt,
                progress.lastPageIndex,
                progress.lastPageCount,
                progress.lastLayoutKey,
                progress.lastContentMode,
                progress.lastCharacterOffset,
            ),
        )
    return progress


def create_task(task: TaskRecord) -> TaskRecord:
    with get_connection() as conn:
        conn.execute(
            """
            INSERT INTO tasks (
                owner_id, id, book_id, task_type, chapter_indexes, status, total_count,
                completed_count, progress, message, error, attempts, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                task.ownerId,
                task.id,
                task.bookId,
                task.taskType,
                json_dumps(task.chapterIndexes),
                task.status,
                task.totalCount,
                task.completedCount,
                task.progress,
                task.message,
                task.error,
                task.attempts,
                task.createdAt,
                task.updatedAt,
            ),
        )
    return task


def get_task(task_id: str, owner_id: str | None = None) -> TaskRecord | None:
    owner_clause = " AND owner_id = ?" if owner_id is not None else ""
    params = (task_id, owner_id) if owner_id is not None else (task_id,)
    with get_connection() as conn:
        row = conn.execute(
            f"""
            SELECT owner_id, id, book_id, task_type, chapter_indexes, status, total_count,
                   completed_count, progress, message, error, attempts, created_at, updated_at
            FROM tasks
            WHERE id = ?{owner_clause}
            """,
            params,
        ).fetchone()

    if row is None:
        return None
    return _row_to_task(row)


def list_tasks(
    book_id: str | None = None,
    owner_id: str | None = None,
) -> list[TaskRecord]:
    query = """
        SELECT owner_id, id, book_id, task_type, chapter_indexes, status, total_count,
               completed_count, progress, message, error, attempts, created_at, updated_at
        FROM tasks
    """
    conditions: list[str] = []
    params_list: list[str] = []
    if book_id:
        conditions.append("book_id = ?")
        params_list.append(book_id)
    if owner_id is not None:
        conditions.append("owner_id = ?")
        params_list.append(owner_id)
    if conditions:
        query += " WHERE " + " AND ".join(conditions)
    query += " ORDER BY updated_at DESC, created_at DESC"

    with get_connection() as conn:
        rows = conn.execute(query, tuple(params_list)).fetchall()

    return [_row_to_task(row) for row in rows]


def list_pending_tasks() -> list[TaskRecord]:
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT owner_id, id, book_id, task_type, chapter_indexes, status, total_count,
                   completed_count, progress, message, error, attempts, created_at, updated_at
            FROM tasks
            WHERE status IN ('queued', 'running')
            ORDER BY created_at ASC
            """
        ).fetchall()

    return [_row_to_task(row) for row in rows]


def save_task(task: TaskRecord) -> TaskRecord:
    with get_connection() as conn:
        conn.execute(
            """
            INSERT INTO tasks (
                owner_id, id, book_id, task_type, chapter_indexes, status, total_count,
                completed_count, progress, message, error, attempts, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                owner_id = excluded.owner_id,
                book_id = excluded.book_id,
                task_type = excluded.task_type,
                chapter_indexes = excluded.chapter_indexes,
                status = excluded.status,
                total_count = excluded.total_count,
                completed_count = excluded.completed_count,
                progress = excluded.progress,
                message = excluded.message,
                error = excluded.error,
                attempts = excluded.attempts,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at
            """,
            (
                task.ownerId,
                task.id,
                task.bookId,
                task.taskType,
                json_dumps(task.chapterIndexes),
                task.status,
                task.totalCount,
                task.completedCount,
                task.progress,
                task.message,
                task.error,
                task.attempts,
                task.createdAt,
                task.updatedAt,
            ),
        )
    return task


def append_task_log(task_id: str, level: str, message: str, created_at: str) -> TaskLogRecord:
    with get_connection() as conn:
        cursor = conn.execute(
            """
            INSERT INTO task_logs (task_id, level, message, created_at)
            VALUES (?, ?, ?, ?)
            """,
            (task_id, level, message, created_at),
        )
        sequence = int(cursor.lastrowid)
    return TaskLogRecord(
        sequence=sequence,
        taskId=task_id,
        level=level,  # type: ignore[arg-type]
        message=message,
        createdAt=created_at,
    )


def list_task_logs(task_id: str, after_sequence: int = 0) -> list[TaskLogRecord]:
    with get_connection() as conn:
        rows = conn.execute(
            """
            SELECT sequence, task_id, level, message, created_at
            FROM task_logs
            WHERE task_id = ? AND sequence > ?
            ORDER BY sequence ASC
            """,
            (task_id, max(0, int(after_sequence))),
        ).fetchall()
    return [_row_to_task_log(row) for row in rows]


def _migrate_settings_payload(payload: dict[str, object]) -> dict[str, object]:
    migrated = dict(payload)
    if not isinstance(migrated.get("translationModel"), dict):
        providers = migrated.get("providers")
        provider_map = providers if isinstance(providers, dict) else {}
        selected = str(migrated.get("defaultProvider") or "openai").strip().lower()
        selected_config = provider_map.get(selected)
        openai_config = provider_map.get("openai")
        if selected != "anthropic" and isinstance(selected_config, dict):
            translation_model = dict(selected_config)
        elif isinstance(openai_config, dict):
            translation_model = dict(openai_config)
        else:
            translation_model = DEFAULT_SETTINGS.translationModel.model_dump()
        migrated["translationModel"] = translation_model
    migrated.pop("defaultProvider", None)
    migrated.pop("providers", None)
    return migrated


def load_settings() -> TranslationSettings:
    with get_connection() as conn:
        row = conn.execute("SELECT payload FROM settings WHERE id = 1").fetchone()

    if not row:
        return DEFAULT_SETTINGS.model_copy(deep=True)

    raw_payload = json.loads(row[0])
    if not isinstance(raw_payload, dict):
        return DEFAULT_SETTINGS.model_copy(deep=True)
    loaded = TranslationSettings.model_validate(_migrate_settings_payload(raw_payload))
    return _normalize_settings(loaded)


def save_settings(settings: TranslationSettings) -> TranslationSettings:
    normalized = _normalize_settings(settings)
    payload = normalized.model_dump_json()
    with get_connection() as conn:
        conn.execute(
            """
            INSERT INTO settings (id, payload)
            VALUES (1, ?)
            ON CONFLICT(id) DO UPDATE SET payload = excluded.payload
            """,
            (payload,),
        )
    return normalized


def _normalize_settings(settings: TranslationSettings) -> TranslationSettings:
    normalized = DEFAULT_SETTINGS.model_copy(deep=True)
    normalized.systemPrompt = settings.systemPrompt
    normalized.autoTranslateNextChapters = settings.autoTranslateNextChapters
    normalized.downloadConcurrency = settings.downloadConcurrency
    normalized.translationModel = settings.translationModel.model_copy(deep=True)
    normalized.mangaOcr = settings.mangaOcr.model_copy(deep=True)
    normalized.bika = settings.bika.model_copy(deep=True)
    return normalized


def _row_to_book(row: sqlite3.Row | tuple) -> BookRecord:
    return BookRecord(
        ownerId=row[0],
        id=row[1],
        title=row[2],
        sourceUrl=row[3],
        bookKind=_normalize_book_kind(row[4]),
        language=_normalize_language(row[5]),
        status=_normalize_book_status(row[6]),
        chapterCount=row[7],
        translated=bool(row[8]),
        localPath=row[9],
        updatedAt=row[10],
        synopsis=row[11],
        lastReadChapterIndex=row[12] if len(row) > 12 else 0,
        lastReadAt=row[13] if len(row) > 13 else None,
        lastReadPageIndex=row[14] if len(row) > 14 else None,
        lastReadPageCount=row[15] if len(row) > 15 else None,
    )


def _row_to_user(row: sqlite3.Row | tuple) -> AdminUserRecord:
    return AdminUserRecord(
        id=row[0],
        username=row[1],
        email=row[8] if len(row) > 8 else None,
        displayName=row[2],
        role=row[3],
        status=row[4],
        createdAt=row[5],
        lastLoginAt=row[6],
        bookCount=int(row[7] or 0) if len(row) > 7 else 0,
        isDefaultAdmin=str(row[0]) == DEFAULT_ADMIN_USER_ID,
        githubLogin=row[9] if len(row) > 9 else None,
        twoFactorEnabled=bool(row[10]) if len(row) > 10 else False,
    )


def _row_to_device(row: sqlite3.Row | tuple) -> DeviceRecord:
    platform = str(row[2] or "other").lower()
    if platform not in {"android", "windows", "linux", "macos", "ios", "other"}:
        platform = "other"
    return DeviceRecord(
        id=row[0],
        name=row[1],
        platform=platform,
        ipAddress=row[3],
        firstSeenAt=row[4],
        lastSeenAt=row[5],
        banned=bool(row[6]),
        bannedAt=row[7],
    )


def _datetime_text(value: datetime) -> str:
    normalized = value if value.tzinfo is not None else value.replace(tzinfo=UTC)
    return normalized.astimezone(UTC).isoformat().replace("+00:00", "Z")


def _parse_datetime(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return datetime.min.replace(tzinfo=UTC)
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def _normalize_book_kind(value: object) -> str:
    normalized = str(value or "").strip()
    if normalized in {"长小说", "轻小说", "漫画"}:
        return normalized
    return "轻小说"


def _normalize_language(value: object) -> str:
    normalized = str(value or "").strip()
    if normalized in {"中文", "英文", "日文"}:
        return normalized
    return "中文"


def _normalize_book_status(value: object) -> str:
    normalized = str(value or "").strip()
    if normalized in {"待处理", "解析中", "已下载", "已完成"}:
        return normalized
    return "已下载"


def _row_to_task(row: sqlite3.Row | tuple) -> TaskRecord:
    return TaskRecord(
        ownerId=row[0],
        id=row[1],
        bookId=row[2],
        taskType=row[3],
        chapterIndexes=json_load_int_list(row[4]),
        status=row[5],
        totalCount=row[6],
        completedCount=row[7],
        progress=row[8],
        message=row[9],
        error=row[10],
        attempts=row[11],
        createdAt=row[12],
        updatedAt=row[13],
    )


def _row_to_task_log(row: sqlite3.Row | tuple) -> TaskLogRecord:
    return TaskLogRecord(
        sequence=row[0],
        taskId=row[1],
        level=row[2],
        message=row[3],
        createdAt=row[4],
    )


def _row_to_book_source(row: sqlite3.Row | tuple) -> BookSourceRecord:
    payload = json_loads(row[9])
    tags = [str(item).strip() for item in payload] if isinstance(payload, list) else []
    return BookSourceRecord(
        id=row[0],
        name=row[1],
        baseUrl=row[2],
        description=row[3],
        bookKind=_normalize_optional_book_kind(row[4]),
        language=_normalize_optional_language(row[5]),
        enabled=bool(row[6]),
        supported=bool(row[7]),
        sampleUrl=row[8],
        tags=[tag for tag in tags if tag],
        origin=row[10],
        importUrl=row[11],
        status=_normalize_source_status(row[12]),
        statusMessage=row[13] or "",
        lastCheckedAt=row[14],
        rulePayload=_normalize_rule_payload(row[15]),
        createdAt=row[16],
        updatedAt=row[17],
    )


def _normalize_optional_book_kind(value: object) -> str | None:
    normalized = str(value or "").strip()
    if normalized in {"长小说", "轻小说", "漫画"}:
        return normalized
    return None


def _normalize_optional_language(value: object) -> str | None:
    normalized = str(value or "").strip()
    if normalized in {"中文", "英文", "日文"}:
        return normalized
    return None


def _normalize_rule_payload(value: object) -> dict | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        payload = json_loads(value)
    except Exception:
        return None
    return payload if isinstance(payload, dict) else None


def _normalize_source_status(value: object) -> str:
    normalized = str(value or "").strip()
    if normalized in {"unknown", "online", "slow", "offline", "unsupported"}:
        return normalized
    return "unknown"


def _seed_builtin_book_sources(conn: sqlite3.Connection) -> None:
    for source in DEFAULT_BOOK_SOURCES:
        conn.execute(
            """
            INSERT INTO book_sources (
                id, name, base_url, description, book_kind, language,
                enabled, supported, sample_url, tags, origin, import_url,
                status, status_message, last_checked_at, rule_payload, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                base_url = excluded.base_url,
                description = excluded.description,
                book_kind = excluded.book_kind,
                language = excluded.language,
                enabled = excluded.enabled,
                supported = excluded.supported,
                sample_url = excluded.sample_url,
                tags = excluded.tags,
                origin = excluded.origin,
                updated_at = excluded.updated_at
            """,
            (
                source.id,
                source.name,
                source.baseUrl,
                source.description,
                source.bookKind,
                source.language,
                int(source.enabled),
                int(source.supported),
                source.sampleUrl,
                json_dumps(source.tags),
                source.origin,
                source.importUrl,
                source.status,
                source.statusMessage,
                source.lastCheckedAt,
                json_dumps(source.rulePayload) if source.rulePayload else None,
                source.createdAt,
                datetime.now(UTC).isoformat().replace("+00:00", "Z"),
            ),
        )


def _seed_site_plugin_settings(conn: sqlite3.Connection) -> None:
    now = datetime.now(UTC).isoformat().replace("+00:00", "Z")
    for plugin in list_site_plugins():
        conn.execute(
            """
            INSERT INTO site_plugin_settings (plugin_id, enabled, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(plugin_id) DO NOTHING
            """,
            (plugin.id, int(plugin.default_enabled), now),
        )


def json_dumps(value: object) -> str:
    import json

    return json.dumps(value, ensure_ascii=False)


def json_loads(value: str) -> object:
    import json

    return json.loads(value)


def json_load_int_list(value: str) -> list[int]:
    payload = json_loads(value)
    if isinstance(payload, list):
        return [int(item) for item in payload]
    return []
