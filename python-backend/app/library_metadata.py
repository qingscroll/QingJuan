"""Editable presentation metadata, applied only at read/export boundaries."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from . import library_metadata_repository as repository
from .models import BookRecord

ReadingState = Literal["unread", "reading", "finished", "on_hold"]


class BookMetadataPatch(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    expectedRevision: int = Field(ge=0)
    title: str | None = Field(default=None, max_length=300)
    author: str | None = Field(default=None, max_length=300)
    synopsis: str | None = Field(default=None, max_length=20000)
    groupName: str | None = Field(default=None, max_length=80)
    tags: list[str] = Field(default_factory=list, max_length=20)
    pinned: bool = False
    readingState: ReadingState = "unread"

    @field_validator("title", "author", "synopsis", "groupName")
    @classmethod
    def clean_text(cls, value, info):
        if value is None:
            return value
        value = value.strip()
        if "\x00" in value:
            raise ValueError("作品信息不能包含空字符")
        if info.field_name == "title" and not value:
            raise ValueError("书名不能为空")
        if info.field_name == "groupName" and not value:
            return None
        return value

    @field_validator("tags")
    @classmethod
    def clean_tags(cls, values):
        result = []
        for tag in values:
            tag = tag.strip()
            if not tag or len(tag) > 80 or "\x00" in tag:
                raise ValueError("每个标签应包含1到80个字符")
            if tag not in result:
                result.append(tag)
        return result

    @model_validator(mode="after")
    def require_changes(self):
        if self.model_fields_set == {"expectedRevision"}:
            raise ValueError("至少修改一项作品信息")
        return self


class BookMetadata(BaseModel):
    bookId: str
    title: str
    author: str = ""
    synopsis: str = ""
    groupName: str | None = None
    tags: list[str] = Field(default_factory=list)
    pinned: bool = False
    readingState: ReadingState = "unread"
    revision: int = 0
    updatedAt: str | None = None
    overriddenFields: list[str] = Field(default_factory=list)


def read_source_manifest(book: BookRecord) -> dict:
    """Read a source snapshot within the data directory, without initializing it."""
    from . import db

    root = db.DATA_DIR.resolve()
    raw = (book.localPath or "").strip()
    if raw:
        candidate = Path(raw)
        candidate = candidate if candidate.is_absolute() else root / candidate
    else:
        title = re.sub(r'[\\/:*?"<>|]', "_", book.title).strip() or "未命名作品"
        candidate = root / "library" / f"{title}-{book.id[:8]}"
    try:
        path = (candidate / "manifest.json").resolve()
        if not path.is_relative_to(root) or not path.is_file():
            return {}
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def _text(value) -> str:
    return value.strip() if isinstance(value, str) else ""


def _effective(book: BookRecord, manifest: dict, stored: tuple) -> BookMetadata:
    overrides, revision, updated_at = stored
    return BookMetadata(
        bookId=book.id,
        title=overrides.get("title", book.title),
        author=overrides.get("author", _text(manifest.get("author"))),
        synopsis=overrides.get("synopsis", _text(manifest.get("synopsis")) or book.synopsis),
        groupName=overrides.get("groupName"),
        tags=overrides.get("tags", []),
        pinned=overrides.get("pinned", False),
        readingState=overrides.get("readingState", "reading" if book.lastReadAt else "unread"),
        revision=revision,
        updatedAt=updated_at,
        overriddenFields=[field for field in ("title", "author", "synopsis") if field in overrides],
    )


def get_book_metadata(book: BookRecord, manifest: dict | None = None) -> BookMetadata:
    source = read_source_manifest(book) if manifest is None else manifest
    return _effective(book, source, repository.load_metadata(book.id, book.ownerId))


def apply_book_metadata(book: BookRecord, manifest: dict | None = None) -> BookRecord:
    """Decorate a final response copy; never pass the result to save_book."""
    metadata = get_book_metadata(book, manifest)
    values = metadata.model_dump(
        include={"title", "author", "synopsis", "groupName", "tags", "pinned", "readingState"}
    )
    return book.model_copy(update={**values, "metadataRevision": metadata.revision})


def metadata_manifest(book: BookRecord, manifest: dict) -> dict:
    metadata = get_book_metadata(book, manifest)
    return {**manifest, "title": metadata.title, "author": metadata.author, "synopsis": metadata.synopsis}


def update_book_metadata(book: BookRecord, patch: BookMetadataPatch) -> BookMetadata:
    stored = repository.update_metadata(
        book.id,
        book.ownerId,
        patch.model_dump(exclude_unset=True, exclude={"expectedRevision"}),
        expected_revision=patch.expectedRevision,
    )
    return _effective(book, read_source_manifest(book), stored)
