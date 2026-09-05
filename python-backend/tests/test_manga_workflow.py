from __future__ import annotations

import asyncio
import base64
import json
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from PIL import Image, ImageDraw

from app import main, manga_workflow
from app.application import create_application
from app.models import (
    BookRecord,
    MangaChapterTranslationPayload,
    MangaOcrPagePayload,
    MangaOcrRegion,
    MangaTranslatedPagePayload,
    MangaTranslatedRegion,
    MangaWorkflowResponse,
    TranslationSettings,
)


def _image_bytes(
    size: tuple[int, int] = (64, 48),
    *,
    image_format: str = "PNG",
    color: tuple[int, int, int] = (245, 245, 245),
) -> bytes:
    output = BytesIO()
    Image.new("RGB", size, color).save(output, format=image_format)
    return output.getvalue()


def _upstream_project(*, translation: str = "") -> dict[str, object]:
    return {
        r"C:\manga\page.png": {
            "regions": [
                {
                    "lines": [[[8, 6], [42, 6], [42, 30], [8, 30]]],
                    "center": [25, 18],
                    "texts": ["猫です"],
                    "text": "猫です",
                    "translation": translation,
                    "translation_raw": translation,
                    "angle": 0,
                    "font_size": 18,
                    "fg_colors": [10, 20, 30],
                    "bg_colors": [255, 255, 255],
                    "direction": "v",
                    "alignment": "center",
                    "target_lang": "CHS",
                    "source_lang": "JPN",
                    "line_spacing": 1.0,
                    "letter_spacing": 1.0,
                    "stroke_width": 0.2,
                    "prob": 0.98,
                    "font_family": "Test Font",
                    "editor_marker": "preserve-region",
                }
            ],
            "original_width": 64,
            "original_height": 48,
            "skip_font_scaling": True,
            "editor_marker": "preserve-page",
        }
    }


def _region(*, translation: str = "") -> MangaTranslatedRegion:
    return MangaTranslatedRegion(
        order=1,
        bbox=(8, 6, 42, 30),
        body_bbox=(6, 4, 44, 32),
        safe_box=(8, 6, 42, 30),
        source_text="猫です",
        source_direction="vertical",
        direction="vertical",
        translation=translation,
    )


def _bookshelf_manga(tmp_path) -> tuple[BookRecord, dict[str, object]]:
    book_dir = tmp_path / "book"
    (book_dir / "images").mkdir(parents=True)
    (book_dir / "0001.txt").write_text("第一话", encoding="utf-8")
    (book_dir / "images" / "page-1.png").write_bytes(_image_bytes())
    (book_dir / "images" / "page-2.png").write_bytes(_image_bytes())
    manifest: dict[str, object] = {
        "title": "测试漫画",
        "synopsis": "",
        "book_kind": "漫画",
        "cover_url": None,
        "cover_file": None,
        "download_mode": "all",
        "chapter_count": 1,
        "chapters": [
            {
                "index": 1,
                "title": "第一话",
                "url": None,
                "file_name": "0001.txt",
                "downloaded": True,
                "translated": False,
                "translated_file_name": "0001.translated.txt",
                "translated_meta_file_name": "0001.translated.json",
                "illustration": False,
                "image_urls": [],
                "image_files": ["images/page-1.png", "images/page-2.png"],
                "translated_image_files": [],
                "page_count": 2,
                "images_repaired": False,
            }
        ],
    }
    main.save_manifest(book_dir, manifest)
    return (
        BookRecord(
            ownerId="owner-1",
            id="book-1",
            title="测试漫画",
            sourceUrl="https://example.com/manga",
            bookKind="漫画",
            language="日文",
            status="已下载",
            chapterCount=1,
            translated=False,
            localPath=str(book_dir),
        ),
        manifest,
    )


