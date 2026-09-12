from __future__ import annotations

import posixpath
import re
import zipfile
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote
from xml.etree import ElementTree

from bs4 import BeautifulSoup

SUPPORTED_LOCAL_EXTENSIONS = frozenset({".txt", ".text", ".docx", ".epub", ".pdf"})
NOVEL_EXTENSIONS = frozenset({".txt", ".text", ".docx", ".epub"})
LOCAL_FILE_SIZE_LIMITS = {
    ".txt": 64 * 1024 * 1024,
    ".text": 64 * 1024 * 1024,
    ".docx": 256 * 1024 * 1024,
    ".epub": 256 * 1024 * 1024,
    ".pdf": 1024 * 1024 * 1024,
}
MAX_ARCHIVE_ENTRIES = 10_000
MAX_ARCHIVE_UNCOMPRESSED_BYTES = 512 * 1024 * 1024
MAX_PDF_PAGES = 5_000
PDF_RENDER_SCALE = 2.0
PDF_MAX_EDGE = 6_000


class LocalImportError(ValueError):
    pass


@dataclass(frozen=True)
class LocalChapter:
    title: str
    content: str


@dataclass(frozen=True)
class LocalImportPlan:
    source_format: str
    title: str
    author: str | None
    synopsis: str
    book_kind: str
    chapters: tuple[LocalChapter, ...] = ()
    page_count: int = 0


def inspect_local_document(
    source_path: Path,
    *,
    original_name: str,
    requested_kind: str,
    text_encoding: str = "auto",
) -> LocalImportPlan:
    suffix = Path(original_name).suffix.lower() or source_path.suffix.lower()
    _validate_source_file(source_path, suffix)
    fallback_title = Path(original_name).stem.strip() or "未命名本地作品"

    if suffix in {".txt", ".text"}:
        content = _decode_text(source_path.read_bytes(), encoding=text_encoding)
        chapters = _split_novel_into_chapters(content)
        return LocalImportPlan(
            source_format=suffix.removeprefix(".").upper(),
            title=fallback_title,
            author=None,
            synopsis="",
            book_kind=_novel_kind(requested_kind),
            chapters=tuple(LocalChapter(title, body) for title, body in chapters),
        )
    if suffix == ".docx":
        return _inspect_docx(source_path, fallback_title, requested_kind)
    if suffix == ".epub":
        return _inspect_epub(source_path, fallback_title, requested_kind)
    if suffix == ".pdf":
        return _inspect_pdf(source_path, fallback_title)
    if suffix == ".doc":
        raise LocalImportError("暂不支持旧版 DOC 文件，请先使用 Word 另存为 DOCX 后再导入")
    raise LocalImportError("不支持该文件格式；小说支持 TXT、TEXT、DOCX、EPUB，漫画支持 PDF")


def write_local_document(
    plan: LocalImportPlan,
    source_path: Path,
    book_dir: Path,
) -> list[dict[str, object]]:
    book_dir.mkdir(parents=True, exist_ok=True)
    if plan.source_format == "PDF":
        return _render_pdf_manga(source_path, book_dir, plan)
    return _write_text_chapters(book_dir, plan.chapters)


def _validate_source_file(source_path: Path, suffix: str) -> None:
    if suffix == ".doc":
        raise LocalImportError("暂不支持旧版 DOC 文件，请先使用 Word 另存为 DOCX 后再导入")
    if suffix not in SUPPORTED_LOCAL_EXTENSIONS:
        raise LocalImportError("不支持该文件格式；小说支持 TXT、TEXT、DOCX、EPUB，漫画支持 PDF")
    try:
        size = source_path.stat().st_size
    except OSError as exc:
        raise LocalImportError(f"无法读取本地文件：{exc}") from exc
    if size <= 0:
        raise LocalImportError("本地文件为空")
    limit = LOCAL_FILE_SIZE_LIMITS[suffix]
    if size > limit:
        raise LocalImportError(f"{suffix.removeprefix('.').upper()} 文件超过 {limit // 1024 // 1024} MB 限制")


def _novel_kind(requested_kind: str) -> str:
    return requested_kind if requested_kind in {"长小说", "轻小说"} else "长小说"


