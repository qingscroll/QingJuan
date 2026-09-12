from contextlib import contextmanager
from pathlib import Path
from uuid import uuid4

from .storage_quota import quota_replace


@contextmanager
def staged_export(target: Path, owner_id: str):
    """Exports become downloadable only after the full artifact passes its quota check."""
    temporary = target.parent / f".quota-{uuid4().hex}.tmp"
    try:
        yield temporary
        quota_replace(temporary, target, owner_id=owner_id)
    finally:
        temporary.unlink(missing_ok=True)