def _chapter_translation_payload(*, second_image: str | None = None) -> MangaChapterTranslationPayload:
    encoded_image = base64.b64encode(_image_bytes()).decode("ascii")
    return MangaChapterTranslationPayload(
        targetLanguage="中文",
        pages=[
            {
                "pageNumber": 1,
                "outputImageBase64": encoded_image,
                "project": _upstream_project(translation="第一页译文"),
                "pageTranslation": "第一页译文",
            },
            {
                "pageNumber": 2,
                "outputImageBase64": second_image or encoded_image,
                "project": _upstream_project(translation="第二页译文"),
                "pageTranslation": "第二页译文",
            },
        ],
    )


def _patch_bookshelf_manga_access(monkeypatch, book: BookRecord) -> None:
    monkeypatch.setattr(main, "require_user_access", lambda _: SimpleNamespace(owner_id="owner-1"))

    def get_book(book_id: str, owner_id: str | None = None) -> BookRecord:
        assert book_id == book.id
        assert owner_id == book.ownerId
        return book

    monkeypatch.setattr(main, "_get_book_or_404", get_book)
    monkeypatch.setattr(main, "_refresh_book_state", lambda current: current)


def test_parse_project_accepts_upstream_document_and_direct_regions() -> None:
    upstream = manga_workflow.parse_manga_project(
        _upstream_project(translation="是猫"),
        default_image_key="page.png",
        image_size=(64, 48),
    )
    direct = manga_workflow.parse_manga_project(
        {"regions": _upstream_project()[r"C:\manga\page.png"]["regions"]},
        default_image_key="page.png",
        image_size=(64, 48),
    )

    assert upstream.input_format == "upstream_document"
    assert upstream.image_key == r"C:\manga\page.png"
    assert upstream.regions[0].bbox == (8, 6, 42, 30)
    assert upstream.regions[0].direction == "vertical"
    assert upstream.regions[0].translation == "是猫"
    assert direct.input_format == "page"
    assert direct.image_key == "page.png"


@pytest.mark.asyncio
async def test_export_original_runs_ocr_without_translation(monkeypatch) -> None:
    async def fake_ocr(**_: object) -> tuple[list[MangaTranslatedRegion], dict[str, object]]:
        return [_region()], {"ocr_backend": "test"}

    monkeypatch.setattr(manga_workflow, "_ocr_regions", fake_ocr)
    result = await manga_workflow.run_manga_workflow(
        image_bytes=_image_bytes(),
        original_name="page.png",
        mode="export_original",
        target_language="中文",
        settings=TranslationSettings(),
    )

    assert result.outputImageBase64 is None
    assert result.original == {"猫です": "猫です"}
    assert result.translated == {"猫です": ""}
    assert result.projectDocument["page.png"]["regions"][0]["text"] == "猫です"
    assert result.projectDocument["page.png"]["regions"][0]["target_lang"] == "CHS"
    assert result.projectDocument["page.png"]["regions"][0]["bbox"] == [8, 6, 42, 30]
    assert result.projectDocument["page.png"]["regions"][0]["body_bbox"] == [6, 4, 44, 32]
    assert result.projectDocument["page.png"]["regions"][0]["safe_box"] == [8, 6, 42, 30]
    assert result.projectDocument["page.png"]["regions"][0]["source_direction"] == "vertical"
    round_trip = manga_workflow.parse_manga_project(
        result.projectDocument,
        default_image_key="page.png",
        image_size=(64, 48),
    )
    assert round_trip.regions[0].bbox == (8, 6, 42, 30)
    assert round_trip.regions[0].body_bbox == (6, 4, 44, 32)
    assert round_trip.regions[0].safe_box == (8, 6, 42, 30)
    assert base64.b64decode(result.project["mask_raw"]).startswith(b"\x89PNG")
    assert result.project["skip_font_scaling"] is False
    assert result.diagnostics["ocr_backend"] == "test"