def _decode_text(raw_content: bytes, *, encoding: str = "auto") -> str:
    supported = {"utf-8": "utf-8-sig", "gb18030": "gb18030", "big5": "big5", "shift_jis": "shift_jis"}
    if encoding != "auto":
        if encoding not in supported:
            raise LocalImportError("不支持该文本编码，请选择 UTF-8、GB18030、Big5 或 Shift-JIS")
        try:
            content = raw_content.decode(supported[encoding])
        except UnicodeDecodeError as exc:
            raise LocalImportError("文件与所选文本编码不匹配，请重新选择编码或转换为 UTF-8") from exc
    elif raw_content.startswith((b"\xff\xfe", b"\xfe\xff")):
        try:
            content = raw_content.decode("utf-16")
        except UnicodeDecodeError as exc:
            raise LocalImportError("UTF-16 文本已损坏，请转换为 UTF-8 后重试") from exc
    else:
        try:
            content = raw_content.decode("utf-8-sig")
        except UnicodeDecodeError:
            # Legacy encodings overlap: a successful decode alone cannot select
            # GB18030 over Big5 or Shift-JIS without silently corrupting text.
            candidates = set()
            for codec in ("gb18030", "big5", "shift_jis"):
                try:
                    candidates.add(raw_content.decode(codec))
                except UnicodeDecodeError:
                    continue
            if len(candidates) != 1:
                raise LocalImportError("无法可靠识别文本编码，请选择 GB18030、Big5 或 Shift-JIS，或转换为 UTF-8") from None
            content = candidates.pop()
    if not content.strip():
        raise LocalImportError("文本文件没有可导入的正文")
    return content.replace("\r\n", "\n").replace("\r", "\n")


def _split_novel_into_chapters(content: str) -> list[tuple[str, str]]:
    normalized = content.replace("\ufeff", "").strip()
    if not normalized:
        return [("第1章", "")]
    chapter_heading = re.compile(
        r"(?im)^(?P<title>\s*(?:章节目录\s*)?(?:第\s*[0-9零一二三四五六七八九十百千万两〇]+(?:章|节|卷|回|部|篇)[^\n]*|chapter\s+\d+[^\n]*))\s*$"
    )
    matches = list(chapter_heading.finditer(normalized))
    if not matches:
        return [("第1章", normalized)]

    chapters: list[tuple[str, str]] = []
    preamble = normalized[:matches[0].start()].strip()
    for index, match in enumerate(matches):
        title = _normalize_chapter_title(match.group("title"), index + 1)
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(normalized)
        body = normalized[start:end].strip()
        if body:
            chapters.append((title or f"第{index + 1}章", body))
    if not chapters:
        return [("第1章", normalized)]
    if preamble:
        chapters.insert(0, ("序章", preamble))
    return chapters


def _normalize_chapter_title(raw_title: str, chapter_number: int) -> str:
    normalized = re.sub(r"^\s*章节目录\s*", "", raw_title.strip(), flags=re.I)
    normalized = re.sub(r"\s+", " ", normalized).strip()
    if not normalized:
        return f"第{chapter_number}章"
    match = re.match(
        r"^(第\s*[0-9零一二三四五六七八九十百千万两〇]+(?:章|节|卷|回|部|篇))(?P<suffix>.*)$",
        normalized,
        flags=re.I,
    )
    if not match:
        return normalized
    prefix = re.sub(r"\s+", "", match.group(1))
    suffix = re.sub(r"\s+", " ", match.group("suffix") or "").strip()
    return f"{prefix} {suffix}".strip()


def _open_archive(source_path: Path, label: str) -> zipfile.ZipFile:
    try:
        archive = zipfile.ZipFile(source_path)
        infos = archive.infolist()
    except (OSError, zipfile.BadZipFile) as exc:
        raise LocalImportError(f"{label} 文件已损坏或不是有效的 {label} 文档") from exc
    if len(infos) > MAX_ARCHIVE_ENTRIES:
        archive.close()
        raise LocalImportError(f"{label} 文件包含过多项目")
    if sum(info.file_size for info in infos) > MAX_ARCHIVE_UNCOMPRESSED_BYTES:
        archive.close()
        raise LocalImportError(f"{label} 解压后内容超过 512 MB 限制")
    return archive


def _read_archive_member(archive: zipfile.ZipFile, member: str, label: str) -> bytes:
    normalized = posixpath.normpath(unquote(member.replace("\\", "/")))
    if normalized.startswith("../") or normalized.startswith("/") or normalized == "..":
        raise LocalImportError(f"{label} 包含不安全的文件路径")
    try:
        return archive.read(normalized)
    except KeyError as exc:
        raise LocalImportError(f"{label} 缺少必要文件：{normalized}") from exc


def _xml_text(root: ElementTree.Element, local_name: str) -> str:
    for node in root.iter():
        if node.tag.rsplit("}", 1)[-1] == local_name and (node.text or "").strip():
            return (node.text or "").strip()
    return ""


