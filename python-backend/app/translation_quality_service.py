from __future__ import annotations

import json

from . import db
from . import translation_quality_repository as repository
from .storage_quota import PUBLISH_LOCK
from .translation_quality_files import (
    WRITE_LOCK,
    atomic_write,
    chapter_files,
    digest,
    prepare_journal,
    recover_journal,
)
from .translation_quality_models import (
    BookGlossary,
    ChapterTranslation,
    GlossaryPatch,
    TranslationCAS,
    TranslationEdit,
    TranslationQualityError,
    TranslationRestore,
)


def get_glossary(book) -> BookGlossary:
    if book.bookKind == "漫画":
        raise TranslationQualityError("书籍术语表目前仅适用于小说")
    with db.get_connection() as conn:
        repository.assert_owned(conn, book)
        entries, revision, updated_at = repository.glossary(conn, book)
    return BookGlossary(bookId=book.id, entries=entries, revision=revision, updatedAt=updated_at)


def save_glossary(book, payload: GlossaryPatch) -> BookGlossary:
    get_glossary(book)
    with db.get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        repository.assert_owned(conn, book)
        _, revision, _ = repository.glossary(conn, book)
        if revision != payload.expectedRevision:
            raise TranslationQualityError("术语表已被其他设备修改，请重新加载后再保存", 409)
        conn.execute(
            """INSERT INTO book_glossaries VALUES(?,?,?,?,?) ON CONFLICT(book_id) DO UPDATE SET
            entries_json=excluded.entries_json,revision=excluded.revision,updated_at=excluded.updated_at""",
            (
                book.id,
                book.ownerId,
                json.dumps([entry.model_dump() for entry in payload.entries], ensure_ascii=False),
                revision + 1,
                repository.now(),
            ),
        )
    return get_glossary(book)


def _snapshot(conn, book, index, files) -> ChapterTranslation:
    repository.assert_owned(conn, book)
    state = repository.state(conn, book, index)
    return ChapterTranslation(
        bookId=book.id,
        chapterIndex=index,
        title=files.title,
        sourceText=files.source_text,
        translatedText=files.translated_text,
        sourceHash=digest(files.source_text),
        translationHash=digest(files.translated_text),
        revision=state[0] if state else 0,
        history=repository.history(conn, book, index),
    )


def get_chapter(book, index: int) -> ChapterTranslation:
    with WRITE_LOCK:
        files = chapter_files(book, index)
        with db.get_connection() as conn:
            return _snapshot(conn, book, index, files)


def verify_cas(snapshot: ChapterTranslation, payload: TranslationCAS):
    if (snapshot.revision, snapshot.sourceHash, snapshot.translationHash) != (
        payload.expectedRevision,
        payload.sourceHash,
        payload.translationHash,
    ):
        raise TranslationQualityError("原文或译文已发生变化，请重新加载并核对后保存", 409)


def get_history(book, index: int, history_id: str):
    with db.get_connection() as conn:
        repository.assert_owned(conn, book)
        return repository.history_item(conn, book, index, history_id)


def save_chapter(book, index: int, payload: TranslationEdit, *, kind="edit", allow_running=False):
    with WRITE_LOCK:
        files = chapter_files(book, index)
        publishing = False
        try:
            with db.get_connection() as conn:
                conn.execute("BEGIN IMMEDIATE")
                PUBLISH_LOCK.acquire()
                publishing = True
                current = _snapshot(conn, book, index, files)
                verify_cas(current, payload)
                if not allow_running:
                    repository.assert_idle(conn, book)
                if payload.text == current.translatedText:
                    return current
                state = repository.state(conn, book, index)
                revision = current.revision
                if state is None and current.translatedText.strip():
                    repository.insert_history(
                        conn,
                        book,
                        index,
                        revision,
                        "initial",
                        current.sourceHash,
                        current.translationHash,
                        current.translatedText,
                    )
                elif state is not None and (
                    state[2] != current.translationHash or state[1] != current.sourceHash
                ):
                    revision += 1
                    repository.insert_history(
                        conn,
                        book,
                        index,
                        revision,
                        "external",
                        current.sourceHash,
                        current.translationHash,
                        current.translatedText,
                    )
                revision += 1
                new_hash = digest(payload.text)
                repository.insert_history(
                    conn, book, index, revision, kind, current.sourceHash, new_hash, payload.text
                )
                conn.execute(
                    """INSERT INTO translation_quality_state VALUES(?,?,?,?,?,?)
                    ON CONFLICT(book_id,chapter_index) DO UPDATE SET revision=excluded.revision,
                    source_hash=excluded.source_hash,translation_hash=excluded.translation_hash""",
                    (book.id, index, book.ownerId, revision, current.sourceHash, new_hash),
                )
                conn.execute(
                    "UPDATE books SET translated=1 WHERE id=? AND owner_id=?", (book.id, book.ownerId)
                )
                prepare_journal(files, book, index, revision, payload.text, connection=conn)
                atomic_write(files.translated, payload.text, connection=conn, owner_id=book.ownerId)
            files.journal.unlink(missing_ok=True)
        except BaseException:
            if files.journal.exists():
                recover_journal(files.journal)
            raise
        finally:
            if publishing:
                PUBLISH_LOCK.release()
        return get_chapter(book, index)


def restore_chapter(book, index: int, payload: TranslationRestore):
    with WRITE_LOCK:
        prior = get_history(book, index, payload.historyId)
        if prior.sourceHash != payload.sourceHash:
            raise TranslationQualityError("历史译文对应的原文已改变，请查看历史内容并手动校对", 409)
        return save_chapter(
            book,
            index,
            TranslationEdit(**payload.model_dump(exclude={"historyId"}), text=prior.text),
            kind="restore",
        )
