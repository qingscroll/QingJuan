from . import annotations_repository as repository
from .annotations_models import AnnotationCreate, AnnotationPatch, ReadingAnnotation
from .cached_text import anchor_hash, validate_position
from .models import BookRecord


def present_annotation(book: BookRecord, annotation: ReadingAnnotation) -> ReadingAnnotation:
    current = anchor_hash(book, annotation.position) if annotation.contentHash else None
    return annotation.model_copy(
        update={"contentChanged": current is not None and current != annotation.contentHash}
    )


def list_annotations(
    book: BookRecord,
    *,
    limit: int = 50,
    offset: int = 0,
    kind: str | None = None,
    chapter_index: int | None = None,
    mode: str | None = None,
):
    annotations = repository.list_annotations(
        book.id, book.ownerId, limit=limit, offset=offset, kind=kind, chapter_index=chapter_index, mode=mode
    )
    hashes = {}
    result = []
    for annotation in annotations:
        key = (annotation.position.chapterIndex, annotation.position.contentMode)
        if annotation.contentHash and key not in hashes:
            hashes[key] = anchor_hash(book, annotation.position)
        current = hashes.get(key)
        result.append(
            annotation.model_copy(
                update={"contentChanged": current is not None and current != annotation.contentHash}
            )
        )
    return result


def create_annotation(book: BookRecord, payload: AnnotationCreate) -> ReadingAnnotation:
    validate_position(book, payload.position)
    annotation = repository.create_annotation(
        book.id, book.ownerId, payload, anchor_hash(book, payload.position)
    )
    return present_annotation(book, annotation)


def update_annotation(book: BookRecord, annotation_id: str, patch: AnnotationPatch) -> ReadingAnnotation:
    current = repository.get_annotation(book.id, book.ownerId, annotation_id)
    position = patch.position or current.position
    if patch.position is not None:
        validate_position(book, position)
    annotation = repository.update_annotation(
        book.id, book.ownerId, annotation_id, patch, anchor_hash(book, position)
    )
    return present_annotation(book, annotation)