def _inspect_docx(source_path: Path, fallback_title: str, requested_kind: str) -> LocalImportPlan:
    archive = _open_archive(source_path, "DOCX")
    try:
        try:
            document = ElementTree.fromstring(_read_archive_member(archive, "word/document.xml", "DOCX"))
        except ElementTree.ParseError as exc:
            raise LocalImportError("DOCX 正文 XML 已损坏") from exc
        metadata: ElementTree.Element | None = None
        if "docProps/core.xml" in archive.namelist():
            try:
                metadata = ElementTree.fromstring(archive.read("docProps/core.xml"))
            except ElementTree.ParseError:
                metadata = None
    finally:
        archive.close()

    namespace = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}
    paragraphs: list[tuple[str, bool]] = []
    for paragraph in document.findall(".//w:body//w:p", namespace):
        text = "".join(node.text or "" for node in paragraph.findall(".//w:t", namespace)).strip()
        if not text:
            continue
        style = paragraph.find("./w:pPr/w:pStyle", namespace)
        style_name = "" if style is None else str(style.attrib.get(f"{{{namespace['w']}}}val") or "")
        paragraphs.append((text, style_name.lower().startswith("heading")))
    if not paragraphs:
        raise LocalImportError("DOCX 中没有可导入的文字内容")

    chapters = _chapters_from_styled_paragraphs(paragraphs)
    return LocalImportPlan(
        source_format="DOCX",
        title=(_xml_text(metadata, "title") or fallback_title) if metadata is not None else fallback_title,
        author=(_xml_text(metadata, "creator") or None) if metadata is not None else None,
        synopsis=_xml_text(metadata, "description") if metadata is not None else "",
        book_kind=_novel_kind(requested_kind),
        chapters=tuple(LocalChapter(title, body) for title, body in chapters),
    )


def _chapters_from_styled_paragraphs(paragraphs: list[tuple[str, bool]]) -> list[tuple[str, str]]:
    if not any(is_heading for _, is_heading in paragraphs):
        return _split_novel_into_chapters("\n".join(text for text, _ in paragraphs))
    chapters: list[tuple[str, str]] = []
    current_title = "序章"
    current_body: list[str] = []
    for text, is_heading in paragraphs:
        if is_heading:
            if current_body:
                chapters.append((current_title, "\n".join(current_body).strip()))
            current_title = text
            current_body = []
        else:
            current_body.append(text)
    if current_body:
        chapters.append((current_title, "\n".join(current_body).strip()))
    return chapters or _split_novel_into_chapters("\n".join(text for text, _ in paragraphs))


def _inspect_epub(source_path: Path, fallback_title: str, requested_kind: str) -> LocalImportPlan:
    archive = _open_archive(source_path, "EPUB")
    try:
        try:
            container = ElementTree.fromstring(
                _read_archive_member(archive, "META-INF/container.xml", "EPUB")
            )
        except ElementTree.ParseError as exc:
            raise LocalImportError("EPUB container.xml 已损坏") from exc
        rootfile = next(
            (
                str(node.attrib.get("full-path") or "").strip()
                for node in container.iter()
                if node.tag.rsplit("}", 1)[-1] == "rootfile"
            ),
            "",
        )
        if not rootfile:
            raise LocalImportError("EPUB 未声明 OPF 内容文件")
        try:
            package = ElementTree.fromstring(_read_archive_member(archive, rootfile, "EPUB"))
        except ElementTree.ParseError as exc:
            raise LocalImportError("EPUB OPF 内容已损坏") from exc

        manifest: dict[str, str] = {}
        for node in package.iter():
            if node.tag.rsplit("}", 1)[-1] != "item":
                continue
            item_id = str(node.attrib.get("id") or "").strip()
            href = str(node.attrib.get("href") or "").strip()
            media_type = str(node.attrib.get("media-type") or "").lower()
            if item_id and href and media_type in {"application/xhtml+xml", "text/html"}:
                manifest[item_id] = href
        spine_ids = [
            str(node.attrib.get("idref") or "").strip()
            for node in package.iter()
            if node.tag.rsplit("}", 1)[-1] == "itemref"
        ]
        opf_dir = posixpath.dirname(posixpath.normpath(rootfile.replace("\\", "/")))
        chapters: list[LocalChapter] = []
        for item_id in spine_ids:
            href = manifest.get(item_id)
            if not href:
                continue
            member = posixpath.join(opf_dir, href.split("#", 1)[0])
            raw_html = _read_archive_member(archive, member, "EPUB")
            soup = BeautifulSoup(raw_html, "html.parser")
            for ignored in soup.select("script, style, nav"):
                ignored.decompose()
            heading = soup.select_one("h1, h2, h3")
            title = heading.get_text(" ", strip=True) if heading is not None else ""
            if heading is not None:
                heading.decompose()
            if not title and soup.title is not None:
                title = soup.title.get_text(" ", strip=True)
            body = soup.body or soup
            text = body.get_text("\n", strip=True)
            if text:
                chapters.append(LocalChapter(title or f"第{len(chapters) + 1}章", text))
        if not chapters:
            raise LocalImportError("EPUB 书脊中没有可导入的章节内容")
        return LocalImportPlan(
            source_format="EPUB",
            title=_xml_text(package, "title") or fallback_title,
            author=_xml_text(package, "creator") or None,
            synopsis=_xml_text(package, "description"),
            book_kind=_novel_kind(requested_kind),
            chapters=tuple(chapters),
        )
    finally:
        archive.close()


