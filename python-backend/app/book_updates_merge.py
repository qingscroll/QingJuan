"""Append new URLs while preserving every existing chapter field and index."""

import copy
from hashlib import sha256
from urllib.parse import urlparse

from .models import ChapterPreview


def manifest_chapters(manifest: dict) -> list[dict]:
    chapters = manifest.get("chapters")
    if not isinstance(chapters, list) or not chapters:
        raise ValueError("现有目录为空，无法安全追更，请重新导入作品")
    indexes = set()
    for chapter in chapters:
        if (
            not isinstance(chapter, dict)
            or type(chapter.get("index")) is not int
            or chapter["index"] <= 0
            or chapter["index"] in indexes
        ):
            raise ValueError("现有章节编号无效，无法安全追更")
        indexes.add(chapter["index"])
    return chapters


def append_new_chapters(manifest: dict, incoming: list[ChapterPreview]) -> tuple[dict, list[int]]:
    existing = manifest_chapters(manifest)
    if not incoming:
        raise ValueError("来源返回空目录，已保留原有章节，请稍后重试")
    known = {str(chapter.get("url") or "").strip() for chapter in existing} - {""}
    urls = [chapter.url.strip() for chapter in incoming]
    if any(urlparse(url).scheme not in {"http", "https"} or not urlparse(url).netloc for url in urls):
        raise ValueError("来源目录包含无效章节链接，已保留原有章节")
    if not known.intersection(urls):
        raise ValueError("来源目录与原章节没有交集，已保留原有章节，请检查原书源")
    result = copy.deepcopy(manifest)
    chapters = result["chapters"]
    index = max(chapter["index"] for chapter in existing)
    appended = []
    for chapter, url in zip(incoming, urls, strict=True):
        if url in known:
            continue
        index += 1
        known.add(url)
        appended.append(index)
        chapters.append(
            {
                "index": index,
                "title": chapter.title,
                "url": url,
                "file_name": f"{index:04d}-update-{sha256(url.encode()).hexdigest()[:10]}.txt",
                "downloaded": False,
                "translated": False,
                "translated_file_name": None,
                "translated_meta_file_name": None,
                "illustration": False,
                "image_urls": [],
                "image_files": [],
                "translated_image_files": [],
                "page_count": chapter.pageCount,
                "images_repaired": False,
                "content_source": None,
                "authorization_method": None,
                "access_restricted": chapter.accessRestricted,
                "download_error": None,
            }
        )
    result["chapter_count"] = len(chapters)
    return result, appended
