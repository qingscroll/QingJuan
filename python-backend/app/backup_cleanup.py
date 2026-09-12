"""Reclaim only the regular files belonging to expired restore inspections."""

import logging
import re
import stat
from pathlib import Path

from .backup_format import COUNT_TABLES, BackupError, private_directory, read_json

_INSPECTION_FILE = re.compile(r"restore-([0-9a-f]{32})\.(zip|json)")
_LOGGER = logging.getLogger("qingjuan.backup")
_MAX_METADATA_BYTES = 64 * 1024


def _unexpired(metadata: dict, identifier: str, now: int) -> bool:
    counts = metadata.get("currentCounts")
    expiry = metadata.get("expiresAt")
    owner = metadata.get("migrationOwnerId")
    return (
        set(metadata) == {"restoreId", "sha256", "mode", "migrationOwnerId", "expiresAt", "currentCounts"}
        and metadata["restoreId"] == identifier
        and isinstance(metadata["sha256"], str)
        and re.fullmatch(r"[0-9a-f]{64}", metadata["sha256"]) is not None
        and (metadata["mode"] == "replace" and owner is None
             or metadata["mode"] == "migrate_local" and isinstance(owner, str) and bool(owner))
        and type(expiry) is int
        and expiry > now
        and isinstance(counts, dict)
        and set(counts) == set(COUNT_TABLES)
        and all(type(count) is int and count >= 0 for count in counts.values())
    )


def cleanup_inspections(storage: Path, now: int, *, invalidate_all: bool = False) -> None:
    """Caller holds the backup operation lock, or is recovering before startup.

    Process-local confirmation keys do not survive a restart, so all previous
    inspections are invalid then. Ordinary sweeps preserve unexpired pairs.
    Formal backups, extraction/rollback directories, and symlinks are untouched.
    """
    if not storage.exists():
        return
    private_directory(storage)
    records: dict[str, dict[str, Path]] = {}
    for path in storage.iterdir():
        match = _INSPECTION_FILE.fullmatch(path.name)
        if match is None:
            continue
        try:
            if stat.S_ISREG(path.lstat().st_mode):
                records.setdefault(match[1], {})[match[2]] = path
        except FileNotFoundError:
            continue
        except OSError:
            _LOGGER.warning("无法检查备份预检文件，稍后重试：%s", path.name, exc_info=True)
    for identifier, files in records.items():
        try:
            if not invalidate_all and set(files) == {"zip", "json"}:
                metadata_path = files["json"]
                if metadata_path.stat().st_size <= _MAX_METADATA_BYTES:
                    metadata = read_json(metadata_path.read_bytes())
                    if _unexpired(metadata, identifier, now):
                        continue
        except (BackupError, FileNotFoundError):
            pass
        except OSError:
            # A temporary read failure does not prove a live inspection invalid.
            _LOGGER.warning("无法读取备份预检记录，稍后重试清理：%s", identifier, exc_info=True)
            continue
        for path in files.values():
            try:
                # Never traverse a directory or follow a substituted link.
                if stat.S_ISREG(path.lstat().st_mode):
                    path.unlink()
            except FileNotFoundError:
                continue
            except OSError:
                _LOGGER.warning("无法清理备份预检文件，稍后重试：%s", path.name, exc_info=True)