def _inspect_pdf(source_path: Path, fallback_title: str) -> LocalImportPlan:
    try:
        import pypdfium2 as pdfium

        document = pdfium.PdfDocument(str(source_path))
    except Exception as exc:
        raise LocalImportError("PDF 文件已损坏、受密码保护或无法读取") from exc
    try:
        page_count = len(document)
    finally:
        document.close()
    if page_count <= 0:
        raise LocalImportError("PDF 中没有可导入的页面")
    if page_count > MAX_PDF_PAGES:
        raise LocalImportError(f"PDF 页数超过 {MAX_PDF_PAGES} 页限制")
    return LocalImportPlan(
        source_format="PDF",
        title=fallback_title,
        author=None,
        synopsis=f"从本地 PDF 导入，共 {page_count} 页",
        book_kind="漫画",
        page_count=page_count,
    )


def _write_text_chapters(
    book_dir: Path,
    chapters: tuple[LocalChapter, ...],
) -> list[dict[str, object]]:
    from .storage_quota import quota_write_text

    chapter_manifest: list[dict[str, object]] = []
    for index, chapter in enumerate(chapters, start=1):
        safe_title = _sanitize_title(chapter.title)[:80]
        file_name = f"{index:04d}-{safe_title}.txt"
        quota_write_text(book_dir / file_name, chapter.content.strip())
        chapter_manifest.append(_chapter_manifest(index, chapter.title, file_name))
    return chapter_manifest


def _render_pdf_manga(
    source_path: Path,
    book_dir: Path,
    plan: LocalImportPlan,
) -> list[dict[str, object]]:
    from io import BytesIO

    from .storage_quota import quota_write_bytes, quota_write_text

    try:
        import pypdfium2 as pdfium

        document = pdfium.PdfDocument(str(source_path))
    except Exception as exc:
        raise LocalImportError("PDF 文件已损坏、受密码保护或无法读取") from exc
    images_dir = book_dir / "images"
    images_dir.mkdir(parents=True, exist_ok=True)
    image_files: list[str] = []
    try:
        for page_index in range(len(document)):
            page = document[page_index]
            bitmap = None
            try:
                width, height = page.get_size()
                scale = min(PDF_RENDER_SCALE, PDF_MAX_EDGE / max(width, height))
                bitmap = page.render(scale=max(scale, 0.25))
                source_image = bitmap.to_pil()
                image = source_image
                try:
                    if image.mode not in {"RGB", "RGBA"}:
                        image = image.convert("RGB")
                    file_name = f"0001-{page_index + 1:04d}.png"
                    with BytesIO() as encoded:
                        image.save(encoded, format="PNG", optimize=True)
                        quota_write_bytes(images_dir / file_name, encoded.getvalue())
                finally:
                    image.close()
                    if source_image is not image:
                        source_image.close()
                image_files.append(f"images/{file_name}")
            finally:
                if bitmap is not None:
                    bitmap.close()
                page.close()
    except Exception as exc:
        raise LocalImportError(f"PDF 第 {len(image_files) + 1} 页渲染失败：{exc}") from exc
    finally:
        document.close()

    chapter_title = plan.title or "PDF 漫画"
    file_name = f"0001-{_sanitize_title(chapter_title)}.txt"
    quota_write_text(book_dir / file_name, f"{chapter_title}\n\nPDF 漫画，共 {len(image_files)} 页。")
    manifest = _chapter_manifest(1, chapter_title, file_name)
    manifest.update(
        {
            "image_files": image_files,
            "page_count": len(image_files),
        }
    )
    return [manifest]


def _chapter_manifest(index: int, title: str, file_name: str) -> dict[str, object]:
    return {
        "index": index,
        "title": title or f"第{index}章",
        "url": None,
        "file_name": file_name,
        "downloaded": True,
        "translated": False,
        "translated_file_name": f"{Path(file_name).stem}.translated.txt",
        "translated_meta_file_name": f"{Path(file_name).stem}.translated.json",
        "illustration": False,
        "image_urls": [],
        "image_files": [],
        "translated_image_files": [],
        "page_count": 0,
    }


def _sanitize_title(title: str) -> str:
    sanitized = re.sub(r'[\\/:*?"<>|]', "_", title).strip().strip(".")
    return sanitized[:80] or "未命名"