@pytest.mark.asyncio
@pytest.mark.parametrize("mode", ["normal", "export_translation"])
async def test_translation_modes_reuse_structured_pipeline(monkeypatch, mode: str) -> None:
    async def fake_translate(**kwargs: object) -> tuple[list[MangaTranslatedRegion], dict[str, object]]:
        regions = kwargs["regions"]
        assert isinstance(regions, list)
        return [regions[0].model_copy(update={"translation": "是猫"})], {"translationModel": "test"}

    async def fake_render(**_: object) -> tuple[bytes, str, dict[str, object]]:
        return _image_bytes(), "是猫", {"rendered_region_count": 1}

    def fake_inpaint(*_: object) -> tuple[bytes, dict[str, object]]:
        return _image_bytes(), {"inpaintedRegionCount": 1}

    monkeypatch.setattr(manga_workflow, "_translate_regions", fake_translate)
    monkeypatch.setattr(manga_workflow, "_render_regions", fake_render)
    monkeypatch.setattr(manga_workflow, "_inpaint_regions", fake_inpaint)
    result = await manga_workflow.run_manga_workflow(
        image_bytes=_image_bytes(),
        original_name="page.png",
        mode=mode,
        target_language="中文",
        settings=TranslationSettings(),
        project=_upstream_project(),
    )

    assert result.translated == {"猫です": "是猫"}
    assert result.project["regions"][0]["translation"] == "是猫"
    if mode == "normal":
        assert result.outputImageBase64 is not None
        assert result.inpaintedImageBase64 is not None
    else:
        assert result.outputImageBase64 is None
        assert result.inpaintedImageBase64 is None


@pytest.mark.asyncio
async def test_translate_json_only_updates_upstream_document(monkeypatch) -> None:
    async def fake_translate(**kwargs: object) -> tuple[list[MangaTranslatedRegion], dict[str, object]]:
        regions = kwargs["regions"]
        return [regions[0].model_copy(update={"translation": "是猫"})], {"translatedRegionCount": 1}

    monkeypatch.setattr(manga_workflow, "_translate_regions", fake_translate)
    result = await manga_workflow.run_manga_workflow(
        image_bytes=_image_bytes(),
        original_name="page.png",
        mode="translate_json_only",
        target_language="中文",
        settings=TranslationSettings(),
        project=_upstream_project(),
    )

    assert result.imageKey == r"C:\manga\page.png"
    assert result.projectDocument[result.imageKey]["regions"][0]["translation_raw"] == "是猫"
    assert result.projectDocument[result.imageKey]["regions"][0]["editor_marker"] == "preserve-region"
    assert result.projectDocument[result.imageKey]["editor_marker"] == "preserve-page"
    assert result.project["skip_font_scaling"] is False
    assert result.pageTranslation == "是猫"


@pytest.mark.asyncio
async def test_import_translation_render_applies_companion_mapping(monkeypatch) -> None:
    async def fake_render(**kwargs: object) -> tuple[bytes, str, dict[str, object]]:
        regions = kwargs["regions"]
        assert regions[0].translation == "是猫"
        return _image_bytes(), "是猫", {"rendered_region_count": 1}

    def fake_inpaint(*_: object) -> tuple[bytes, dict[str, object]]:
        return _image_bytes(), {"inpaintedRegionCount": 1}

    monkeypatch.setattr(manga_workflow, "_render_regions", fake_render)
    monkeypatch.setattr(manga_workflow, "_inpaint_regions", fake_inpaint)
    result = await manga_workflow.run_manga_workflow(
        image_bytes=_image_bytes(),
        original_name="page.png",
        mode="import_translation_render",
        target_language="中文",
        settings=TranslationSettings(),
        project=_upstream_project(),
        companion={"猫です": "是猫"},
    )

    assert base64.b64decode(result.outputImageBase64 or "").startswith(b"\x89PNG")
    assert result.diagnostics["companionMatchedRegionCount"] == 1
    assert result.project["regions"][0]["translation"] == "是猫"


