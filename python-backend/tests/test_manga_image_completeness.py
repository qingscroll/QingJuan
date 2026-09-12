from pathlib import Path

import pytest
import test_task_publication as publication_base

from app import main

publication_runtime = publication_base.publication_runtime


@pytest.mark.asyncio
@pytest.mark.parametrize("damage", ["missing-file", "missing-reference", "duplicate", "none"])
async def test_reader_and_exports_never_select_partial_translated_pages(publication_runtime, monkeypatch, damage):
    book, directory = publication_runtime
    manifest = main.load_manifest(directory)
    translated = ["1.translated.png", "2.translated.png"]
    for source, target in zip(["1.png", "2.png"], translated, strict=True):
        (directory / target).write_bytes((directory / source).read_bytes())
    (directory / "1.translated.txt").write_text("Translated text", encoding="utf-8")
    if damage == "missing-file":
        (directory / translated[0]).unlink()
    elif damage == "missing-reference":
        translated = translated[1:]
    elif damage == "duplicate":
        translated = [translated[0], translated[0]]
    manifest["chapters"][0]["translated_image_files"] = translated
    manifest["chapters"][0]["translated"] = True
    main.save_manifest(directory, manifest)
    monkeypatch.setattr(main, "translated_image_payload_is_current", lambda *args: True)
    monkeypatch.setattr(main, "_schedule_source_chapter_cache_ahead", lambda *args: None)

    response = await main.get_chapter_content(book.id, 1, None, mode="translated", prefetch=True)
    _, single = main._load_chapter_export_item(book, 1)
    _, batch = main._load_export_chapters(book, chapter_indexes=[1])
    expected = ["1.png", "2.png"] if damage != "none" else translated
    assert [Path(source).name for source in response.imageSources] == expected
    assert [path.name for path in single["image_paths"]] == expected
    assert [path.name for path in batch[0]["image_paths"]] == expected
