"""Publish complete manifests without truncating the previous checkpoint."""

import json
import os
from pathlib import Path
from tempfile import NamedTemporaryFile

from .storage_quota import quota_replace as replace


def save_manifest(book_dir: Path, manifest: dict) -> None:
    # Serialize before opening files: invalid data cannot disturb the old manifest.
    payload = json.dumps(manifest, ensure_ascii=False, indent=2, allow_nan=False)
    temporary = None
    try:
        with NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=book_dir,
            prefix=".manifest-", suffix=".tmp", delete=False,
        ) as handle:
            temporary = Path(handle.name)
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        replace(temporary, book_dir / "manifest.json")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