@pytest.mark.asyncio
async def test_import_translation_render_accepts_manual_region_without_source_text(
    monkeypatch,
) -> None:
    project = _upstream_project(translation="是猫")
    page = project[r"C:\manga\page.png"]
    assert isinstance(page, dict)
    regions = page["regions"]
    assert isinstance(regions, list)
    regions.append(
        {
            "order": 2,
            "bbox": [45, 8, 60, 28],
            "body_bbox": [44, 7, 61, 29],
            "safe_box": [45, 8, 60, 28],
            "lines": [[[45, 8], [60, 8], [60, 28], [45, 28]]],
            "center": [52.5, 18],
            "texts": [],
            "text": "",
            "source_text": "",
            "translation": "……",
            "translation_raw": "……",
            "direction": "v",
            "font_size": 12,
            "alignment": "center",
            "manual_region": True,
        }
    )

    async def fail_ocr(**_: object) -> tuple[list[MangaTranslatedRegion], dict[str, object]]:
        raise AssertionError("人工工程重新渲染不应再次执行 OCR")

    async def fail_translate(**_: object) -> tuple[list[MangaTranslatedRegion], dict[str, object]]:
        raise AssertionError("人工工程重新渲染不应再次调用翻译模型")

    def fake_inpaint(
        _image_path: Path,
        parsed_regions: list[MangaTranslatedRegion],
    ) -> tuple[bytes, dict[str, object]]:
        assert len(parsed_regions) == 2
        assert parsed_regions[1].source_text == ""
        assert parsed_regions[1].translation == "……"
        assert parsed_regions[1].bbox == (45.0, 8.0, 60.0, 28.0)
        return _image_bytes(), {"inpaintedRegionCount": 2}

    async def fake_render(**kwargs: object) -> tuple[bytes, str, dict[str, object]]:
        parsed_regions = kwargs["regions"]
        assert isinstance(parsed_regions, list)
        assert parsed_regions[1].translation == "……"
        return _image_bytes(), "是猫\n……", {"rendered_region_count": 2}

    monkeypatch.setattr(manga_workflow, "_ocr_regions", fail_ocr)
    monkeypatch.setattr(manga_workflow, "_translate_regions", fail_translate)
    monkeypatch.setattr(manga_workflow, "_inpaint_regions", fake_inpaint)
    monkeypatch.setattr(manga_workflow, "_render_regions", fake_render)

    result = await manga_workflow.run_manga_workflow(
        image_bytes=_image_bytes(),
        original_name="page.png",
        mode="import_translation_render",
        target_language="中文",
        settings=TranslationSettings(),
        project=project,
    )

    manual = result.projectDocument[result.imageKey]["regions"][1]
    assert result.pageTranslation == "是猫\n……"
    assert manual["text"] == ""
    assert manual["translation"] == "……"
    assert manual["translation_raw"] == "……"
    assert manual["manual_region"] is True
    assert manual["bbox"] == [45.0, 8.0, 60.0, 28.0]


