import json

import pytest

from app import cached_text as search
from app import db
from app.annotations_models import CachedTextQuery
from app.models import BookRecord


@pytest.fixture
def cached_book(monkeypatch, tmp_path):
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    folder = tmp_path / "cached"
    folder.mkdir()
    book = BookRecord(
        id="search",
        ownerId="alice",
        title="正文",
        sourceUrl="",
        bookKind="长小说",
        language="中文",
        status="已下载",
        chapterCount=3,
        translated=False,
        localPath="cached",
    )

    def install(chapters, files):
        (folder / "manifest.json").write_text(json.dumps({"chapters": chapters}), encoding="utf-8")
        for name, value in files.items():
            (folder / name).write_bytes(value.encode("utf-8") if isinstance(value, str) else value)
        return book

    return book, folder, install


def test_search_offsets_match_reader_markers_paragraph_separators_and_utf16(cached_book):
    book, _, install = cached_book
    raw = "  😀开篇\r\n\r\n\ue000\ue000  第二段 needle\nㅤㅤ  第三段 NEEDLE"
    install([{"index": 1, "title": "第一章", "file_name": "one.txt"}], {"one.txt": raw})
    normalized = "\ue000😀开篇\n\n\ue000第二段 needle\n\n\ue000第三段 NEEDLE"
    assert search.reader_text(raw) == normalized
    result = search.search_cached_text(book, CachedTextQuery(query="needle"))
    assert [hit.position.characterOffset for hit in result.results] == [
        search.utf16_length(normalized[: normalized.index("needle")]),
        search.utf16_length(normalized[: normalized.index("NEEDLE")]),
    ]
    assert result.results[0].position.anchorType == "top"
    assert result.results[0].position.layoutKey.startswith("search-utf16-v1:")
    assert result.offsetEncoding == "utf-16" and result.scannedChapters == 1


def test_literal_query_cursor_paginates_inside_and_across_chapters(cached_book):
    book, _, install = cached_book
    install([{"index": i, "file_name": f"{i}.txt"} for i in [1, 4]], {"1.txt": "a.* b a.*", "4.txt": "a.*"})
    cursor = None
    positions = []
    for _ in range(4):
        response = search.search_cached_text(book, CachedTextQuery(query="a.*", cursor=cursor, limit=1))
        positions.extend(
            (hit.position.chapterIndex, hit.position.characterOffset) for hit in response.results
        )
        cursor = response.nextCursor
        if cursor is None:
            break
    assert positions == [(1, 1), (1, 7), (4, 1)] and cursor is None
    first = search.search_cached_text(book, CachedTextQuery(query="a.*", limit=1))
    with pytest.raises(ValueError, match="游标"):
        search.search_cached_text(book, CachedTextQuery(query="different", cursor=first.nextCursor))


def test_translated_search_never_falls_back_to_original_and_skips_bad_files(cached_book):
    book, folder, install = cached_book
    install(
        [
            {"index": 1, "file_name": "one.txt"},
            {"index": 2, "file_name": "two.txt"},
            {"index": 3, "file_name": "three.txt"},
        ],
        {"one.txt": "needle", "two.translated.txt": "translated needle", "three.translated.txt": b"\xff"},
    )
    before = {path.name: path.read_bytes() for path in folder.iterdir()}
    result = search.search_cached_text(book, CachedTextQuery(query="needle", mode="translated"))
    assert len(result.results) == 1 and result.results[0].position.chapterIndex == 2
    assert result.uncachedChapters == 1 and result.skippedChapters == 1
    assert {path.name: path.read_bytes() for path in folder.iterdir()} == before


def test_scan_limits_return_resumable_cursor_and_oversized_file_is_skipped(cached_book, monkeypatch):
    book, _, install = cached_book
    install(
        [{"index": i, "file_name": f"{i}.txt"} for i in range(1, 5)],
        {"1.txt": "nothing", "2.txt": "needle", "3.txt": "needle", "4.txt": "x" * 21},
    )
    monkeypatch.setattr(search, "MAX_SCAN_CHAPTERS", 2)
    monkeypatch.setattr(search, "MAX_CHAPTER_BYTES", 20)
    first = search.search_cached_text(book, CachedTextQuery(query="needle"))
    assert first.truncated and first.nextCursor and first.scannedChapters == 2
    second = search.search_cached_text(book, CachedTextQuery(query="needle", cursor=first.nextCursor))
    assert [hit.position.chapterIndex for hit in second.results] == [3]
    assert second.skippedChapters == 1 and second.nextCursor is None


def test_untrusted_chapter_and_manifest_paths_cannot_escape_data_directory(cached_book, tmp_path):
    book, folder, install = cached_book
    secret = tmp_path / "secret.txt"
    secret.write_text("private needle", encoding="utf-8")
    install([{"index": 1, "file_name": "../secret.txt"}], {})
    assert search.search_cached_text(book, CachedTextQuery(query="needle")).uncachedChapters == 1
    with pytest.raises(ValueError, match="缓存目录"):
        search.search_cached_text(
            book.model_copy(update={"localPath": str(folder.parent.parent)}), CachedTextQuery(query="needle")
        )


def test_invalid_encoding_also_consumes_total_scan_budget(cached_book, monkeypatch):
    book, _, install = cached_book
    install(
        [{"index": i, "file_name": f"{i}.txt"} for i in range(1, 4)],
        {"1.txt": b"\xff" * 6, "2.txt": "needle", "3.txt": "needle"},
    )
    monkeypatch.setattr(search, "MAX_SCAN_BYTES", 10)
    first = search.search_cached_text(book, CachedTextQuery(query="needle"))
    assert first.results == [] and first.skippedChapters == 1 and first.nextCursor
    second = search.search_cached_text(book, CachedTextQuery(query="needle", cursor=first.nextCursor))
    assert [hit.position.chapterIndex for hit in second.results] == [2]
    assert second.nextCursor


@pytest.mark.parametrize("cursor", ["bad", "bnVsbA==", "W10=", "e30="])
def test_malformed_cursor_is_reported(cached_book, cursor):
    book, _, install = cached_book
    install([], {})
    with pytest.raises(ValueError, match="游标"):
        search.search_cached_text(book, CachedTextQuery(query="needle", cursor=cursor))
