"""Journalled replacement of the database and library, with rollback before startup."""

from __future__ import annotations

import os
import secrets
from pathlib import Path
from typing import TYPE_CHECKING

from .backup_format import DATABASE_NAME, BackupError, private_directory, read_json, write_private_json

if TYPE_CHECKING:
    from .backup_service import BackupService

SWAPPED_NAMES = (DATABASE_NAME, DATABASE_NAME + "-wal", DATABASE_NAME + "-shm", "library")


class RestoreSwap:
    def __init__(self, service: BackupService, stage: Path, *, rollback: Path | None = None):
        self.service = service
        self.stage = stage
        self.root = service.data_dir
        self.backup = rollback or service.storage / f"rollback-{secrets.token_hex(16)}"

    def install(self) -> None:
        private_directory(self.backup)
        present = []
        for name in SWAPPED_NAMES:
            source = self.root / name
            if source.is_symlink() or getattr(source, "is_junction", lambda: False)():
                raise BackupError("恢复目标不能是符号链接")
            if source.exists():
                present.append(name)
        # Journal before the first move. Every crash window can be distinguished by
        # whether the old entry is in rollback and whether the staged entry remains.
        write_private_json(
            self.backup / "journal.json", {"stage": self.stage.name, "present": present, "committed": False}
        )
        for name in SWAPPED_NAMES:
            if name in present:
                os.replace(self.root / name, self.backup / name)
        for name in (DATABASE_NAME, "library"):
            os.replace(self.stage / name, self.root / name)

    def rollback(self) -> None:
        journal = self.backup / "journal.json"
        if not journal.exists():
            return
        record = read_json(journal.read_bytes())
        if (
            set(record) != {"stage", "present", "committed"}
            or not isinstance(record["present"], list)
            or not all(name in SWAPPED_NAMES for name in record["present"])
            or type(record["committed"]) is not bool
        ):
            raise BackupError("恢复日志无效，请保留当前数据并联系管理员")
        if record.get("committed"):
            self.service._remove(self.backup)
            return
        for name in SWAPPED_NAMES:
            saved = self.backup / name
            target = self.root / name
            if saved.exists():
                if target.exists():
                    discarded = self.backup / f"discarded-{name}"
                    os.replace(target, discarded)
                os.replace(saved, target)
            elif name not in record["present"] and target.exists():
                os.replace(target, self.backup / f"discarded-{name}")
        self.service._remove(self.backup)

    def commit(self) -> None:
        journal = self.backup / "journal.json"
        record = read_json(journal.read_bytes())
        record["committed"] = True
        temp = self.backup / "committed.json"
        write_private_json(temp, record)
        os.replace(temp, journal)
        self.service._remove(self.backup)