@pytest.mark.asyncio
async def test_import_translation_render_paints_manual_empty_source_region_without_touching_outside() -> None:
    image = Image.new("RGB", (180, 180), "white")
    draw = ImageDraw.Draw(image)
    region_bbox = (48, 28, 132, 152)
    # Simulate missed vertical source glyphs.  Corner strokes make it possible
    # to prove cleanup happened independently from the newly centered text.
    for block in (
        (48, 28, 60, 40),
        (120, 28, 132, 40),
        (48, 140, 60, 152),
        (120, 140, 132, 152),
        (84, 62, 96, 118),
    ):
        draw.rectangle(block, fill="black")
    source = BytesIO()
    image.save(source, format="PNG")
    project = {
        "page.png": {
            "original_width": image.width,
            "original_height": image.height,
            "regions": [
                {
                    "order": 1,
                    "bbox": list(region_bbox),
                    "body_bbox": list(region_bbox),
                    "safe_box": list(region_bbox),
                    "lines": [
                        [
                            [region_bbox[0], region_bbox[1]],
                            [region_bbox[2], region_bbox[1]],
                            [region_bbox[2], region_bbox[3]],
                            [region_bbox[0], region_bbox[3]],
                        ]
                    ],
                    "center": [90, 90],
                    "texts": [],
                    "text": "",
                    "source_text": "",
                    "translation": "人工补译",
                    "translation_raw": "人工补译",
                    "direction": "v",
                    "font_size": 24,
                    "alignment": "center",
                    "manual_region": True,
                }
            ],
        }
    }

    result = await manga_workflow.run_manga_workflow(
        image_bytes=source.getvalue(),
        original_name="page.png",
        mode="import_translation_render",
        target_language="中文",
        settings=TranslationSettings(),
        project=project,
    )

    assert result.pageTranslation == "人工补译"
    assert result.diagnostics["rendered_region_count"] == 1
    assert result.diagnostics["source_text_erased_region_count"] == 1
    with Image.open(BytesIO(base64.b64decode(result.outputImageBase64 or ""))) as rendered:
        output = rendered.convert("RGB")
        # The four original corner strokes are cleaned; translated text is
        # rendered around the center of the manually supplied region.
        for point in ((52, 32), (128, 32), (52, 148), (128, 148)):
            assert output.getpixel(point) == (255, 255, 255)
        assert any(
            output.getpixel((current_x, current_y)) != (255, 255, 255)
            for current_y in range(region_bbox[1], region_bbox[3])
            for current_x in range(region_bbox[0], region_bbox[2])
        )
        for current_y in range(image.height):
            for current_x in range(image.width):
                if (
                    region_bbox[0] <= current_x < region_bbox[2]
                    and region_bbox[1] <= current_y < region_bbox[3]
                ):
                    continue
                assert output.getpixel((current_x, current_y)) == image.getpixel(
                    (current_x, current_y)
                )


@pytest.mark.asyncio
async def test_inpaint_only_keeps_ocr_project(monkeypatch) -> None:
    async def fake_ocr(**_: object) -> tuple[list[MangaTranslatedRegion], dict[str, object]]:
        return [_region()], {"ocr_backend": "test"}

    def fake_inpaint(*_: object) -> tuple[bytes, dict[str, object]]:
        return _image_bytes(), {"inpaintedRegionCount": 1}

    monkeypatch.setattr(manga_workflow, "_ocr_regions", fake_ocr)
    monkeypatch.setattr(manga_workflow, "_inpaint_regions", fake_inpaint)
    result = await manga_workflow.run_manga_workflow(
        image_bytes=_image_bytes(),
        original_name="page.png",
        mode="inpaint_only",
        target_language="中文",
        settings=TranslationSettings(),
    )

    assert result.project["regions"][0]["text"] == "猫です"
    assert result.projectDocument == {"page.png": result.project}
    assert result.diagnostics["shouldPersistProject"] is True


@pytest.mark.asyncio
async def test_local_colorize_and_upscale_are_deterministic() -> None:
    source = _image_bytes((16, 12), image_format="JPEG")
    first_color = await manga_workflow.run_manga_workflow(
        image_bytes=source,
        original_name="page.jpg",
        mode="colorize_only",
        target_language="中文",
        settings=TranslationSettings(),
    )
    second_color = await manga_workflow.run_manga_workflow(
        image_bytes=source,
        original_name="page.jpg",
        mode="colorize_only",
        target_language="中文",
        settings=TranslationSettings(),
    )
    upscaled = await manga_workflow.run_manga_workflow(
        image_bytes=source,
        original_name="page.jpg",
        mode="upscale_only",
        target_language="中文",
        settings=TranslationSettings(),
        upscale_factor=3,
    )

    assert first_color.outputImageBase64 == second_color.outputImageBase64
    assert first_color.project == {}
    assert first_color.projectDocument == {}
    assert first_color.diagnostics["shouldPersistProject"] is False
    assert upscaled.project == {}
    assert upscaled.projectDocument == {}
    assert upscaled.diagnostics["shouldPersistProject"] is False
    upscaled_bytes = base64.b64decode(upscaled.outputImageBase64 or "")
    assert upscaled.mimeType == "image/png"
    assert upscaled_bytes.startswith(b"\x89PNG\r\n\x1a\n")
    with Image.open(BytesIO(upscaled_bytes)) as image:
        assert image.size == (48, 36)
    assert upscaled.diagnostics["upscaleAlgorithm"] == "lanczos"


