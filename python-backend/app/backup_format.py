"""Portable, bounded archive format. Inspection never opens the live database for writing."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sqlite3
import stat
import zipfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

from .two_factor import decrypt_totp_secret

FORMAT_VERSION = 1
SERVICE_NAME = "qingjuan-backup"
DATABASE_NAME = "qingjuan.db"
REQUIRED_TABLES = {
    "users",
    "books",
    "reading_progress",
    "tasks",
    "settings",
    "site_plugin_settings",
    "site_plugin_packages",
}
COUNT_TABLES = ("books", "reading_progress", "tasks", "users", "site_plugin_packages", "link_jobs")
_RESERVED_NAMES = {
    "CON",
    "PRN",
    "AUX",
    "NUL",
    *(f"COM{i}" for i in range(10)),
    *(f"LPT{i}" for i in range(10)),
}


@contextmanager
def open_database(path, **kwargs):
    conn = sqlite3.connect(path, **kwargs)
    try:
        with conn:
            yield conn
    finally:
        conn.close()


class BackupError(ValueError):
    def __init__(self, message: str, status_code: int = 400):
        super().__init__(message)
        self.status_code = status_code


@dataclass(frozen=True)
class BackupLimits:
    archive_bytes: int = 50 * 1024**3
    expanded_bytes: int = 100 * 1024**3
    entry_bytes: int = 10 * 1024**3
    members: int = 200_000
    manifest_bytes: int = 32 * 1024**2
    compression_ratio: int = 2000


def safe_key(value: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 2048:
        raise BackupError("备份包含无效文件路径")
    path = PurePosixPath(value)
    if value != path.as_posix() or path.is_absolute() or "\\" in value:
        raise BackupError("备份文件路径不安全")
    for part in path.parts:
        if (
            part in {".", ".."}
            or part.endswith((" ", "."))
            or any(ord(c) < 32 for c in part)
            or any(c in '<>:"|?*' for c in part)
            or part.split(".")[0].upper() in _RESERVED_NAMES
        ):
            raise BackupError("备份文件路径不安全或不能跨平台迁移")
    return value


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or getattr(path, "is_junction", lambda: False)():
        raise BackupError("备份工作目录不能是符号链接")
    if os.name != "nt":
        path.chmod(0o700)


def write_private_json(path: Path, value: Any) -> None:
    with path.open("x", encoding="utf-8") as handle:
        if os.name != "nt":
            os.chmod(path, 0o600)
        json.dump(value, handle, ensure_ascii=False, separators=(",", ":"))
        handle.flush()
        os.fsync(handle.fileno())


def read_json(data: bytes) -> dict:
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise BackupError("备份 JSON 包含重复字段")
            result[key] = value
        return result

    try:
        result = json.loads(data, object_pairs_hook=pairs)
        if not isinstance(result, dict):
            raise ValueError
        return result
    except (ValueError, UnicodeDecodeError, RecursionError):
        raise BackupError("备份清单格式无效") from None


def sqlite_snapshot(source: Path, destination: Path) -> None:
    if not source.is_file() or source.is_symlink():
        raise BackupError("没有可备份的数据库")
    try:
        with open_database(source.as_uri() + "?mode=ro", uri=True) as src, open_database(destination) as dst:
            src.backup(dst)
            dst.execute("PRAGMA journal_mode = DELETE")
    except sqlite3.Error:
        raise BackupError("数据库快照创建失败，请检查磁盘空间和数据库状态") from None
    if os.name != "nt":
        destination.chmod(0o600)


def library_files(root: Path) -> list[Path]:
    if root.is_symlink() or getattr(root, "is_junction", lambda: False)():
        raise BackupError("书库不能是符号链接")
    if not root.exists():
        return []
    result = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        current = Path(directory)
        for name in [*dirs, *files]:
            item = current / name
            if item.is_symlink() or getattr(item, "is_junction", lambda: False)():
                raise BackupError("书库包含符号链接，无法创建完整备份")
            if not item.is_dir() and not item.is_file():
                raise BackupError("书库包含不支持的文件类型")
        result.extend(current / name for name in sorted(files))
    return sorted(result)


def write_archive(
    staging: Path, output: Path, *, app_version: str, source_mode: str, limits: BackupLimits
) -> dict:
    paths = [staging / DATABASE_NAME, staging / "security.json", *library_files(staging / "library")]
    if len(paths) + 1 > limits.members:
        raise BackupError("书库文件数量超过备份上限", 413)
    files = {}
    total = 0
    for path in paths:
        key = safe_key(path.relative_to(staging).as_posix())
        size = path.stat().st_size
        total += size
        if size > limits.entry_bytes or total > limits.expanded_bytes:
            raise BackupError("书库大小超过备份上限", 413)
        files[key] = {"size": size, "sha256": digest_file(path)}
    from datetime import UTC, datetime

    manifest = {
        "format": SERVICE_NAME,
        "schemaVersion": FORMAT_VERSION,
        "appVersion": app_version,
        "createdAt": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "sourceMode": source_mode,
        "containsSensitiveData": True,
        "files": files,
        "directories": sorted(
            {
                "library",
                *(
                    safe_key(Path(directory).relative_to(staging).as_posix())
                    for directory, _, _ in os.walk(staging / "library")
                ),
            }
        ),
    }
    encoded = json.dumps(manifest, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(encoded) > limits.manifest_bytes:
        raise BackupError("备份清单超过大小上限", 413)
    with output.open("xb") as handle:
        if os.name != "nt":
            output.chmod(0o600)
        with zipfile.ZipFile(
            handle, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True
        ) as archive:
            archive.writestr("manifest.json", encoded)
            for key in files:
                archive.write(staging / key, key)
    if output.stat().st_size > limits.archive_bytes:
        raise BackupError("备份压缩包超过大小上限", 413)
    return manifest


def _version(value: str) -> tuple[int, int, int]:
    if not isinstance(value, str) or not re.fullmatch(r"\d+\.\d+\.\d+", value):
        raise BackupError("备份应用版本无效")
    return tuple(int(part) for part in value.split("."))


def extract_archive(archive_path: Path, staging: Path, *, app_version: str, limits: BackupLimits) -> dict:
    if archive_path.stat().st_size > limits.archive_bytes:
        raise BackupError("备份压缩包超过大小上限", 413)
    private_directory(staging)
    try:
        with zipfile.ZipFile(archive_path) as archive:
            infos = archive.infolist()
            if len(infos) > limits.members:
                raise BackupError("备份文件数量超过上限", 413)
            entries = {}
            casefolded = set()
            total = 0
            for info in infos:
                key = safe_key(info.filename)
                mode = info.external_attr >> 16
                if (
                    info.is_dir()
                    or stat.S_ISLNK(mode)
                    or stat.S_IFMT(mode) not in {0, stat.S_IFREG}
                    or info.flag_bits & 1
                    or info.compress_type not in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}
                ):
                    raise BackupError("备份包含不支持或不安全的文件类型")
                if key.casefold() in casefolded:
                    raise BackupError("备份包含重复文件路径")
                if key not in {"manifest.json", DATABASE_NAME, "security.json"} and not key.startswith(
                    "library/"
                ):
                    raise BackupError("备份包含范围外文件")
                total += info.file_size
                if (
                    info.file_size > limits.entry_bytes
                    or total > limits.expanded_bytes
                    or info.file_size > max(info.compress_size, 1) * limits.compression_ratio
                ):
                    raise BackupError("备份解压大小或压缩比例超过上限", 413)
                entries[key] = info
                casefolded.add(key.casefold())
            if not {"manifest.json", DATABASE_NAME, "security.json"} <= entries.keys():
                raise BackupError("备份缺少数据库、安全材料或清单")
            if entries["manifest.json"].file_size > limits.manifest_bytes:
                raise BackupError("备份清单超过大小上限", 413)
            manifest = read_json(archive.read("manifest.json"))
            if manifest.get("format") != SERVICE_NAME or manifest.get("schemaVersion") != FORMAT_VERSION:
                raise BackupError("不支持此备份格式版本，请升级后端后重试")
            if _version(manifest.get("appVersion")) > _version(app_version):
                raise BackupError("备份来自较新应用版本，请先升级后端")
            if (
                manifest.get("sourceMode") not in {"local", "multi_user"}
                or manifest.get("containsSensitiveData") is not True
            ):
                raise BackupError("备份来源信息无效")
            files = manifest.get("files")
            if not isinstance(files, dict) or set(files) != entries.keys() - {"manifest.json"}:
                raise BackupError("备份文件与清单不一致")
            directories = manifest.get("directories")
            if (
                not isinstance(directories, list)
                or len(directories) > limits.members
                or not all(isinstance(key, str) for key in directories)
                or len({key.casefold() for key in directories}) != len(directories)
            ):
                raise BackupError("备份目录清单无效")
            for key in directories:
                safe_key(key)
                if (key != "library" and not key.startswith("library/")) or key.casefold() in casefolded:
                    raise BackupError("备份目录清单存在路径冲突")
                private_directory(staging / key)
            for key, expected in files.items():
                if (
                    not isinstance(expected, dict)
                    or set(expected) != {"size", "sha256"}
                    or type(expected["size"]) is not int
                    or expected["size"] != entries[key].file_size
                    or not isinstance(expected["sha256"], str)
                    or not re.fullmatch(r"[0-9a-f]{64}", expected["sha256"])
                ):
                    raise BackupError("备份文件校验清单无效")
                path = staging / safe_key(key)
                private_directory(path.parent)
                digest = hashlib.sha256()
                written = 0
                with archive.open(key) as src, path.open("xb") as dst:
                    if os.name != "nt":
                        path.chmod(0o600)
                    for block in iter(lambda: src.read(1024 * 1024), b""):
                        written += len(block)
                        if written > expected["size"]:
                            raise BackupError("备份文件解压大小不符")
                        digest.update(block)
                        dst.write(block)
                if written != expected["size"] or digest.hexdigest() != expected["sha256"]:
                    raise BackupError("备份文件校验失败，文件可能已损坏")
            return manifest
    except (zipfile.BadZipFile, zipfile.LargeZipFile, RuntimeError, EOFError, OSError):
        raise BackupError("备份压缩包无效或无法读取，请检查文件和磁盘空间") from None


def validate_database(root: Path, *, normalize_from: Path | None = None) -> dict[str, int]:
    """Validate a staged DB and its referenced files without executing application/plugin code."""
    database = root / DATABASE_NAME
    try:
        with open_database(database) as conn:
            conn.execute("PRAGMA trusted_schema = OFF")
            tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if not tables >= REQUIRED_TABLES:
                raise BackupError("备份数据库缺少必要的数据表")
            if conn.execute(
                "SELECT 1 FROM sqlite_master WHERE type IN ('trigger', 'view') OR sql LIKE '%VIRTUAL TABLE%' LIMIT 1"
            ).fetchone():
                raise BackupError("备份数据库包含不支持的可执行结构")
            if (
                conn.execute("PRAGMA integrity_check").fetchall() != [("ok",)]
                or conn.execute("PRAGMA foreign_key_check").fetchone()
            ):
                raise BackupError("备份数据库完整性检查失败")
            users = {row[0] for row in conn.execute("SELECT id FROM users")}
            for table in ("resource_limits", "daily_resource_usage"):
                if table in tables and any(
                    owner not in users for (owner,) in conn.execute(f"SELECT owner_id FROM {table}")
                ):
                    raise BackupError("备份资源限制或用量缺少对应账号")
            books = {}
            book_keys = {}
            for book_id, owner, raw in conn.execute("SELECT id, owner_id, local_path FROM books").fetchall():
                if owner not in users:
                    raise BackupError("备份书籍账号归属不完整")
                key = str(raw)
                if normalize_from is not None and Path(key).is_absolute():
                    resolved = Path(key).resolve()
                    if not resolved.is_relative_to(normalize_from.resolve()):
                        raise BackupError("书籍路径不在数据目录内，无法跨平台备份")
                    key = resolved.relative_to(normalize_from.resolve()).as_posix()
                    conn.execute("UPDATE books SET local_path=? WHERE id=?", (key, book_id))
                safe_key(key)
                if not key.startswith("library/") or not (root / key).is_dir():
                    raise BackupError("备份书籍路径无效或缺少书籍目录")
                books[book_id] = owner
                book_keys[book_id] = key
            if "storage_provisional_roots" in tables:
                owned_paths = [(book_keys[book_id], owner) for book_id, owner in books.items()]
                for key, owner in conn.execute("SELECT storage_key,owner_id FROM storage_provisional_roots"):
                    safe_key(key)
                    if owner not in users or not key.startswith("library/"):
                        raise BackupError("临时书库目录或账号归属无效")
                    if (root / key).exists() and not (root / key).is_dir():
                        raise BackupError("临时书库目录无效")
                    for previous, previous_owner in owned_paths:
                        if previous_owner != owner and (
                            Path(previous).is_relative_to(Path(key)) or Path(key).is_relative_to(Path(previous))
                        ):
                            raise BackupError("临时书库与其他账号目录重叠")
                    owned_paths.append((key, owner))
            for table in ("reading_progress", "tasks", "reading_progress_receipts", "book_metadata", "book_updates", "book_glossaries",
                "translation_quality_state", "translation_quality_history", "translation_quality_usage", "translation_quality_requests",
                "reading_annotations"):
                if table not in tables:
                    continue
                for book_id, owner in conn.execute(f"SELECT book_id, owner_id FROM {table}"):
                    if books.get(book_id) != owner:
                        raise BackupError("备份阅读记录或任务与书籍归属不一致")
            if "link_jobs" in tables:
                for identifier, owner, raw in conn.execute(
                    "SELECT id, owner_id, record FROM link_jobs"
                ).fetchall():
                    if owner not in users:
                        raise BackupError("备份链接任务账号归属不完整")
                    record = read_json(raw.encode("utf-8"))
                    embedded_book = record.get("book")
                    if embedded_book is not None:
                        if not isinstance(embedded_book, dict):
                            raise BackupError("备份链接任务书籍信息无效")
                        # Import history can legitimately refer to a subsequently deleted book.
                        if embedded_book.get("id") in book_keys:
                            embedded_book["localPath"] = book_keys[embedded_book["id"]]
                        elif embedded_book.get("localPath"):
                            safe_key(embedded_book["localPath"])
                        embedded_book["ownerId"] = owner
                        conn.execute(
                            "UPDATE link_jobs SET record=? WHERE id=?",
                            (json.dumps(record, ensure_ascii=False), identifier),
                        )
            from .plugin_system.manifest import PluginManifest, PluginPackageError
            from .plugin_system.packages import inspect_package

            for plugin_id, raw_manifest, package, digest in conn.execute(
                "SELECT plugin_id, manifest_json, package, sha256 FROM site_plugin_packages"
            ):
                if hashlib.sha256(package).hexdigest() != digest:
                    raise BackupError("备份插件包完整性检查失败")
                try:
                    manifest, _ = inspect_package(package)
                    recorded = PluginManifest.model_validate_json(raw_manifest)
                    if manifest.id != plugin_id or manifest != recorded:
                        raise BackupError("备份插件清单与插件包不一致")
                except (PluginPackageError, ValueError):
                    raise BackupError("备份插件包格式或版本不兼容，请修复插件后重新备份") from None
            security = read_json((root / "security.json").read_bytes())
            if security.get("schemaVersion") != 1 or set(security) != {
                "schemaVersion",
                "twoFactorEncryptionKey",
            }:
                raise BackupError("备份安全材料格式不支持")
            key = security.get("twoFactorEncryptionKey")
            if key is not None and (not isinstance(key, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", key)):
                raise BackupError("备份独立二次验证密钥无效")
            for (secret,) in conn.execute(
                "SELECT totp_secret_encrypted FROM users WHERE totp_secret_encrypted IS NOT NULL"
            ):
                if not key:
                    raise BackupError("备份缺少独立二次验证密钥，不能完整恢复账号")
                try:
                    decrypt_totp_secret(secret, session_secret=key)
                except (ValueError, RuntimeError):
                    raise BackupError("备份二次验证密钥与数据库不匹配") from None
            return {
                table: conn.execute(f"SELECT count(*) FROM {table}").fetchone()[0] if table in tables else 0
                for table in COUNT_TABLES
            }
    except (sqlite3.Error, OSError, TypeError):
        raise BackupError("备份数据库或安全材料无法验证") from None


def copy_library(source: Path, staging: Path) -> None:
    private_directory(staging / "library")
    for path in library_files(source / "library"):
        key = safe_key(path.relative_to(source).as_posix())
        destination = staging / key
        private_directory(destination.parent)
        shutil.copyfile(path, destination)
        if os.name != "nt":
            destination.chmod(0o600)
    # Empty book folders are legitimate (a queued import has no downloaded content yet).
    if (source / "library").exists():
        for directory, _, _ in os.walk(source / "library"):
            key = safe_key(Path(directory).relative_to(source).as_posix())
            private_directory(staging / key)
