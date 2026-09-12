"""Small integration hooks for regular novel translation tasks."""

from __future__ import annotations

from pathlib import Path

from .translation_quality_files import atomic_write
from .translation_quality_models import TranslationEdit, TranslationQualityError
from .translation_quality_service import get_chapter, save_chapter
from .translation_quality_usage import find_book


def prepare_novel_translation(directory: Path, index: int):
    book = find_book(directory)
    if book is None:
        return None
    try:
        return book, get_chapter(book, index)
    except TranslationQualityError as error:
        if error.status_code == 413:
            # Existing full-chapter tasks may exceed the bounded interactive editor.
            return None
        raise


def publish_novel_translation(directory: Path, filename: str, index: int, text: str, snapshot):
    if snapshot is None:
        atomic_write(directory / f"{Path(filename).stem}.translated.txt", text)
        return
    book, before = snapshot
    try:
        save_chapter(
            book,
            index,
            TranslationEdit(
                expectedRevision=before.revision,
                sourceHash=before.sourceHash,
                translationHash=before.translationHash,
                text=text,
            ),
            kind="translate",
            allow_running=True,
        )
    except TranslationQualityError:
        raise ValueError("章节内容已变化或译文保存失败，请重新加载后重试；原译文保持不变") from None