def test_replace_translation_matches_scaled_regions_by_iou() -> None:
    source = [_region()]
    replacement = [
        MangaTranslatedRegion(
            order=1,
            bbox=(16, 12, 84, 60),
            source_text="是猫",
        )
    ]
    resolved, diagnostics = manga_workflow.match_replacement_regions(
        source,
        replacement,
        source_size=(64, 48),
        replacement_size=(128, 96),
    )

    assert resolved[0].translation == "是猫"
    assert diagnostics["matchedRegionCount"] == 1
    assert diagnostics["averageMatchOverlap"] == 1.0
    assert diagnostics["minimumRequiredOverlap"] == 0.3


def test_replace_translation_rejects_low_overlap_regions() -> None:
    source = [_region()]
    replacement = [
        MangaTranslatedRegion(
            order=1,
            bbox=(40, 28, 60, 48),
            source_text="是猫",
        )
    ]
    resolved, diagnostics = manga_workflow.match_replacement_regions(
        source,
        replacement,
        source_size=(128, 96),
        replacement_size=(128, 96),
    )

    assert resolved[0].translation == ""
    assert diagnostics["matchedRegionCount"] == 0


@pytest.mark.asyncio
async def test_replace_translation_requires_a_pairing_input() -> None:
    with pytest.raises(ValueError, match="translatedFile"):
        await manga_workflow.run_manga_workflow(
            image_bytes=_image_bytes(),
            original_name="page.png",
            mode="replace_translation",
            target_language="中文",
            settings=TranslationSettings(),
            project=_upstream_project(translation="旧译文"),
        )


def test_workflow_route_accepts_camel_case_multipart_and_bmp(monkeypatch) -> None:
    captured: dict[str, object] = {}

    async def fake_workflow(**kwargs: object) -> MangaWorkflowResponse:
        captured.update(kwargs)
        return MangaWorkflowResponse(
            mode="upscale_only",
            imageKey="page.bmp",
            project={"regions": []},
            projectDocument={"page.bmp": {"regions": []}},
        )

    monkeypatch.setattr(main, "run_manga_workflow", fake_workflow)
    monkeypatch.setattr(main, "load_settings", TranslationSettings)
    application = create_application(routers=[main.library_router])
    with TestClient(application) as client:
        response = client.post(
            "/images/workflow",
            files={
                "file": ("page.bmp", _image_bytes(image_format="BMP"), "image/bmp"),
                "translatedFile": ("translated.png", _image_bytes(), "image/png"),
            },
            data={
                "mode": "upscale_only",
                "language": "中文",
                "companion": json.dumps({"猫です": "是猫"}, ensure_ascii=False),
                "upscaleFactor": "3",
            },
        )

    assert response.status_code == 200
    assert response.json()["imageKey"] == "page.bmp"
    assert captured["upscale_factor"] == 3
    assert captured["translated_image_bytes"] == _image_bytes()
    assert json.loads(str(captured["companion"])) == {"猫です": "是猫"}


