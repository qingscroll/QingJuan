"""Management-only complete snapshots and explicit local-to-server migration.

The injected quiesce context MUST drain foreground requests and stop all background
writers before yielding. Its reload callback runs while the same gate is still held,
and must be safe to call again after rollback. Never use only SQLite locks or the
ordinary pause-new-tasks switch as a replacement for this application-wide gate.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import os
import secrets
import shutil
import sqlite3
import time
from collections.abc import Awaitable, Callable
from contextlib import AbstractAsyncContextManager
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict

from .backup_cleanup import cleanup_inspections
from .backup_format import (
    COUNT_TABLES,
    DATABASE_NAME,
    BackupError,
    BackupLimits,
    copy_library,
    digest_file,
    extract_archive,
    library_files,
    open_database,
    private_directory,
    read_json,
    sqlite_snapshot,
    validate_database,
    write_archive,
    write_private_json,
)
from .backup_restore_state import RestoreSwap as _RestoreSwap
from .multi_user import DEFAULT_ADMIN_USER_ID, multi_user_enabled
from .two_factor import TWO_FACTOR_ENCRYPTION_KEY_ENV, decrypt_totp_secret, encrypt_totp_secret

RestoreMode = Literal["replace", "migrate_local"]
Reload = Callable[[], Awaitable[None]]
Quiesce = Callable[[str], AbstractAsyncContextManager[Reload]]
INSPECTION_TTL = 60 * 60
_LOGGER = logging.getLogger("qingjuan.backup")
ACCOUNT_TABLES = (
    "users",
    "user_sessions",
    "registration_settings",
    "email_verification_codes",
    "user_recovery_codes",
    "devices",
    "account_verified_emails",
    "account_email_challenges",
    "account_attempt_windows",
    "account_session_metadata",
    "resource_limits",
    "daily_resource_usage",
)


async def run_blocking(function, *args, **kwargs):
    """Do not release maintenance or delete staging while a cancelled worker still runs."""
    task = asyncio.create_task(asyncio.to_thread(function, *args, **kwargs))
    try:
        return await asyncio.shield(task)
    except asyncio.CancelledError:
        # A thread cannot be interrupted safely. Drain it before propagating cancellation.
        while not task.done():
            try:
                await asyncio.shield(task)
            except asyncio.CancelledError:
                continue
            except Exception:
                break
        if task.done() and not task.cancelled():
            task.exception()
        raise


class BackupArtifact(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: str
    createdAt: str
    appVersion: str
    sizeBytes: int
    sha256: str
    containsSensitiveData: Literal[True] = True
    downloadUrl: str


class BackupInspection(BaseModel):
    model_config = ConfigDict(extra="forbid")
    restoreId: str
    confirmationToken: str
    expiresAt: int
    sha256: str
    appVersion: str
    createdAt: str
    sourceMode: str
    mode: RestoreMode
    migrationOwnerId: str | None = None
    backupCounts: dict[str, int]
    currentCounts: dict[str, int]
    replacementScope: list[str]
    warnings: list[str]


class BackupRestoreResult(BaseModel):
    restored: Literal[True] = True
    mode: RestoreMode
    restoredCounts: dict[str, int]
    message: str = "备份已恢复，服务已重新加载"


class BackupService:
    def __init__(
        self, data_dir: Path, app_version: str, *, quiesce: Quiesce, limits: BackupLimits | None = None,
        cleanup_interval_seconds: float = 60,
    ):
        self.data_dir = data_dir.resolve()
        self.storage = self.data_dir / "backups"
        self.app_version = app_version
        self.quiesce = quiesce
        self.limits = limits or BackupLimits()
        self._lock = asyncio.Lock()
        self._confirmation_key = secrets.token_bytes(32)
        self._cleanup_interval_seconds = cleanup_interval_seconds
        self._cleanup_task: asyncio.Task | None = None

    def _ready(self) -> None:
        private_directory(self.storage)

    async def cleanup_expired_inspections(self) -> None:
        # Do not wait behind a restore: it may be stopping this worker to reload.
        if self._lock.locked():
            return
        async with self._lock:
            await run_blocking(cleanup_inspections, self.storage, int(time.time()))

    async def _cleanup_loop(self) -> None:
        while True:
            try:
                await self.cleanup_expired_inspections()
            except (OSError, BackupError):
                _LOGGER.warning("备份预检清理暂时失败，将在下个周期重试", exc_info=True)
            await asyncio.sleep(self._cleanup_interval_seconds)

    def start_cleanup(self) -> None:
        if self._cleanup_task is None or self._cleanup_task.done():
            self._cleanup_task = asyncio.create_task(self._cleanup_loop())

    async def stop_cleanup(self) -> None:
        if self._cleanup_task is not None:
            self._cleanup_task.cancel()
            await asyncio.gather(self._cleanup_task, return_exceptions=True)
            self._cleanup_task = None

    def _id(self, value: str) -> str:
        if len(value) != 32 or any(c not in "0123456789abcdef" for c in value):
            raise BackupError("备份记录不存在", 404)
        return value

    def _remove(self, path: Path) -> None:
        # All recursively removed paths are checked against this service's workspace.
        if (
            not path.resolve().is_relative_to(self.storage.resolve())
            or path.resolve() == self.storage.resolve()
        ):
            raise BackupError("备份清理路径无效")
        if path.is_symlink():
            raise BackupError("备份目录不能是符号链接")
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink(missing_ok=True)

    def artifact_path(self, artifact_id: str) -> Path:
        path = self.storage / f"backup-{self._id(artifact_id)}.zip"
        if not path.is_file() or path.is_symlink():
            raise BackupError("备份文件不存在，请重新创建", 404)
        return path

    def list_artifacts(self) -> list[BackupArtifact]:
        self._ready()
        records = []
        for path in self.storage.glob("backup-*.json"):
            try:
                record = BackupArtifact.model_validate(read_json(path.read_bytes()))
                self.artifact_path(record.id)
                records.append(record)
            except (BackupError, ValueError, OSError):
                continue
        return sorted(records, key=lambda record: record.createdAt, reverse=True)

    async def create(self) -> BackupArtifact:
        if self._lock.locked():
            raise BackupError("已有备份或恢复正在执行，请稍后重试", 409)
        async with self._lock, self.quiesce("export") as reload:
            try:
                return await run_blocking(self._create)
            finally:
                await reload()

    def _create(self) -> BackupArtifact:
        self._ready()
        identifier = secrets.token_hex(16)
        stage = self.storage / f"create-{identifier}"
        output = self.storage / f"backup-{identifier}.zip"
        private_directory(stage)
        try:
            sqlite_snapshot(self.data_dir / DATABASE_NAME, stage / DATABASE_NAME)
            copy_library(self.data_dir, stage)
            key = os.getenv(TWO_FACTOR_ENCRYPTION_KEY_ENV, "").strip() or None
            if multi_user_enabled() and key is None:
                raise BackupError("服务器缺少独立二次验证密钥，不能创建完整账号备份")
            write_private_json(stage / "security.json", {"schemaVersion": 1, "twoFactorEncryptionKey": key})
            validate_database(stage, normalize_from=self.data_dir)
            manifest = write_archive(
                stage,
                output,
                app_version=self.app_version,
                source_mode="multi_user" if multi_user_enabled() else "local",
                limits=self.limits,
            )
            artifact = BackupArtifact(
                id=identifier,
                createdAt=manifest["createdAt"],
                appVersion=self.app_version,
                sizeBytes=output.stat().st_size,
                sha256=digest_file(output),
                downloadUrl=f"/api/v1/backups/{identifier}/download",
            )
            write_private_json(self.storage / f"backup-{identifier}.json", artifact.model_dump())
            return artifact
        except Exception:
            output.unlink(missing_ok=True)
            raise
        finally:
            self._remove(stage)

    def _current_counts(self) -> dict[str, int]:
        if not (self.data_dir / DATABASE_NAME).exists():
            return dict.fromkeys(COUNT_TABLES, 0)
        try:
            with open_database((self.data_dir / DATABASE_NAME).as_uri() + "?mode=ro", uri=True) as conn:
                tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                return {
                    name: conn.execute(f"SELECT count(*) FROM {name}").fetchone()[0] if name in tables else 0
                    for name in COUNT_TABLES
                }
        except sqlite3.Error:
            raise BackupError("无法检查当前数据库，请先修复数据库状态") from None

    def _check_migration(self, manifest: dict, owner: str | None, counts: dict) -> None:
        if manifest["sourceMode"] != "local":
            raise BackupError("显式本机迁移只接受 Windows 本机备份")
        if not multi_user_enabled():
            raise BackupError("本机迁移的目标必须是多用户服务器")
        if any(counts[name] for name in ("books", "reading_progress", "tasks", "link_jobs")):
            raise BackupError("目标书库、任务和链接历史必须为空；请先备份并使用空的服务器实例迁移", 409)
        if library_files(self.data_dir / "library"):
            raise BackupError("目标书库仍有文件，请使用空的服务器实例迁移", 409)
        if not owner:
            raise BackupError("请选择服务器上接收本机书库的账号")
        try:
            with open_database((self.data_dir / DATABASE_NAME).as_uri() + "?mode=ro", uri=True) as conn:
                if (
                    conn.execute("SELECT 1 FROM users WHERE id=? AND status='active'", (owner,)).fetchone()
                    is None
                ):
                    raise BackupError("迁移目标账号不存在或已停用")
        except sqlite3.Error:
            raise BackupError("无法验证迁移目标账号") from None

    def _token(self, metadata: dict) -> str:
        message = json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode()
        return hmac.new(self._confirmation_key, message, hashlib.sha256).hexdigest()

    async def inspect(
        self, archive_path: Path, *, mode: RestoreMode, migration_owner_id: str | None = None
    ) -> BackupInspection:
        if self._lock.locked():
            raise BackupError("已有备份或恢复正在执行，请稍后重试", 409)
        async with self._lock:
            await run_blocking(cleanup_inspections, self.storage, int(time.time()))
            return await self._inspect(archive_path, mode=mode, migration_owner_id=migration_owner_id)

    async def _inspect(
        self, archive_path: Path, *, mode: RestoreMode, migration_owner_id: str | None = None
    ) -> BackupInspection:
        if mode not in {"replace", "migrate_local"} or (mode == "replace" and migration_owner_id):
            raise BackupError("恢复模式或迁移目标无效")
        self._ready()
        identifier = secrets.token_hex(16)
        upload = self.storage / f"restore-{identifier}.zip"
        metadata_path = self.storage / f"restore-{identifier}.json"
        stage = self.storage / f"inspect-{identifier}"
        try:
            if archive_path.stat().st_size > self.limits.archive_bytes:
                raise BackupError("备份文件超过大小上限", 413)
            await run_blocking(shutil.copyfile, archive_path, upload)
            if os.name != "nt":
                upload.chmod(0o600)
            manifest = await run_blocking(
                extract_archive, upload, stage, app_version=self.app_version, limits=self.limits
            )
            counts = await run_blocking(validate_database, stage)
            current = await run_blocking(self._current_counts)
            if mode == "migrate_local":
                await run_blocking(self._check_migration, manifest, migration_owner_id, current)
                await run_blocking(self._check_single_owner, stage)
            elif manifest["sourceMode"] == "local" and multi_user_enabled():
                raise BackupError("本机备份恢复到多用户服务器必须选择显式迁移模式")
            elif manifest["sourceMode"] == "multi_user" and not multi_user_enabled():
                raise BackupError("多用户备份必须恢复到多用户服务器，不能降为本机单用户库")
            await run_blocking(self._check_target_encryption, stage, mode)
            metadata = {
                "restoreId": identifier,
                "sha256": await run_blocking(digest_file, upload),
                "mode": mode,
                "migrationOwnerId": migration_owner_id,
                "expiresAt": int(time.time()) + INSPECTION_TTL,
                "currentCounts": current,
            }
            write_private_json(metadata_path, metadata)
            return BackupInspection(
                **metadata,
                confirmationToken=self._token(metadata),
                appVersion=manifest["appVersion"],
                createdAt=manifest["createdAt"],
                sourceMode=manifest["sourceMode"],
                backupCounts=counts,
                replacementScope=[
                    "书库文件、正文、图片、译文",
                    "阅读进度、任务及链接历史",
                    "翻译设置（含密钥）、书源与插件包/配置",
                ]
                + (
                    ["用户、登录会话、二次验证、恢复码、注册与邮件配置、设备记录"]
                    if mode == "replace"
                    else []
                ),
                warnings=[
                    "备份包含账号和服务密钥；只应保存在受保护的位置",
                    "插件包包含可执行代码，只恢复可信备份",
                    "恢复时将短暂停止业务，校验或重载失败会保留原数据",
                ]
                + (
                    ["目标账号和服务器登录配置保留；书库归属映射给所选账号，翻译设置和插件配置将被替换"]
                    if mode == "migrate_local"
                    else ["完整恢复会替换以上数据；目标服务器环境凭据与实例标识保留"]
                ),
            )
        except BaseException:
            upload.unlink(missing_ok=True)
            metadata_path.unlink(missing_ok=True)
            raise
        finally:
            if stage.exists():
                await run_blocking(self._remove, stage)

    def _check_single_owner(self, stage: Path) -> None:
        with open_database(stage / DATABASE_NAME) as conn:
            tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            for table in ("books", "tasks", "reading_progress", "reading_progress_receipts", "link_jobs", "book_metadata", "book_updates",
                "book_glossaries", "translation_quality_state", "translation_quality_history", "translation_quality_usage",
                "translation_quality_requests", "reading_annotations", "storage_provisional_roots"):
                if (
                    table in tables
                    and conn.execute(
                        f"SELECT 1 FROM {table} WHERE owner_id != ? LIMIT 1", (DEFAULT_ADMIN_USER_ID,)
                    ).fetchone()
                ):
                    raise BackupError("本机备份包含其他账号数据，不能迁移")

    def _check_target_encryption(self, stage: Path, mode: RestoreMode) -> None:
        if mode == "migrate_local":
            return
        with open_database(stage / DATABASE_NAME) as conn:
            has_two_factor = conn.execute(
                "SELECT 1 FROM users WHERE totp_secret_encrypted IS NOT NULL LIMIT 1"
            ).fetchone()
        if has_two_factor:
            key = os.getenv(TWO_FACTOR_ENCRYPTION_KEY_ENV, "").strip()
            if len(key) != 64 or any(c not in "0123456789abcdefABCDEF" for c in key):
                raise BackupError("目标服务器缺少有效的独立二次验证密钥，请完成配置后恢复")

    def _prepare(self, stage: Path, mode: RestoreMode, owner: str | None) -> None:
        if mode == "migrate_local":
            with (
                open_database(stage / DATABASE_NAME) as destination,
                open_database((self.data_dir / DATABASE_NAME).as_uri() + "?mode=ro", uri=True) as target,
            ):
                destination.execute("PRAGMA foreign_keys = OFF")
                target_tables = {
                    row[0] for row in target.execute("SELECT name FROM sqlite_master WHERE type='table'")
                }
                stage_tables = {
                    row[0] for row in destination.execute("SELECT name FROM sqlite_master WHERE type='table'")
                }
                for table in ACCOUNT_TABLES:
                    if table not in target_tables:
                        if table in stage_tables:
                            destination.execute(f"DELETE FROM {table}")
                        continue
                    if table not in stage_tables:
                        schema = target.execute(
                            "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (table,)
                        ).fetchone()[0]
                        destination.execute(schema)
                    columns = [row[1] for row in target.execute(f"PRAGMA table_info({table})")]
                    stage_columns = {row[1] for row in destination.execute(f"PRAGMA table_info({table})")}
                    if not set(columns) <= stage_columns:
                        raise BackupError("迁移数据库版本不兼容，请将本机和服务器升级到同一版本")
                    quoted = ",".join('"' + column.replace('"', '""') + '"' for column in columns)
                    destination.execute(f"DELETE FROM {table}")
                    rows = target.execute(f"SELECT {quoted} FROM {table}").fetchall()
                    destination.executemany(
                        f"INSERT INTO {table} ({quoted}) VALUES ({','.join('?' for _ in columns)})", rows
                    )
                for table in ("books", "tasks", "reading_progress", "reading_progress_receipts", "link_jobs", "book_metadata", "book_updates",
                    "book_glossaries", "translation_quality_state", "translation_quality_history", "translation_quality_usage", "reading_annotations", "storage_provisional_roots"):
                    if table in stage_tables:
                        destination.execute(f"UPDATE {table} SET owner_id=?", (owner,))
                if "translation_quality_requests" in stage_tables:
                    destination.execute("DELETE FROM translation_quality_requests")
            (stage / "security.json").unlink()
            write_private_json(
                stage / "security.json",
                {
                    "schemaVersion": 1,
                    "twoFactorEncryptionKey": os.getenv(TWO_FACTOR_ENCRYPTION_KEY_ENV, "").strip() or None,
                },
            )
        else:
            source_key = read_json((stage / "security.json").read_bytes())["twoFactorEncryptionKey"]
            target_key = os.getenv(TWO_FACTOR_ENCRYPTION_KEY_ENV, "").strip() or None
            with open_database(stage / DATABASE_NAME) as conn:
                rows = conn.execute(
                    "SELECT id, totp_secret_encrypted FROM users WHERE totp_secret_encrypted IS NOT NULL"
                ).fetchall()
                for user_id, encrypted in rows:
                    plaintext = decrypt_totp_secret(encrypted, session_secret=source_key)
                    conn.execute(
                        "UPDATE users SET totp_secret_encrypted=? WHERE id=?",
                        (encrypt_totp_secret(plaintext, session_secret=target_key), user_id),
                    )
            (stage / "security.json").unlink()
            write_private_json(
                stage / "security.json", {"schemaVersion": 1, "twoFactorEncryptionKey": target_key}
            )
        validate_database(stage)

    async def restore(self, restore_id: str, confirmation_token: str) -> BackupRestoreResult:
        identifier = self._id(restore_id)
        try:
            metadata = read_json((self.storage / f"restore-{identifier}.json").read_bytes())
        except OSError:
            raise BackupError("恢复预检已失效，请重新选择备份文件", 409) from None
        if metadata["expiresAt"] <= int(time.time()):
            await self.cleanup_expired_inspections()
            raise BackupError("恢复确认已失效，请重新预检备份", 409)
        if not hmac.compare_digest(
            self._token(metadata), confirmation_token
        ):
            raise BackupError("恢复确认已失效，请重新预检备份", 409)
        if self._lock.locked():
            raise BackupError("已有备份或恢复正在执行，请稍后重试", 409)
        async with self._lock:
            upload = self.storage / f"restore-{identifier}.zip"
            if not upload.is_file() or await run_blocking(digest_file, upload) != metadata["sha256"]:
                raise BackupError("备份文件已改变，请重新预检", 409)
            stage = self.storage / f"apply-{secrets.token_hex(16)}"
            try:
                manifest = await run_blocking(
                    extract_archive, upload, stage, app_version=self.app_version, limits=self.limits
                )
                await run_blocking(validate_database, stage)
                async with self.quiesce("restore") as reload:
                    current = await run_blocking(self._current_counts)
                    if current != metadata["currentCounts"]:
                        raise BackupError("当前数据数量已变化，请重新预检并确认恢复范围", 409)
                    if metadata["mode"] == "migrate_local":
                        await run_blocking(
                            self._check_migration, manifest, metadata["migrationOwnerId"], current
                        )
                    await run_blocking(self._check_target_encryption, stage, metadata["mode"])
                    await run_blocking(self._prepare, stage, metadata["mode"], metadata["migrationOwnerId"])
                    swap = _RestoreSwap(self, stage)
                    try:
                        await run_blocking(swap.install)
                        await reload()
                    except BaseException as error:
                        await run_blocking(swap.rollback)
                        await reload()
                        if isinstance(error, asyncio.CancelledError):
                            raise
                        raise BackupError("恢复失败，已回滚并重新加载原数据", 500) from None
                    await run_blocking(swap.commit)
                    counts = await run_blocking(self._current_counts)
                (self.storage / f"restore-{identifier}.json").unlink(missing_ok=True)
                upload.unlink(missing_ok=True)
                return BackupRestoreResult(mode=metadata["mode"], restoredCounts=counts)
            finally:
                if stage.exists():
                    await run_blocking(self._remove, stage)

    def recover_interrupted_restore(self) -> None:
        """Call before init_db, plugin imports, or any startup/background writes."""
        if self._lock.locked():
            raise BackupError("已有备份或恢复正在执行，不能执行启动恢复", 409)
        # Do not make a new data directory nonempty before db.ensure_data_dir has
        # had the opportunity to migrate a legacy installation.
        if not self.storage.exists():
            return
        self._ready()
        for rollback in self.storage.glob("rollback-*"):
            journal = rollback / "journal.json"
            if not journal.is_file():
                continue
            record = read_json(journal.read_bytes())
            stage_name = record.get("stage")
            if (
                not isinstance(stage_name, str)
                or not stage_name.startswith("apply-")
                or "/" in stage_name
                or "\\" in stage_name
            ):
                raise BackupError("恢复日志无效，请保留当前数据并联系管理员")
            stage = self.storage / stage_name
            _RestoreSwap(self, stage, rollback=rollback).rollback()
            if stage.exists():
                self._remove(stage)
        # Only actual process startup reaches here, never an in-place restore
        # reload. The new confirmation key invalidates every old inspection.
        cleanup_inspections(self.storage, int(time.time()), invalidate_all=True)
