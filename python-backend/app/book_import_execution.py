"""Import orchestration with durable ownership before any book files are written."""

from contextlib import suppress
from uuid import uuid4

from .models import BookRecord
from .storage_quota import provisional_book_storage


async def create_imported_book(runtime, payload, preview, *, owner_id, book_id=None):
    if book_id is not None:
        existing = runtime.get_book(book_id, owner_id)
        if existing is not None:
            return runtime._hydrate_book_record(existing)
    lightweight = runtime._uses_manifest_only_import(payload)
    book_id = book_id or f"book-{uuid4()}"
    root = runtime.LIBRARY_ROOT / owner_id / book_id
    with provisional_book_storage(owner_id, root):
        if lightweight:
            result = await runtime.create_book_manifest_only(payload, preview, root)
        else:
            result = await runtime.download_book(
                payload,
                preview,
                root,
                **runtime._site_account_download_kwargs(owner_id, str(payload.sourceUrl)),
            )
        record = BookRecord(
            ownerId=owner_id,
            id=book_id,
            title=result.title,
            sourceUrl=str(payload.sourceUrl),
            bookKind=preview.bookKind,
            language=payload.language,
            status="待处理" if lightweight else "已下载",
            chapterCount=len(result.chapters),
            translated=False,
            localPath=runtime._storage_key_for_path(result.local_path),
            updatedAt=runtime._now(),
            synopsis=result.synopsis,
            cover=result.cover,
        )
        runtime.save_book(record)
    # Import has already committed; periodic discovery compensates if tracking
    # registration is temporarily unavailable, without reporting a false failure.
    with suppress(Exception):
        updates = getattr(getattr(runtime.app, "state", None), "book_updates", None)
        if updates is not None:
            updates.register_book(record.id, owner_id)
    if lightweight:
        runtime._schedule_server_managed_source_cache(record)
    return runtime._hydrate_book_record(record)