@pytest.mark.asyncio
async def test_manga_chapter_translation_writes_complete_result_to_bookshelf(
    monkeypatch,
    tmp_path,
) -> None:
    book, _ = _bookshelf_manga(tmp_path)
    _patch_bookshelf_manga_access(monkeypatch, book)

    response = await main.post_manga_chapter_translation(
        book.id,
        1,
        _chapter_translation_payload(),
        SimpleNamespace(),  # type: ignore[arg-type]
    )

    book_dir = Path(book.localPath)
    translated_assets = [
        "images/page-1.translated.png",
        "images/page-2.translated.png",
    ]
    assert response.translated is True
    assert response.pageCount == 2
    assert response.translatedImageFiles == translated_assets
    assert all((book_dir / asset).read_bytes().startswith(b"\x89PNG") for asset in translated_assets)

    metadata = json.loads((book_dir / "0001.translated.json").read_text(encoding="utf-8"))
    assert metadata["page_count"] == 2
    assert metadata["target_language"] == "中文"
    assert metadata["translated_image_files"] == translated_assets
    assert [page["page_number"] for page in metadata["translated_pages"]] == [1, 2]
    assert metadata["translated_pages"][0]["source_image_file"] == "images/page-1.png"
    assert metadata["translated_pages"][0]["regions"][0]["translation"] == "第一页译文"

    translated_text = (book_dir / "0001.translated.txt").read_text(encoding="utf-8")
    assert "第一页译文" in translated_text
    assert "第二页译文" in translated_text
    manifest = main.load_manifest(book_dir)
    chapter = manifest["chapters"][0]
    assert chapter["translated"] is True
    assert chapter["translated_file_name"] == "0001.translated.txt"
    assert chapter["translated_meta_file_name"] == "0001.translated.json"
    assert chapter["translated_image_files"] == translated_assets

    reader_payload = await main.get_chapter_content(
        book.id,
        1,
        SimpleNamespace(),  # type: ignore[arg-type]
        mode="translated",
        prefetch=False,
    )
    assert reader_payload.mode == "translated"
    assert reader_payload.translatedAvailable is True
    assert reader_payload.pageTranslations == ["第一页译文", "第二页译文"]
    assert [Path(source).name for source in reader_payload.imageSources] == [
        "page-1.translated.png",
        "page-2.translated.png",
    ]


@pytest.mark.asyncio
async def test_manga_chapter_translation_rejects_missing_page(monkeypatch, tmp_path) -> None:
    book, _ = _bookshelf_manga(tmp_path)
    _patch_bookshelf_manga_access(monkeypatch, book)
    payload = _chapter_translation_payload().model_copy(
        update={"pages": _chapter_translation_payload().pages[:1]}
    )

    with pytest.raises(HTTPException, match="一次提交整章全部 2 页") as raised:
        await main.post_manga_chapter_translation(
            book.id,
            1,
            payload,
            SimpleNamespace(),  # type: ignore[arg-type]
        )

    assert raised.value.status_code == 400
    book_dir = Path(book.localPath)
    assert not (book_dir / "0001.translated.txt").exists()
    assert not (book_dir / "0001.translated.json").exists()
    assert not (book_dir / "images/page-1.translated.png").exists()
    assert main.load_manifest(book_dir)["chapters"][0]["translated"] is False


@pytest.mark.asyncio
async def test_manga_chapter_translation_publish_error_restores_old_translation(
    monkeypatch,
    tmp_path,
) -> None:
    book, manifest = _bookshelf_manga(tmp_path)
    _patch_bookshelf_manga_access(monkeypatch, book)
    book_dir = Path(book.localPath)
    old_first_image = _image_bytes((64, 48), image_format="PNG", color=(10, 20, 30))
    old_second_image = _image_bytes((64, 48), image_format="PNG", color=(30, 20, 10))
    (book_dir / "images/page-1.translated.png").write_bytes(old_first_image)
    (book_dir / "images/page-2.translated.png").write_bytes(old_second_image)
    old_text = "已有整章译文"
    old_metadata = '{"old": true}\n'
    (book_dir / "0001.translated.txt").write_text(old_text, encoding="utf-8")
    (book_dir / "0001.translated.json").write_text(old_metadata, encoding="utf-8")
    old_chapter = manifest["chapters"][0]
    assert isinstance(old_chapter, dict)
    old_chapter["translated"] = True
    old_chapter["translated_image_files"] = [
        "images/page-1.translated.png",
        "images/page-2.translated.png",
    ]
    main.save_manifest(book_dir, manifest)
    # Normalize through the same loader used by the endpoint before taking the baseline.
    main._load_or_initialize_manifest(book, book_dir)  # noqa: SLF001
    old_manifest = (book_dir / "manifest.json").read_bytes()

    original_replace = main.os.replace
    failed = False

    def fail_second_image_once(source, target) -> None:
        nonlocal failed
        source_path = Path(source)
        target_path = Path(target)
        if (
            not failed
            and target_path.name == "page-2.translated.png"
            and "__backup__" not in source_path.parts
        ):
            failed = True
            raise OSError("simulated publish failure")
        original_replace(source, target)

    monkeypatch.setattr(main.os, "replace", fail_second_image_once)
    with pytest.raises(HTTPException, match="漫画译文写入书架失败") as raised:
        await main.post_manga_chapter_translation(
            book.id,
            1,
            _chapter_translation_payload(),
            SimpleNamespace(),  # type: ignore[arg-type]
        )

    assert raised.value.status_code == 500
    assert failed is True
    assert (book_dir / "images/page-1.translated.png").read_bytes() == old_first_image
    assert (book_dir / "images/page-2.translated.png").read_bytes() == old_second_image
    assert (book_dir / "0001.translated.txt").read_text(encoding="utf-8") == old_text
    assert (book_dir / "0001.translated.json").read_text(encoding="utf-8") == old_metadata
    assert (book_dir / "manifest.json").read_bytes() == old_manifest


@pytest.mark.asyncio
async def test_workflow_operation_is_cancelled_after_client_disconnect() -> None:
    cancelled = False

    async def operation() -> str:
        nonlocal cancelled
        try:
            await asyncio.sleep(60)
        finally:
            cancelled = True

    class DisconnectedRequest:
        async def is_disconnected(self) -> bool:
            return True

    with pytest.raises(HTTPException) as raised:
        await main._await_or_cancel_on_disconnect(  # noqa: SLF001
            DisconnectedRequest(),  # type: ignore[arg-type]
            operation(),
            poll_seconds=0,
        )

    assert raised.value.status_code == 499
    assert cancelled is True


@pytest.mark.asyncio
async def test_task_page_results_include_task_updated_at(monkeypatch, tmp_path) -> None:
    task = SimpleNamespace(
        id="task-1",
        bookId="book-1",
        taskType="translate",
        chapterIndexes=[1],
        completedCount=1,
        updatedAt="2030-01-02T03:04:05Z",
    )
    book = SimpleNamespace(bookKind="漫画")
    page = MangaTranslatedPagePayload(
        page_number=1,
        page_translation="是猫",
        regions=[_region(translation="是猫")],
    )
    monkeypatch.setattr(main, "require_user_access", lambda _: SimpleNamespace(owner_id="owner-1"))
    monkeypatch.setattr(main, "get_task", lambda *_: task)
    monkeypatch.setattr(main, "_get_book_or_404", lambda *_: book)
    monkeypatch.setattr(main, "_resolve_book_dir", lambda *_: tmp_path)
    monkeypatch.setattr(main, "_load_or_initialize_manifest", lambda *_: {})
    monkeypatch.setattr(
        main,
        "_build_manifest_lookup",
        lambda _: {
            1: {
                "title": "第一话",
                "file_name": "0001.txt",
                "image_files": ["page.png"],
            }
        },
    )
    monkeypatch.setattr(main, "load_manga_translation_page_payloads", lambda *_args, **_kwargs: [page])

    results = await main.get_task_page_results("task-1", SimpleNamespace(), after=0)

    assert results[0].updatedAt == "2030-01-02T03:04:05Z"
    assert results[0].texts[0].translation == "是猫"


def test_all_nine_workflow_modes_are_declared() -> None:
    assert {
        "normal",
        "export_translation",
        "export_original",
        "translate_json_only",
        "import_translation_render",
        "colorize_only",
        "upscale_only",
        "inpaint_only",
        "replace_translation",
    } == manga_workflow.WORKFLOW_MODES


def test_ocr_payload_model_remains_compatible_with_workflow_regions() -> None:
    payload = MangaOcrPagePayload(
        page_number=1,
        image_size=(64, 48),
        regions=[MangaOcrRegion(order=1, bbox=(8, 6, 42, 30), source_text="猫です")],
    )

    assert payload.regions[0].source_text == "猫です"
