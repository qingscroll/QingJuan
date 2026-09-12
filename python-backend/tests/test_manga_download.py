from __future__ import annotations

import asyncio
import base64
import importlib
from io import BytesIO
from types import SimpleNamespace

import httpx
import pytest
from PIL import Image, ImageDraw, ImageFont

from app import scraper
from app.manga_download import fetch_image_with_retry, is_valid_image_file, write_image_atomic
from app.models import (
    MangaOcrConfig,
    MangaOcrPagePayload,
    MangaOcrRegion,
    MangaTranslatedPagePayload,
    MangaTranslatedRegion,
    OpenAICompatibleConfig,
    TaskRecord,
    TranslationSettings,
)

PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


async def _no_sleep(_: float) -> None:
    return None


@pytest.mark.asyncio
async def test_image_download_retries_status_and_invalid_payload() -> None:
    attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            return httpx.Response(503, request=request)
        if attempts == 2:
            return httpx.Response(200, content=b"<html>blocked</html>", request=request)
        return httpx.Response(200, content=PNG_1X1, request=request)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        content = await fetch_image_with_retry(
            client,
            "https://img.example.test/page.png",
            headers={"Referer": "https://reader.example.test/chapter/1"},
            max_attempts=3,
            base_delay=0,
            sleep=_no_sleep,
        )

    assert content == PNG_1X1
    assert attempts == 3


@pytest.mark.asyncio
async def test_image_download_does_not_retry_permanent_404() -> None:
    attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        attempts += 1
        return httpx.Response(404, request=request)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(httpx.HTTPStatusError):
            await fetch_image_with_retry(
                client,
                "https://img.example.test/missing.png",
                headers={},
                max_attempts=4,
                base_delay=0,
                sleep=_no_sleep,
            )

    assert attempts == 1


def test_atomic_image_write_replaces_corrupt_cache(tmp_path) -> None:
    target = tmp_path / "page.png"
    target.write_bytes(b"partial-response")

    write_image_atomic(target, PNG_1X1)

    assert is_valid_image_file(target)
    assert target.read_bytes() == PNG_1X1
    assert not target.with_suffix(".png.part").exists()


def test_manga_style_estimator_reads_source_color_and_font_size() -> None:
    image = Image.new("RGB", (260, 140), (250, 248, 244))
    draw = ImageDraw.Draw(image)
    font = scraper._load_local_render_font(32, bold=True)
    draw.text((38, 42), "TEST", font=font, fill=(178, 28, 44))
    bbox = draw.textbbox((38, 42), "TEST", font=font)

    style = scraper._estimate_manga_text_style(
        image,
        bbox,
        (250, 248, 244),
        preferred_color=None,
        direction="horizontal",
    )

    assert scraper._color_difference(style.text_color, (178, 28, 44)) < 18
    assert 24 <= style.font_size <= 40
    assert style.bold is True
    assert style.ink_mask.getbbox() is not None


def test_local_render_font_fallback_preserves_requested_size(monkeypatch) -> None:
    original_truetype = scraper.ImageFont.truetype

    monkeypatch.setattr(scraper, "_local_render_font_paths", lambda **_: [])

    def reject_named_fonts(font: object, *args: object, **kwargs: object) -> ImageFont.ImageFont:
        if isinstance(font, str):
            raise OSError("system font unavailable")
        return original_truetype(font, *args, **kwargs)

    monkeypatch.setattr(scraper.ImageFont, "truetype", reject_named_fonts)

    small_font = scraper._load_local_render_font(12)
    large_font = scraper._load_local_render_font(36)
    small_bbox = small_font.getbbox("TEST")
    large_bbox = large_font.getbbox("TEST")

    assert large_bbox[3] - large_bbox[1] >= (small_bbox[3] - small_bbox[1]) * 2


def test_long_vertical_translation_uses_bubble_width_for_multiple_columns() -> None:
    translation = "今天一定要带你去漂亮的花田……然后和你成为朋友！"

    layout = scraper._fit_text_layout_for_render(
        translation,
        (339, 576),
        "vertical",
        preferred_font_size=180,
        bold=True,
    )

    assert layout["fits"] is True
    assert len(layout["columns"]) >= 2
    assert layout["font_size"] >= 30


def test_manga_fill_sampler_prefers_bubble_color_over_page_background() -> None:
    image = Image.new("RGB", (320, 220), (222, 224, 226))
    draw = ImageDraw.Draw(image)
    bubble_color = (252, 249, 241)
    body_bbox = (40, 28, 280, 192)
    draw.ellipse(body_bbox, fill=bubble_color, outline=(20, 20, 20), width=4)

    detected = scraper._sample_region_fill_color(
        image,
        body_bbox,
        body_bbox=body_bbox,
    )

    assert scraper._color_difference(detected, bubble_color) < 4


def test_manga_source_text_is_erased_without_repainting_the_whole_bubble() -> None:
    image = Image.new("RGBA", (280, 160), (255, 255, 255, 255))
    draw = ImageDraw.Draw(image)
    bubble_bbox = (10, 10, 270, 150)
    draw.ellipse(bubble_bbox, outline=(12, 12, 12, 255), width=4)
    font = scraper._load_local_render_font(30, bold=True)
    draw.text((44, 58), "ORIGINAL", font=font, fill=(175, 24, 36, 255))
    text_bbox = draw.textbbox((44, 58), "ORIGINAL", font=font)
    style = scraper._estimate_manga_text_style(
        image,
        text_bbox,
        (255, 255, 255),
        preferred_color=None,
        direction="horizontal",
    )

    erased_pixels, method = scraper._erase_manga_source_text(
        image,
        text_bbox,
        style,
        (255, 255, 255),
    )

    assert erased_pixels > 0
    assert method == "solid"
    assert image.getpixel((10, 80))[:3] == (12, 12, 12)
    remaining_red = sum(
        1
        for pixel in image.crop(text_bbox).get_flattened_data()
        if pixel[0] >= 130 and pixel[0] >= pixel[1] * 2 and pixel[0] >= pixel[2] * 2
    )
    assert remaining_red == 0


def test_manga_render_uses_detected_style_and_reports_cleanup(tmp_path) -> None:
    source = tmp_path / "manga.png"
    image = Image.new("RGB", (260, 140), "white")
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((10, 10, 250, 130), radius=24, outline=(0, 0, 0), width=3)
    font = scraper._load_local_render_font(30, bold=True)
    draw.text((54, 50), "SOURCE", font=font, fill=(34, 74, 188))
    text_bbox = draw.textbbox((54, 50), "SOURCE", font=font)
    image.save(source)
    payload = MangaTranslatedPagePayload(
        page_number=1,
        image_size=image.size,
        target_language="Chinese",
        regions=[
            MangaTranslatedRegion(
                order=1,
                bbox=text_bbox,
                body_bbox=(10, 10, 250, 130),
                safe_box=(30, 28, 230, 112),
                source_text="SOURCE",
                source_direction="horizontal",
                direction="horizontal",
                translation="译文",
                shape="roundrect",
            )
        ],
    )

    translated_bytes, _, diagnostics = scraper._render_translated_manga_page_to_image(source, payload)

    assert translated_bytes.startswith(b"\x89PNG\r\n\x1a\n")
    assert diagnostics["style_estimated_region_count"] == 1
    assert diagnostics["source_text_erased_region_count"] == 1
    assert diagnostics["solid_cleanup_region_count"] == 1
    assert diagnostics["average_source_font_size"] >= 20
    assert diagnostics["rendered_horizontal_count"] == 1
    assert diagnostics["rendered_vertical_count"] == 0


def test_manga_render_cleans_full_tight_ocr_bbox_without_shape_clipping(tmp_path) -> None:
    source = tmp_path / "tight-vertical-ocr.png"
    image = Image.new("RGB", (180, 180), "white")
    draw = ImageDraw.Draw(image)
    text_bbox = (48, 28, 132, 152)
    # Simulate vertical glyph strokes touching the corners of a tight OCR box.
    # The legacy ellipse cleanup mask used to clip precisely these fragments.
    for block in (
        (48, 28, 60, 40),
        (120, 28, 132, 40),
        (48, 140, 60, 152),
        (120, 140, 132, 152),
        (84, 62, 96, 118),
    ):
        draw.rectangle(block, fill="black")
    image.save(source)
    payload = MangaTranslatedPagePayload(
        page_number=1,
        image_size=image.size,
        target_language="Chinese",
        regions=[
            MangaTranslatedRegion(
                order=1,
                bbox=text_bbox,
                body_bbox=text_bbox,
                safe_box=text_bbox,
                source_text="縦書き原文",
                source_direction="vertical",
                direction="vertical",
                translation="译文",
            )
        ],
    )

    translated_bytes, _, diagnostics = scraper._render_translated_manga_page_to_image(source, payload)

    with Image.open(BytesIO(translated_bytes)) as translated:
        result = translated.convert("RGB")
        assert result.getpixel((52, 32)) == (255, 255, 255)
        assert result.getpixel((128, 32)) == (255, 255, 255)
        assert result.getpixel((52, 148)) == (255, 255, 255)
        assert result.getpixel((128, 148)) == (255, 255, 255)
        for current_y in range(image.height):
            for current_x in range(image.width):
                if text_bbox[0] <= current_x < text_bbox[2] and text_bbox[1] <= current_y < text_bbox[3]:
                    continue
                assert result.getpixel((current_x, current_y)) == image.getpixel(
                    (current_x, current_y)
                )
    assert diagnostics["source_text_erased_region_count"] == 1
    assert diagnostics["tight_bbox_cleanup_fallback_region_count"] == 1


def test_manga_cleanup_does_not_override_an_explicit_container_shape() -> None:
    text_bbox = (20, 10, 140, 110)
    ellipse_mask = Image.new("L", (120, 100), 0)
    ImageDraw.Draw(ellipse_mask).ellipse((0, 0, 119, 99), fill=255)

    resolved, used_fallback = scraper._resolve_manga_cleanup_limit_mask(
        text_bbox,
        text_bbox,
        ellipse_mask,
        safe_box=text_bbox,
        explicit_shape="ellipse",
    )

    assert used_fallback is False
    assert list(resolved.get_flattened_data()) == list(ellipse_mask.get_flattened_data())


def test_manga_render_never_changes_pixels_outside_original_bubble(tmp_path) -> None:
    source = tmp_path / "bounded-bubble.png"
    image = Image.new("RGB", (300, 190), (238, 238, 238))
    draw = ImageDraw.Draw(image)
    body_bbox = (20, 15, 280, 175)
    draw.ellipse(body_bbox, fill="white", outline="black", width=4)
    font = scraper._load_local_render_font(28, bold=True)
    draw.text((74, 76), "ORIGINAL", font=font, fill="black")
    text_bbox = draw.textbbox((74, 76), "ORIGINAL", font=font)
    image.save(source)
    payload = MangaTranslatedPagePayload(
        page_number=1,
        image_size=image.size,
        target_language="Chinese",
        regions=[
            MangaTranslatedRegion(
                order=1,
                bbox=text_bbox,
                body_bbox=body_bbox,
                safe_box=body_bbox,
                source_text="ORIGINAL",
                source_direction="horizontal",
                direction="horizontal",
                translation="这是必须完整限制在原对话气泡以内的译文",
                shape="ellipse",
            )
        ],
    )

    translated_bytes, _, diagnostics = scraper._render_translated_manga_page_to_image(source, payload)

    allowed_mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(allowed_mask).ellipse(body_bbox, fill=255)
    with Image.open(BytesIO(translated_bytes)) as translated:
        source_pixels = list(image.convert("RGB").get_flattened_data())
        translated_pixels = list(translated.convert("RGB").get_flattened_data())
    outside_changes = sum(
        1
        for before, after, allowed in zip(
            source_pixels,
            translated_pixels,
            allowed_mask.get_flattened_data(),
            strict=True,
        )
        if allowed == 0 and before != after
    )
    assert diagnostics["rendered_region_count"] == 1
    assert diagnostics["overflow_region_count"] == 0
    assert outside_changes == 0


def test_manga_render_compresses_translation_when_it_cannot_fit(tmp_path) -> None:
    source = tmp_path / "overflow-bubble.png"
    image = Image.new("RGB", (120, 90), "white")
    draw = ImageDraw.Draw(image)
    body_bbox = (20, 15, 100, 75)
    draw.ellipse(body_bbox, outline="black", width=3)
    font = scraper._load_local_render_font(20, bold=True)
    draw.text((38, 34), "TEXT", font=font, fill="black")
    text_bbox = draw.textbbox((38, 34), "TEXT", font=font)
    full_translation = "无法容纳的超长翻译文本" * 20
    image.save(source)
    payload = MangaTranslatedPagePayload(
        page_number=1,
        image_size=image.size,
        target_language="Chinese",
        regions=[
            MangaTranslatedRegion(
                order=1,
                bbox=text_bbox,
                body_bbox=body_bbox,
                safe_box=(28, 22, 92, 68),
                source_text="TEXT",
                direction="horizontal",
                translation=full_translation,
                shape="ellipse",
            )
        ],
    )

    translated_bytes, page_translation, diagnostics = scraper._render_translated_manga_page_to_image(
        source, payload
    )

    assert page_translation == full_translation
    assert diagnostics["rendered_region_count"] == 1
    assert diagnostics["compressed_overflow_region_count"] == 1
    assert diagnostics["skipped_overflow_region_count"] == 0
    assert diagnostics["source_text_erased_region_count"] == 1
    assert 0 < diagnostics["min_overflow_scale"] < 1
    allowed_mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(allowed_mask).ellipse(body_bbox, fill=255)
    with Image.open(BytesIO(translated_bytes)) as translated:
        translated_pixels = list(translated.convert("RGB").get_flattened_data())
    source_pixels = list(image.get_flattened_data())
    assert translated_pixels != source_pixels
    assert all(
        before == after
        for before, after, allowed in zip(
            source_pixels,
            translated_pixels,
            allowed_mask.get_flattened_data(),
            strict=True,
        )
        if allowed == 0
    )


def test_manga_render_skips_effectively_unchanged_text(tmp_path) -> None:
    source = tmp_path / "unchanged.png"
    image = Image.new("RGB", (180, 80), "white")
    draw = ImageDraw.Draw(image)
    font = scraper._load_local_render_font(26)
    draw.text((32, 24), '"6b', font=font, fill="black")
    image.save(source)
    payload = MangaTranslatedPagePayload(
        page_number=1,
        image_size=image.size,
        target_language="Chinese",
        regions=[
            MangaTranslatedRegion(
                order=1,
                bbox=(28, 20, 90, 58),
                source_text='"6b',
                translation="“6b",
                direction="horizontal",
            )
        ],
    )

    translated_bytes, _, diagnostics = scraper._render_translated_manga_page_to_image(source, payload)

    assert diagnostics["rendered_region_count"] == 0
    assert diagnostics["skipped_unchanged_region_count"] == 1
    assert diagnostics["source_text_erased_region_count"] == 0
    with Image.open(BytesIO(translated_bytes)) as translated:
        assert list(translated.convert("RGB").get_flattened_data()) == list(image.get_flattened_data())


def test_manga_render_skips_region_when_ink_mask_covers_most_of_artwork(tmp_path) -> None:
    source = tmp_path / "artwork.png"
    image = Image.new("RGB", (120, 80))
    pixels = image.load()
    for y in range(image.height):
        for x in range(image.width):
            pixels[x, y] = (30 + x, 70 + y, 120 + (x + y) // 3)
    image.save(source)
    payload = MangaTranslatedPagePayload(
        page_number=1,
        image_size=image.size,
        target_language="Chinese",
        regions=[
            MangaTranslatedRegion(
                order=1,
                bbox=(0, 0, 120, 80),
                body_bbox=(0, 0, 120, 80),
                source_text="背景上的装饰文字",
                translation="译文",
                background="#FEFEFE",
                direction="horizontal",
            )
        ],
    )

    translated_bytes, _, diagnostics = scraper._render_translated_manga_page_to_image(source, payload)

    assert diagnostics["rendered_region_count"] == 0
    assert diagnostics["skipped_unsafe_cleanup_region_count"] == 1
    assert diagnostics["source_text_erased_region_count"] == 0
    with Image.open(BytesIO(translated_bytes)) as translated:
        assert list(translated.convert("RGB").get_flattened_data()) == list(image.get_flattened_data())


def test_manga_cleanup_safety_allows_dense_glyphs_but_rejects_opaque_masks() -> None:
    dense_glyph_mask = Image.new("L", (10, 10), 0)
    ImageDraw.Draw(dense_glyph_mask).rectangle((0, 0, 5, 9), fill=255)
    opaque_mask = Image.new("L", (10, 10), 255)

    assert not scraper._manga_ink_mask_is_unsafe(dense_glyph_mask)
    assert scraper._manga_ink_mask_is_unsafe(opaque_mask)


def test_manga_render_skips_large_single_glyph_sound_effect(tmp_path) -> None:
    source = tmp_path / "sound-effect.png"
    image = Image.new("RGB", (160, 160), "black")
    image.save(source)
    payload = MangaTranslatedPagePayload(
        page_number=1,
        image_size=image.size,
        target_language="Chinese",
        regions=[
            MangaTranslatedRegion(
                order=1,
                bbox=(20, 20, 120, 140),
                source_text="ッ",
                translation="！",
                background="#000000",
                direction="vertical",
            )
        ],
    )

    translated_bytes, _, diagnostics = scraper._render_translated_manga_page_to_image(source, payload)

    assert diagnostics["rendered_region_count"] == 0
    assert diagnostics["skipped_nonlinguistic_region_count"] == 1
    with Image.open(BytesIO(translated_bytes)) as translated:
        assert list(translated.convert("RGB").get_flattened_data()) == list(image.get_flattened_data())


def test_manga_nonlinguistic_guard_keeps_short_utterances_renderable() -> None:
    large_bbox = (20, 20, 120, 140)

    assert scraper._manga_region_is_likely_nonlinguistic("ッ", large_bbox)
    assert scraper._manga_region_is_likely_nonlinguistic("！！", large_bbox)
    assert scraper._manga_region_is_likely_nonlinguistic("♪♫", large_bbox)
    assert not scraper._manga_region_is_likely_nonlinguistic("ね", large_bbox)
    assert not scraper._manga_region_is_likely_nonlinguistic("ねー", large_bbox)
    assert not scraper._manga_region_is_likely_nonlinguistic("はぁ", large_bbox)
    assert not scraper._manga_region_is_likely_nonlinguistic("A1", large_bbox)


def test_manga_render_removes_unsupported_music_symbols() -> None:
    assert scraper._sanitize_manga_render_translation("起跑线♪") == "起跑线"


def test_external_ocr_keeps_text_bbox_separate_from_bubble_body() -> None:
    image = Image.new("RGB", (240, 160), "white")
    text_bbox = (84, 64, 156, 92)

    region = scraper._build_external_ocr_region(
        order=1,
        text="SOURCE",
        bbox=text_bbox,
        image=image,
        direction="horizontal",
        line_count=1,
    )

    assert tuple(region["bbox"]) == text_bbox
    assert tuple(region["body_bbox"]) != text_bbox
    assert region["body_bbox"][0] <= text_bbox[0]
    assert region["body_bbox"][2] >= text_bbox[2]


def test_manga_ocr_coercion_preserves_body_box_around_text_box() -> None:
    region = scraper._coerce_manga_ocr_region(
        {
            "order": 1,
            "bbox": [84, 64, 156, 92],
            "body_bbox": [30, 20, 210, 140],
            "safe_box": [42, 32, 198, 128],
            "source_text": "SOURCE",
            "direction": "horizontal",
            "shape": "rect",
        },
        image_size=(240, 160),
        fallback_order=1,
    )

    assert region is not None
    assert region.bbox == (84, 64, 156, 92)
    assert region.body_bbox == (30, 20, 210, 140)
    assert region.safe_box == (42, 32, 198, 128)


def test_external_ocr_finds_white_caption_container_on_dark_artwork() -> None:
    image = Image.new("RGB", (240, 200), (20, 20, 20))
    draw = ImageDraw.Draw(image)
    panel_bbox = (40, 20, 200, 180)
    draw.rectangle(panel_bbox, fill="white", outline="black", width=4)
    draw.rectangle((88, 48, 112, 152), fill="black")
    draw.rectangle((128, 40, 154, 144), fill="black")
    text_bbox = (84, 38, 158, 156)

    region = scraper._build_external_ocr_region(
        order=1,
        text="RIGHT\nLEFT",
        bbox=text_bbox,
        image=image,
        direction="vertical",
        line_count=2,
    )

    body_bbox = tuple(region["body_bbox"])
    safe_box = tuple(region["safe_box"])
    assert region["background"] == "#FFFFFF"
    assert region["shape"] == "rect"
    assert body_bbox[0] <= panel_bbox[0] + 6
    assert body_bbox[1] <= panel_bbox[1] + 6
    assert body_bbox[2] >= panel_bbox[2] - 6
    assert body_bbox[3] >= panel_bbox[3] - 6
    assert scraper._bbox_area(safe_box) > scraper._bbox_area(text_bbox)


def test_external_ocr_container_detection_has_python_fallback(monkeypatch) -> None:
    monkeypatch.setattr(scraper, "cv2", None)
    monkeypatch.setattr(scraper, "np", None)
    image = Image.new("RGB", (180, 150), (20, 20, 20))
    draw = ImageDraw.Draw(image)
    panel_bbox = (24, 18, 156, 132)
    draw.rectangle(panel_bbox, fill="white", outline="black", width=3)
    draw.rectangle((72, 42, 94, 112), fill="black")

    region = scraper._build_external_ocr_region(
        order=1,
        text="TEXT",
        bbox=(68, 38, 98, 116),
        image=image,
        direction="vertical",
        line_count=1,
    )

    assert region["_container_inferred"] is True
    assert tuple(region["body_bbox"])[0] <= panel_bbox[0] + 5
    assert tuple(region["body_bbox"])[2] >= panel_bbox[2] - 5


def test_external_ocr_rejects_page_background_as_container() -> None:
    image = Image.new("RGB", (220, 180), "white")
    ImageDraw.Draw(image).rectangle((90, 54, 124, 126), fill="black")

    region = scraper._build_external_ocr_region(
        order=1,
        text="TEXT",
        bbox=(86, 50, 128, 130),
        image=image,
        direction="vertical",
        line_count=1,
    )

    assert region["_container_inferred"] is False
    assert scraper._bbox_area(tuple(region["body_bbox"])) < image.width * image.height * 0.3


def test_rapidocr_merges_split_vertical_columns_in_same_caption() -> None:
    image = Image.new("RGB", (240, 200), (20, 20, 20))
    draw = ImageDraw.Draw(image)
    draw.rectangle((40, 20, 200, 180), fill="white", outline="black", width=4)
    draw.rectangle((122, 42, 150, 108), fill="black")
    draw.rectangle((82, 92, 110, 158), fill="black")
    result = SimpleNamespace(
        boxes=[
            [[120.0, 40.0], [154.0, 40.0], [154.0, 110.0], [120.0, 110.0]],
            [[80.0, 90.0], [114.0, 90.0], [114.0, 160.0], [80.0, 160.0]],
        ],
        txts=("RIGHTSIDE", "LEFTSIDE"),
        scores=(0.99, 0.99),
    )

    payload = scraper._build_rapid_ocr_page_payload(
        result,
        image=image,
        image_size=image.size,
        page_number=1,
    )

    assert len(payload.regions) == 1
    assert payload.regions[0].source_text == "RIGHTSIDE\nLEFTSIDE"
    assert payload.regions[0].shape == "rect"
    assert payload.regions[0].body_bbox is not None
    assert payload.regions[0].body_bbox[0] <= 46
    assert payload.regions[0].body_bbox[2] >= 194


def test_hybrid_manga_ocr_keeps_model_layout_and_recovers_windows_text() -> None:
    model_payload = MangaOcrPagePayload(
        page_number=1,
        image_size=(800, 1200),
        regions=[
            MangaOcrRegion(
                order=1,
                bbox=(300, 180, 430, 420),
                body_bbox=(270, 140, 470, 460),
                safe_box=(292, 170, 448, 430),
                source_text="短句",
                source_direction="vertical",
                direction="vertical",
                shape="ellipse",
            ),
            MangaOcrRegion(
                order=2,
                bbox=(80, 760, 260, 850),
                body_bbox=(60, 730, 280, 880),
                source_text="ドン！",
                source_direction="horizontal",
                direction="horizontal",
            ),
        ],
        diagnostics={"ocr_backend": "openai_vision"},
    )
    windows_payload = MangaOcrPagePayload(
        page_number=1,
        image_size=(800, 1200),
        regions=[
            MangaOcrRegion(
                order=1,
                bbox=(308, 188, 424, 414),
                body_bbox=(294, 174, 440, 432),
                source_text="这是更完整的识别文字",
                source_direction="vertical",
                direction="vertical",
            )
        ],
        diagnostics={"ocr_backend": "windows"},
    )

    merged = scraper._merge_hybrid_manga_ocr_payloads(model_payload, windows_payload)

    assert len(merged.regions) == 2
    assert merged.regions[0].source_text == "这是更完整的识别文字"
    assert merged.regions[0].body_bbox == (270, 140, 470, 460)
    assert merged.regions[0].safe_box == (292, 170, 448, 430)
    assert merged.regions[1].source_text == "ドン！"
    assert merged.diagnostics["ocr_backend"] == "hybrid_windows_openai"
    assert merged.diagnostics["model_region_count"] == 2
    assert merged.diagnostics["windows_region_count"] == 1


def test_hybrid_manga_ocr_merges_text_box_contained_by_model_body() -> None:
    model_payload = MangaOcrPagePayload(
        page_number=1,
        image_size=(640, 420),
        regions=[
            MangaOcrRegion(
                order=1,
                bbox=(120, 80, 520, 330),
                body_bbox=(100, 60, 540, 350),
                safe_box=(130, 90, 510, 320),
                source_text="HELLO\nWORLD",
                source_direction="horizontal",
                direction="horizontal",
            )
        ],
        diagnostics={"ocr_backend": "openai_vision"},
    )
    windows_payload = MangaOcrPagePayload(
        page_number=1,
        image_size=(640, 420),
        regions=[
            MangaOcrRegion(
                order=1,
                bbox=(220, 160, 420, 220),
                body_bbox=(210, 150, 430, 230),
                source_text="HELLO WORLD",
                source_direction="horizontal",
                direction="horizontal",
            )
        ],
        diagnostics={"ocr_backend": "windows"},
    )

    merged = scraper._merge_hybrid_manga_ocr_payloads(model_payload, windows_payload)

    assert len(merged.regions) == 1
    assert merged.regions[0].body_bbox == (100, 60, 540, 350)
    assert merged.diagnostics["hybrid_merged_region_count"] == 1


def test_hybrid_manga_ocr_does_not_match_equal_text_across_distant_regions() -> None:
    model_payload = MangaOcrPagePayload(
        page_number=1,
        image_size=(720, 1024),
        regions=[MangaOcrRegion(order=1, bbox=(619, 429, 653, 439), source_text="0 0")],
    )
    windows_payload = MangaOcrPagePayload(
        page_number=1,
        image_size=(720, 1024),
        regions=[MangaOcrRegion(order=1, bbox=(304, 74, 430, 249), source_text="M0.00")],
    )

    merged = scraper._merge_hybrid_manga_ocr_payloads(model_payload, windows_payload)

    assert len(merged.regions) == 2
    assert {region.bbox for region in merged.regions} == {
        (619, 429, 653, 439),
        (304, 74, 430, 249),
    }


def test_local_manga_ocr_keeps_complete_rapidocr_geometry_and_background() -> None:
    rapid_payload = MangaOcrPagePayload(
        page_number=1,
        image_size=(700, 1000),
        regions=[
            MangaOcrRegion(
                order=1,
                bbox=(536, 62, 625, 200),
                body_bbox=(532, 58, 629, 204),
                safe_box=(538, 64, 623, 198),
                source_text="今日も\n来てくれて\nありがとー！",
                background="#FEFEFE",
                source_direction="vertical",
                direction="vertical",
                shape="ellipse",
            )
        ],
        diagnostics={"ocr_backend": "rapidocr"},
    )
    windows_payload = MangaOcrPagePayload(
        page_number=1,
        image_size=(700, 1000),
        regions=[
            MangaOcrRegion(
                order=1,
                bbox=(570, 71, 617, 91),
                body_bbox=(570, 71, 617, 91),
                safe_box=(570, 71, 617, 91),
                source_text="来 兮",
                background="#020202",
                source_direction="horizontal",
                direction="horizontal",
                shape="rect",
            ),
            MangaOcrRegion(
                order=2,
                bbox=(40, 820, 92, 842),
                source_text="冫 了 、",
                background="#FEFEFE",
                direction="horizontal",
            ),
        ],
        diagnostics={"ocr_backend": "windows"},
    )

    merged = scraper._merge_local_manga_ocr_payloads(rapid_payload, windows_payload)

    assert len(merged.regions) == 1
    assert merged.regions[0].source_text == "今日も\n来てくれて\nありがとー！"
    assert merged.regions[0].bbox == (536, 62, 625, 200)
    assert merged.regions[0].body_bbox == (532, 58, 629, 204)
    assert merged.regions[0].safe_box == (538, 64, 623, 198)
    assert merged.regions[0].background == "#FEFEFE"
    assert merged.regions[0].direction == "vertical"


def test_hybrid_manga_ocr_collapses_conflicting_model_regions_around_windows_text() -> None:
    model_payload = MangaOcrPagePayload(
        page_number=1,
        image_size=(640, 420),
        regions=[
            MangaOcrRegion(
                order=1,
                bbox=(350, 150, 550, 250),
                body_bbox=(350, 150, 550, 250),
                source_text="おはようございます架空文字",
                direction="horizontal",
            ),
            MangaOcrRegion(
                order=2,
                bbox=(106, 204, 536, 250),
                body_bbox=(106, 204, 536, 250),
                source_text="HELLO WORLD",
                direction="horizontal",
            ),
        ],
    )
    windows_payload = MangaOcrPagePayload(
        page_number=1,
        image_size=(640, 420),
        regions=[
            MangaOcrRegion(
                order=1,
                bbox=(106, 204, 536, 250),
                body_bbox=(106, 204, 536, 250),
                source_text="HELLO WORLD",
                direction="horizontal",
            )
        ],
    )

    merged = scraper._merge_hybrid_manga_ocr_payloads(model_payload, windows_payload)

    assert len(merged.regions) == 1
    assert merged.regions[0].source_text == "HELLO WORLD"
    assert merged.diagnostics["hybrid_merged_region_count"] == 2


def test_vision_ocr_image_evidence_rejects_blank_and_border_only_regions() -> None:
    image = Image.new("RGB", (640, 420), "white")
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((80, 70, 560, 350), radius=60, outline=(30, 30, 30), width=5)
    font = scraper._load_local_render_font(58, bold=True)
    draw.text((106, 190), "HELLO WORLD", font=font, fill=(20, 20, 20))
    payload = MangaOcrPagePayload(
        page_number=1,
        image_size=image.size,
        regions=[
            MangaOcrRegion(order=1, bbox=(50, 20, 590, 90), source_text="标题"),
            MangaOcrRegion(order=2, bbox=(100, 120, 300, 180), source_text="空白"),
            MangaOcrRegion(order=3, bbox=(106, 190, 536, 250), source_text="HELLO WORLD"),
            MangaOcrRegion(order=4, bbox=(200, 300, 450, 380), source_text="音效"),
        ],
    )

    filtered = scraper._filter_manga_ocr_regions_by_image_evidence(payload, image)

    assert [region.source_text for region in filtered.regions] == ["HELLO WORLD"]
    assert filtered.diagnostics["image_evidence_rejected_region_count"] == 3


def test_rapid_ocr_result_builds_local_regions_with_confidence() -> None:
    image = Image.new("RGB", (640, 420), "white")
    result = SimpleNamespace(
        boxes=[[[99.0, 183.0], [540.0, 183.0], [540.0, 240.0], [99.0, 240.0]]],
        txts=("HELLO WORLD",),
        scores=(0.99965,),
    )

    payload = scraper._build_rapid_ocr_page_payload(
        result,
        image=image,
        image_size=image.size,
        page_number=1,
    )

    assert len(payload.regions) == 1
    assert payload.regions[0].source_text == "HELLO WORLD"
    assert payload.regions[0].bbox == (99, 183, 540, 240)
    assert payload.diagnostics["ocr_backend"] == "rapidocr"
    assert payload.diagnostics["average_confidence"] > 0.99


def test_external_ocr_does_not_chain_large_single_glyph_sound_effect_into_dialogue() -> None:
    items = [
        {"bbox": (109, 790, 180, 912), "text": "ッ", "direction": "vertical"},
        {"bbox": (206, 848, 238, 938), "text": "フォッグ", "direction": "vertical"},
        {"bbox": (225, 845, 270, 914), "text": "霧の国", "direction": "vertical"},
    ]

    merged = scraper._merge_external_ocr_lines(items)

    assert len(merged) == 2
    assert any(item["text"] == "ッ" for item in merged)
    assert any("フォッグ" in item["text"] and "霧の国" in item["text"] for item in merged)


def test_hybrid_confirmation_drops_unstable_regions_not_seen_by_local_ocr() -> None:
    primary = MangaOcrPagePayload(
        page_number=1,
        image_size=(640, 420),
        regions=[
            MangaOcrRegion(order=1, bbox=(106, 190, 536, 250), source_text="HELLO WORLD"),
            MangaOcrRegion(order=2, bbox=(40, 40, 300, 120), source_text="不稳定误检"),
        ],
    )
    verification = MangaOcrPagePayload(
        page_number=1,
        image_size=(640, 420),
        regions=[MangaOcrRegion(order=1, bbox=(108, 192, 534, 248), source_text="HELLO WORLD")],
    )
    windows_payload = MangaOcrPagePayload(
        page_number=1,
        image_size=(640, 420),
        regions=[MangaOcrRegion(order=1, bbox=(106, 190, 536, 250), source_text="HELLO WORLD")],
    )

    confirmed = scraper._confirm_hybrid_model_regions(primary, verification, windows_payload)

    assert [region.source_text for region in confirmed.regions] == ["HELLO WORLD"]
    assert confirmed.diagnostics["vision_confirmation_rejected_region_count"] == 1


def test_disabled_translation_model_is_not_silently_enabled() -> None:
    settings = TranslationSettings(
        translationModel=OpenAICompatibleConfig(
            enabled=False,
            baseUrl="https://api.openai.com/v1",
            apiKey="secret",
            model="vision-model",
        )
    )

    with pytest.raises(ValueError, match="模型未启用"):
        scraper._resolve_manga_image_provider_config(settings)


@pytest.mark.parametrize(
    ("configured_url", "expected_base_url"),
    [
        ("https://proxy.example.test", "https://proxy.example.test/v1"),
        ("https://proxy.example.test/", "https://proxy.example.test/v1"),
        ("https://proxy.example.test/v1", "https://proxy.example.test/v1"),
        (
            "https://proxy.example.test/v1/chat/completions",
            "https://proxy.example.test/v1",
        ),
    ],
)
def test_translation_model_normalizes_openai_base_url(
    configured_url: str,
    expected_base_url: str,
) -> None:
    settings = TranslationSettings(
        translationModel=OpenAICompatibleConfig(
            enabled=True,
            baseUrl=configured_url,
            apiKey="secret",
            model="text-model",
        )
    )

    base_url, _, _ = scraper._resolve_openai_compatible_model_config(
        settings,
        feature_name="翻译",
    )

    assert base_url == expected_base_url


@pytest.mark.asyncio
async def test_translation_response_reports_empty_body_clearly() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"", request=request)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(ValueError) as exc_info:
            await scraper._post_translation_json(
                client,
                "https://example.com/v1/chat/completions",
                headers={"Authorization": "Bearer secret"},
                payload={"model": "text-model", "messages": []},
                max_retries=1,
            )

    message = str(exc_info.value)
    assert "空响应" in message
    assert "HTTP 200" in message
    assert "/v1/chat/completions" in message
    assert "secret" not in message
    assert "Expecting value" not in message


@pytest.mark.asyncio
async def test_translation_response_reports_non_json_body_safely() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            text="<html><body>upstream gateway unavailable</body></html>",
            headers={"Content-Type": "text/html; charset=utf-8"},
            request=request,
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(ValueError) as exc_info:
            await scraper._post_translation_json(
                client,
                "https://example.com/v1/chat/completions",
                headers={},
                payload={"model": "text-model", "messages": []},
                max_retries=1,
            )

    message = str(exc_info.value)
    assert "非 JSON" in message
    assert "text/html" in message
    assert "upstream gateway unavailable" in message
    assert "Expecting value" not in message


@pytest.mark.asyncio
async def test_translation_response_surfaces_openai_error_message() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            401,
            json={"error": {"message": "Invalid API key"}},
            request=request,
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(ValueError) as exc_info:
            await scraper._post_translation_json(
                client,
                "https://example.com/v1/chat/completions",
                headers={"Authorization": "Bearer secret"},
                payload={"model": "text-model", "messages": []},
                max_retries=1,
            )

    message = str(exc_info.value)
    assert "HTTP 401" in message
    assert "Invalid API key" in message
    assert "secret" not in message


@pytest.mark.asyncio
async def test_default_manga_ocr_runs_vision_and_local_ocr_together(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(scraper.os, "name", "nt")
    image_path = tmp_path / "page.png"
    Image.new("RGB", (640, 960), "white").save(image_path)
    settings = TranslationSettings(
        translationModel=OpenAICompatibleConfig(
            enabled=True,
            baseUrl="https://gateway.example.test/v1",
            apiKey="secret",
            model="vision-model",
            supportsVision=True,
        ),
        mangaOcr=MangaOcrConfig(enabled=False, baseUrl=""),
    )
    calls: list[str] = []

    async def fake_windows(**_: object) -> MangaOcrPagePayload:
        calls.append("windows")
        return MangaOcrPagePayload(
            page_number=1,
            image_size=(640, 960),
            regions=[MangaOcrRegion(order=1, bbox=(20, 20, 120, 80), source_text="本机")],
        )

    async def fake_vision(**_: object) -> MangaOcrPagePayload:
        calls.append("vision")
        return MangaOcrPagePayload(
            page_number=1,
            image_size=(640, 960),
            regions=[
                MangaOcrRegion(
                    order=1,
                    bbox=(22, 22, 118, 78),
                    body_bbox=(10, 10, 130, 90),
                    source_text="视觉模型补全",
                )
            ],
        )

    monkeypatch.setattr(scraper, "_request_windows_ocr_regions_payload", fake_windows)
    monkeypatch.setattr(scraper, "_request_rapid_ocr_regions_payload", fake_windows)
    monkeypatch.setattr(scraper, "_request_openai_vision_ocr_regions_payload", fake_vision)

    payload = await scraper._request_manga_ocr_regions_payload(
        settings=settings,
        base_url=settings.translationModel.baseUrl,
        api_key=settings.translationModel.apiKey,
        model=settings.translationModel.model,
        image_path=image_path,
        timeout_seconds=30,
        page_number=1,
    )

    assert sorted(calls) == ["vision", "vision", "windows", "windows"]
    assert payload.diagnostics["ocr_backend"] == "hybrid_local_openai"
    assert payload.regions[0].source_text == "本机"
    assert payload.diagnostics["vision_confirmation_region_count"] == 1


@pytest.mark.asyncio
async def test_text_only_model_uses_local_ocr_without_sending_the_image(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(scraper.os, "name", "nt")
    image_path = tmp_path / "page.png"
    Image.new("RGB", (640, 960), "white").save(image_path)
    settings = TranslationSettings(
        translationModel=OpenAICompatibleConfig(
            enabled=True,
            baseUrl="https://gateway.example.test/v1",
            apiKey="secret",
            model="text-only-model",
            supportsVision=False,
        ),
        mangaOcr=MangaOcrConfig(enabled=False, baseUrl=""),
    )
    calls: list[str] = []

    async def fake_windows(**_: object) -> MangaOcrPagePayload:
        calls.append("windows")
        return MangaOcrPagePayload(
            page_number=1,
            image_size=(640, 960),
            regions=[MangaOcrRegion(order=1, bbox=(20, 20, 120, 80), source_text="本机文字")],
        )

    async def fake_rapid(**_: object) -> MangaOcrPagePayload:
        calls.append("rapidocr")
        return MangaOcrPagePayload(
            page_number=1,
            image_size=(640, 960),
            regions=[MangaOcrRegion(order=1, bbox=(21, 21, 121, 81), source_text="本机文字")],
        )

    async def forbidden_vision(**_: object) -> MangaOcrPagePayload:
        raise AssertionError("纯文本模型不应接收漫画图片")

    monkeypatch.setattr(scraper, "_request_windows_ocr_regions_payload", fake_windows)
    monkeypatch.setattr(scraper, "_request_rapid_ocr_regions_payload", fake_rapid)
    monkeypatch.setattr(scraper, "_request_openai_vision_ocr_regions_payload", forbidden_vision)

    payload = await scraper._request_manga_ocr_regions_payload(
        settings=settings,
        base_url=settings.translationModel.baseUrl,
        api_key=settings.translationModel.apiKey,
        model=settings.translationModel.model,
        image_path=image_path,
        timeout_seconds=30,
        page_number=1,
    )

    assert sorted(calls) == ["rapidocr", "windows"]
    assert len(payload.regions) == 1
    assert payload.regions[0].source_text == "本机文字"
    assert payload.diagnostics["ocr_backend"] == "local_rapidocr_windows"


@pytest.mark.asyncio
async def test_high_confidence_rapidocr_skips_slower_windows_ocr(monkeypatch, tmp_path) -> None:
    monkeypatch.setattr(scraper.os, "name", "nt")
    image_path = tmp_path / "page.png"
    Image.new("RGB", (640, 960), "white").save(image_path)

    async def fake_rapid(**_: object) -> MangaOcrPagePayload:
        return MangaOcrPagePayload(
            page_number=1,
            image_size=(640, 960),
            regions=[MangaOcrRegion(order=1, bbox=(20, 20, 120, 80), source_text="文字")],
            diagnostics={"ocr_backend": "rapidocr", "average_confidence": 0.96},
        )

    async def forbidden_windows(**_: object) -> MangaOcrPagePayload:
        raise AssertionError("高置信度 RapidOCR 不应等待 Windows OCR")

    monkeypatch.setattr(scraper, "_request_rapid_ocr_regions_payload", fake_rapid)
    monkeypatch.setattr(scraper, "_request_windows_ocr_regions_payload", forbidden_windows)

    payload = await scraper._request_local_manga_ocr_regions_payload(
        settings=TranslationSettings(),
        image_path=image_path,
        image_size=(640, 960),
        timeout_seconds=30,
        page_number=1,
    )

    assert payload.diagnostics["windows_ocr_skipped"] == "rapidocr_high_confidence"


@pytest.mark.asyncio
async def test_linux_local_ocr_never_invokes_windows_ocr(monkeypatch, tmp_path) -> None:
    image_path = tmp_path / "page.png"
    Image.new("RGB", (320, 480), "white").save(image_path)
    calls: list[str] = []

    async def fake_rapid(**_: object) -> MangaOcrPagePayload:
        calls.append("rapidocr")
        return MangaOcrPagePayload(page_number=1, image_size=(320, 480))

    async def forbidden_windows(**_: object) -> MangaOcrPagePayload:
        raise AssertionError("Linux 后端不得调用 Windows OCR")

    monkeypatch.setattr(scraper.os, "name", "posix")
    monkeypatch.setattr(scraper, "_request_rapid_ocr_regions_payload", fake_rapid)
    monkeypatch.setattr(scraper, "_request_windows_ocr_regions_payload", forbidden_windows)

    payload = await scraper._request_local_manga_ocr_regions_payload(
        settings=TranslationSettings(),
        image_path=image_path,
        image_size=(320, 480),
        timeout_seconds=30,
        page_number=1,
    )

    assert calls == ["rapidocr"]
    assert payload.page_number == 1


@pytest.mark.asyncio
async def test_manga_translation_sends_only_ocr_text_to_text_model(monkeypatch) -> None:
    captured_payload: dict[str, object] = {}

    async def fake_post(*_: object, **kwargs: object) -> dict[str, object]:
        captured_payload.update(kwargs["payload"])
        return {
            "choices": [{"message": {"content": '{"translations":[{"order":1,"translation":"你好世界"}]}'}}]
        }

    monkeypatch.setattr(scraper, "_post_translation_json", fake_post)
    regions = [
        MangaOcrRegion(
            order=1,
            bbox=(20, 20, 180, 80),
            source_text="HELLO WORLD",
            direction="horizontal",
        )
    ]

    translated = await scraper._translate_manga_region_batch(
        settings=TranslationSettings(),
        base_url="https://gateway.example.test/v1",
        api_key="secret",
        model="text-only-model",
        target_language="Chinese",
        chapter_title="",
        chapter_index=1,
        page_number=1,
        total_pages=1,
        regions=regions,
        timeout_seconds=30,
    )

    user_content = captured_payload["messages"][1]["content"]
    assert isinstance(user_content, str)
    assert "image_url" not in user_content
    assert translated[0].translation == "你好世界"


@pytest.mark.asyncio
async def test_manga_translation_rewrites_over_budget_result_more_concisely(monkeypatch) -> None:
    submitted_payloads: list[dict[str, object]] = []

    async def fake_post(*_: object, **kwargs: object) -> dict[str, object]:
        submitted_payloads.append(dict(kwargs["payload"]))
        translation = "现在立刻马上从这里快速离开不要停留" if len(submitted_payloads) == 1 else "快离开"
        return {
            "choices": [
                {
                    "message": {
                        "content": scraper.json.dumps(
                            {"translations": [{"order": 1, "translation": translation}]},
                            ensure_ascii=False,
                        )
                    }
                }
            ]
        }

    monkeypatch.setattr(scraper, "_post_translation_json", fake_post)
    regions = [
        MangaOcrRegion(
            order=1,
            bbox=(20, 20, 120, 60),
            safe_box=(28, 24, 112, 56),
            source_text="GET OUT OF HERE RIGHT NOW",
            direction="horizontal",
        )
    ]

    translated = await scraper._translate_manga_region_batch(
        settings=TranslationSettings(),
        base_url="https://gateway.example.test/v1",
        api_key="secret",
        model="text-only-model",
        target_language="Chinese",
        chapter_title="",
        chapter_index=1,
        page_number=1,
        total_pages=1,
        regions=regions,
        timeout_seconds=30,
    )

    assert len(submitted_payloads) == 2
    compact_prompt = submitted_payloads[1]["messages"][1]["content"]
    assert isinstance(compact_prompt, str)
    assert "hard maximum" in compact_prompt
    assert "current_translation" in compact_prompt
    assert translated[0].translation == "快离开"


@pytest.mark.asyncio
async def test_deepseek_v4_translation_disables_thinking_and_retries_exhausted_output(
    monkeypatch,
) -> None:
    submitted_payloads: list[dict[str, object]] = []

    async def fake_post(*_: object, **kwargs: object) -> dict[str, object]:
        submitted_payloads.append(dict(kwargs["payload"]))
        if len(submitted_payloads) == 1:
            return {
                "choices": [
                    {
                        "finish_reason": "length",
                        "message": {
                            "content": "",
                            "reasoning_content": "reasoning consumed the whole output budget",
                        },
                    }
                ]
            }
        return {
            "choices": [
                {
                    "finish_reason": "stop",
                    "message": {"content": '{"translations":[{"order":1,"translation":"你好世界"}]}'},
                }
            ]
        }

    monkeypatch.setattr(scraper, "_post_translation_json", fake_post)

    translated = await scraper._translate_manga_region_batch(
        settings=TranslationSettings(),
        base_url="https://gateway.example.test/v1",
        api_key="secret",
        model="deepseek-v4-flash",
        target_language="Chinese",
        chapter_title="",
        chapter_index=1,
        page_number=1,
        total_pages=1,
        regions=[MangaOcrRegion(order=1, bbox=(20, 20, 180, 80), source_text="HELLO WORLD")],
        timeout_seconds=30,
    )

    assert len(submitted_payloads) == 2
    assert submitted_payloads[0]["thinking"] == {"type": "disabled"}
    assert submitted_payloads[0]["response_format"] == {"type": "json_object"}
    assert submitted_payloads[1]["thinking"] == {"type": "disabled"}
    assert submitted_payloads[1]["response_format"] == {"type": "json_object"}
    assert int(submitted_payloads[1]["max_tokens"]) >= 8000
    assert translated[0].translation == "你好世界"


@pytest.mark.asyncio
async def test_manga_translation_replaces_existing_workflow_region_translation(
    monkeypatch,
) -> None:
    async def fake_post(*_: object, **__: object) -> dict[str, object]:
        return {
            "choices": [
                {
                    "finish_reason": "stop",
                    "message": {"content": '{"translations":[{"order":1,"translation":"新译文"}]}'},
                }
            ]
        }

    monkeypatch.setattr(scraper, "_post_translation_json", fake_post)

    translated = await scraper._translate_manga_region_batch(
        settings=TranslationSettings(),
        base_url="https://gateway.example.test/v1",
        api_key="secret",
        model="text-only-model",
        target_language="Chinese",
        chapter_title="",
        chapter_index=1,
        page_number=2,
        total_pages=2,
        regions=[
            MangaTranslatedRegion(
                order=1,
                bbox=(20, 20, 180, 80),
                source_text="SOURCE",
                translation="旧译文",
            )
        ],
        timeout_seconds=30,
    )

    assert translated[0].source_text == "SOURCE"
    assert translated[0].translation == "新译文"


@pytest.mark.parametrize(
    "raw_payload, regions",
    [
        (
            {"translations": [{"order": 2, "translation": "第二项"}]},
            [
                MangaOcrRegion(order=1, source_text="FIRST"),
                MangaOcrRegion(order=2, source_text="SECOND"),
            ],
        ),
        (
            {"translations": [{"order": 2, "translation": "未知项"}]},
            [MangaOcrRegion(order=1, source_text="FIRST")],
        ),
        (
            {
                "translations": [
                    {"order": 1, "translation": "第一项"},
                    {"order": 1, "translation": "重复项"},
                ]
            },
            [
                MangaOcrRegion(order=1, source_text="FIRST"),
                MangaOcrRegion(order=2, source_text="SECOND"),
            ],
        ),
        (
            {"translations": [{"order": 1, "translation": ""}]},
            [MangaOcrRegion(order=1, source_text="FIRST")],
        ),
    ],
)
def test_manga_translation_requires_exact_non_empty_order_coverage(
    raw_payload: dict[str, object],
    regions: list[MangaOcrRegion],
) -> None:
    with pytest.raises(ValueError):
        scraper._coerce_manga_translated_regions(
            raw_payload,
            regions,
            target_language="中文",
        )


def test_manga_translation_may_leave_punctuation_only_region_unchanged() -> None:
    translated = scraper._coerce_manga_translated_regions(
        {"translations": [{"order": 1, "translation": ""}]},
        [MangaOcrRegion(order=1, source_text="……")],
        target_language="中文",
    )

    assert translated[0].translation == ""


@pytest.mark.asyncio
async def test_manga_translation_retries_incomplete_order_coverage_without_cross_assignment(
    monkeypatch,
) -> None:
    submitted_payloads: list[dict[str, object]] = []

    async def fake_post(*_: object, **kwargs: object) -> dict[str, object]:
        submitted_payloads.append(dict(kwargs["payload"]))
        if len(submitted_payloads) == 1:
            content = '{"translations":[{"order":2,"translation":"第二项"}]}'
        else:
            content = (
                '{"translations":[{"order":1,"translation":"第一项"},{"order":2,"translation":"第二项"}]}'
            )
        return {"choices": [{"finish_reason": "stop", "message": {"content": content}}]}

    monkeypatch.setattr(scraper, "_post_translation_json", fake_post)

    translated = await scraper._translate_manga_region_batch(
        settings=TranslationSettings(),
        base_url="https://gateway.example.test/v1",
        api_key="secret",
        model="text-only-model",
        target_language="Chinese",
        chapter_title="",
        chapter_index=1,
        page_number=1,
        total_pages=1,
        regions=[
            MangaOcrRegion(order=1, bbox=(20, 20, 220, 100), source_text="FIRST"),
            MangaOcrRegion(order=2, bbox=(20, 120, 220, 200), source_text="SECOND"),
        ],
        timeout_seconds=30,
    )

    assert len(submitted_payloads) == 2
    retry_prompt = submitted_payloads[1]["messages"][1]["content"]
    assert "Do not omit, duplicate, or invent orders" in retry_prompt
    assert [region.translation for region in translated] == ["第一项", "第二项"]


@pytest.mark.asyncio
async def test_manga_translation_still_rejects_missing_order_after_retry(
    monkeypatch,
) -> None:
    submitted_payloads: list[dict[str, object]] = []

    async def fake_post(*_: object, **kwargs: object) -> dict[str, object]:
        submitted_payloads.append(dict(kwargs["payload"]))
        content = '{"translations":[{"order":2,"translation":"第二项"}]}'
        return {"choices": [{"finish_reason": "stop", "message": {"content": content}}]}

    monkeypatch.setattr(scraper, "_post_translation_json", fake_post)

    with pytest.raises(ValueError, match="缺少 order：1"):
        await scraper._translate_manga_region_batch(
            settings=TranslationSettings(),
            base_url="https://gateway.example.test/v1",
            api_key="secret",
            model="text-only-model",
            target_language="Chinese",
            chapter_title="",
            chapter_index=1,
            page_number=1,
            total_pages=1,
            regions=[
                MangaOcrRegion(order=1, bbox=(20, 20, 220, 100), source_text="FIRST"),
                MangaOcrRegion(order=2, bbox=(20, 120, 220, 200), source_text="SECOND"),
            ],
            timeout_seconds=30,
        )

    assert len(submitted_payloads) == 2


@pytest.mark.asyncio
async def test_manga_translation_retries_unchanged_japanese_short_utterance_for_chinese(
    monkeypatch,
) -> None:
    submitted_payloads: list[dict[str, object]] = []

    async def fake_post(*_: object, **kwargs: object) -> dict[str, object]:
        submitted_payloads.append(dict(kwargs["payload"]))
        translation = "ねー" if len(submitted_payloads) == 1 else "对吧—"
        content = scraper.json.dumps(
            {"translations": [{"order": 1, "translation": translation}]},
            ensure_ascii=False,
        )
        return {"choices": [{"finish_reason": "stop", "message": {"content": content}}]}

    monkeypatch.setattr(scraper, "_post_translation_json", fake_post)

    translated = await scraper._translate_manga_region_batch(
        settings=TranslationSettings(),
        base_url="https://gateway.example.test/v1",
        api_key="secret",
        model="text-only-model",
        target_language="Chinese",
        chapter_title="",
        chapter_index=1,
        page_number=1,
        total_pages=1,
        regions=[MangaOcrRegion(order=1, bbox=(20, 20, 220, 100), source_text="ねー")],
        timeout_seconds=30,
    )

    assert len(submitted_payloads) == 2
    first_prompt = submitted_payloads[0]["messages"][1]["content"]
    assert "short utterances" in first_prompt
    assert "Pure punctuation" in first_prompt
    assert translated[0].translation == "对吧—"


@pytest.mark.asyncio
async def test_manga_translation_repairs_only_the_unchanged_region(
    monkeypatch,
) -> None:
    submitted_payloads: list[dict[str, object]] = []

    async def fake_post(*_: object, **kwargs: object) -> dict[str, object]:
        submitted_payloads.append(dict(kwargs["payload"]))
        if len(submitted_payloads) == 1:
            translations = [
                {"order": 1, "translation": "小静今天休息"},
                {"order": 2, "translation": "诶？"},
                {"order": 3, "translation": "スク"},
            ]
        else:
            translations = [{"order": 3, "translation": "唰"}]
        content = scraper.json.dumps({"translations": translations}, ensure_ascii=False)
        return {"choices": [{"finish_reason": "stop", "message": {"content": content}}]}

    monkeypatch.setattr(scraper, "_post_translation_json", fake_post)

    translated = await scraper._translate_manga_region_batch(
        settings=TranslationSettings(),
        base_url="https://gateway.example.test/v1",
        api_key="secret",
        model="deepseek-v4-flash",
        target_language="中文",
        chapter_title="しず子、熱を出す",
        chapter_index=1,
        page_number=2,
        total_pages=8,
        regions=[
            MangaOcrRegion(order=1, bbox=(10, 10, 120, 220), source_text="しず子\nお休みなの"),
            MangaOcrRegion(order=2, bbox=(929, 235, 1024, 334), source_text="之"),
            MangaOcrRegion(order=3, bbox=(1139, 252, 1314, 377), source_text="スク"),
        ],
        timeout_seconds=30,
    )

    assert len(submitted_payloads) == 2
    repair_prompt = submitted_payloads[1]["messages"][1]["content"]
    assert '"order": 3' in repair_prompt
    assert '"order": 1' not in repair_prompt
    assert '"order": 2' not in repair_prompt
    assert [region.translation for region in translated] == ["小静今天休息", "诶？", "唰"]


@pytest.mark.asyncio
async def test_manga_translation_keeps_stubborn_fragment_without_failing_page(
    monkeypatch,
) -> None:
    submitted_payloads: list[dict[str, object]] = []

    async def fake_post(*_: object, **kwargs: object) -> dict[str, object]:
        submitted_payloads.append(dict(kwargs["payload"]))
        translations = (
            [
                {"order": 1, "translation": "小静今天休息"},
                {"order": 2, "translation": "诶？"},
                {"order": 3, "translation": "スク"},
            ]
            if len(submitted_payloads) == 1
            else [{"order": 3, "translation": "スク"}]
        )
        content = scraper.json.dumps({"translations": translations}, ensure_ascii=False)
        return {"choices": [{"finish_reason": "stop", "message": {"content": content}}]}

    monkeypatch.setattr(scraper, "_post_translation_json", fake_post)
    source_regions = [
        MangaOcrRegion(order=1, bbox=(10, 10, 120, 220), source_text="しず子\nお休みなの"),
        MangaOcrRegion(order=2, bbox=(929, 235, 1024, 334), source_text="之"),
        MangaOcrRegion(order=3, bbox=(1139, 252, 1314, 377), source_text="スク"),
    ]

    translated = await scraper._translate_manga_region_batch(
        settings=TranslationSettings(),
        base_url="https://gateway.example.test/v1",
        api_key="secret",
        model="deepseek-v4-flash",
        target_language="中文",
        chapter_title="しず子、熱を出す",
        chapter_index=1,
        page_number=2,
        total_pages=8,
        regions=source_regions,
        timeout_seconds=30,
    )

    diagnostics = scraper._build_manga_page_translation_diagnostics(
        MangaOcrPagePayload(
            page_number=2,
            image_size=(1433, 2024),
            regions=source_regions,
        ),
        translated,
        target_language="中文",
    )
    assert len(submitted_payloads) == 3
    assert "Targeted repair attempt 2 of 2" in submitted_payloads[2]["messages"][1]["content"]
    assert [region.translation for region in translated] == ["小静今天休息", "诶？", "スク"]
    assert diagnostics["unresolved_translation_region_count"] == 1
    assert diagnostics["unresolved_translation_orders"] == [3]


@pytest.mark.asyncio
async def test_manga_translation_retries_malformed_model_json(monkeypatch) -> None:
    submitted_payloads: list[dict[str, object]] = []

    async def fake_post(*_: object, **kwargs: object) -> dict[str, object]:
        submitted_payloads.append(dict(kwargs["payload"]))
        if len(submitted_payloads) == 1:
            content = '{"translations":[{"order":1,"translation":"多个"国""}]}'
        else:
            content = '{"translations":[{"order":1,"translation":"多个国家"}]}'
        return {
            "choices": [
                {
                    "finish_reason": "stop",
                    "message": {"content": content},
                }
            ]
        }

    monkeypatch.setattr(scraper, "_post_translation_json", fake_post)

    translated = await scraper._translate_manga_region_batch(
        settings=TranslationSettings(),
        base_url="https://gateway.example.test/v1",
        api_key="secret",
        model="deepseek-v4-flash",
        target_language="Chinese",
        chapter_title="",
        chapter_index=1,
        page_number=2,
        total_pages=17,
        regions=[MangaOcrRegion(order=1, bbox=(20, 20, 180, 80), source_text="COUNTRY")],
        timeout_seconds=30,
    )

    assert len(submitted_payloads) == 2
    assert submitted_payloads[0]["response_format"] == {"type": "json_object"}
    retry_messages = submitted_payloads[1]["messages"]
    assert "invalid JSON" in retry_messages[0]["content"]
    assert translated[0].translation == "多个国家"


@pytest.mark.asyncio
async def test_translation_reports_reasoning_budget_exhaustion_after_retry(monkeypatch) -> None:
    async def fake_post(*_: object, **__: object) -> dict[str, object]:
        return {
            "choices": [
                {
                    "finish_reason": "length",
                    "message": {
                        "content": "",
                        "reasoning_content": "reasoning consumed the whole output budget",
                    },
                }
            ]
        }

    monkeypatch.setattr(scraper, "_post_translation_json", fake_post)

    with pytest.raises(ValueError, match="推理过程耗尽"):
        await scraper._translate_manga_region_batch(
            settings=TranslationSettings(),
            base_url="https://gateway.example.test/v1",
            api_key="secret",
            model="deepseek-v4-flash",
            target_language="Chinese",
            chapter_title="",
            chapter_index=1,
            page_number=1,
            total_pages=1,
            regions=[MangaOcrRegion(order=1, bbox=(20, 20, 180, 80), source_text="HELLO WORLD")],
            timeout_seconds=30,
        )


def test_rapidocr_uses_fast_manga_detection_settings(monkeypatch, tmp_path) -> None:
    image_path = tmp_path / "page.png"
    Image.new("RGB", (64, 64), "white").save(image_path)
    captured: dict[str, object] = {}

    class FakeRapidOCR:
        def __init__(self, *, params: dict[str, object]) -> None:
            captured["params"] = params

        def __call__(self, path, *, use_cls: bool):
            captured["path"] = path
            captured["use_cls"] = use_cls
            return SimpleNamespace(boxes=[], txts=[], scores=[])

    monkeypatch.setattr(scraper, "_RAPID_OCR_ENGINE", None)
    monkeypatch.setattr(
        scraper.importlib,
        "import_module",
        lambda _: SimpleNamespace(RapidOCR=FakeRapidOCR),
    )

    scraper._run_rapid_ocr_sync(image_path)

    params = captured["params"]
    assert isinstance(params, dict)
    assert params["Det.limit_side_len"] == 512
    assert params["Det.limit_type"] == "min"
    assert captured["use_cls"] is False


@pytest.mark.asyncio
async def test_manga_translation_resumes_completed_pages_from_checkpoint(
    monkeypatch,
    tmp_path,
) -> None:
    image_dir = tmp_path / "images"
    image_dir.mkdir()
    image_files = ["images/page-1.png", "images/page-2.png"]
    for asset_path in image_files:
        (tmp_path / asset_path).write_bytes(PNG_1X1)

    checkpoint_path = tmp_path / "chapter.translated.json.part"
    settings = TranslationSettings(
        translationModel=OpenAICompatibleConfig(
            enabled=True,
            baseUrl="https://api.deepseek.com",
            apiKey="secret",
            model="deepseek-v4-flash",
        )
    )
    calls: list[int] = []
    failed_once = False

    async def fake_pipeline(**kwargs):
        nonlocal failed_once
        page_number = int(kwargs["page_number"])
        calls.append(page_number)
        if page_number == 2 and not failed_once:
            failed_once = True
            raise RuntimeError("temporary translation failure")
        translation = f"translation-{page_number}"
        return (
            PNG_1X1,
            translation,
            MangaTranslatedPagePayload(
                page_number=page_number,
                target_language=str(kwargs["target_language"]),
                source_image_file=str(kwargs["source_image_file"]),
                translated_image_file=str(kwargs["translated_image_file"]),
                page_translation=translation,
                regions=[
                    MangaTranslatedRegion(
                        order=1,
                        source_text=f"source-{page_number}",
                        translation=translation,
                    )
                ],
            ),
        )

    monkeypatch.setattr(scraper, "_translate_manga_page_with_pipeline", fake_pipeline)
    first_progress: list[int] = []
    with pytest.raises(RuntimeError, match="temporary translation failure"):
        await scraper._translate_manga_pages_with_command_detailed(
            settings=settings,
            target_language="中文",
            chapter_index=1,
            title="chapter",
            image_files=image_files,
            book_dir=tmp_path,
            checkpoint_path=checkpoint_path,
            progress_callback=lambda completed, _: first_progress.append(completed),
        )

    assert calls == [1, 2]
    assert first_progress == [1]
    assert checkpoint_path.exists()
    partial_pages = scraper.load_manga_translation_page_payloads(
        tmp_path,
        "chapter.txt",
    )
    assert [page.page_number for page in partial_pages] == [1]
    assert partial_pages[0].regions[0].source_text == "source-1"

    logs: list[str] = []
    resumed_progress: list[int] = []
    (
        page_translations,
        translated_files,
        translated_pages,
    ) = await scraper._translate_manga_pages_with_command_detailed(
        settings=settings,
        target_language="中文",
        chapter_index=1,
        title="chapter",
        image_files=image_files,
        book_dir=tmp_path,
        checkpoint_path=checkpoint_path,
        log_callback=lambda _, message: logs.append(message),
        progress_callback=lambda completed, _: resumed_progress.append(completed),
    )

    assert calls == [1, 2, 2]
    assert resumed_progress == [1, 2]
    assert page_translations == ["translation-1", "translation-2"]
    assert translated_files == [
        "images/page-1.translated.png",
        "images/page-2.translated.png",
    ]
    assert [page.page_number for page in translated_pages] == [1, 2]
    assert any("断点恢复" in message for message in logs)
    completed_pages = scraper.load_manga_translation_page_payloads(
        tmp_path,
        "chapter.txt",
    )
    assert [page.page_translation for page in completed_pages] == [
        "translation-1",
        "translation-2",
    ]


@pytest.mark.asyncio
async def test_openai_vision_ocr_retries_a_valid_but_empty_result(monkeypatch, tmp_path) -> None:
    image_path = tmp_path / "page.png"
    image = Image.new("RGB", (640, 960), "white")
    draw = ImageDraw.Draw(image)
    draw.text((28, 38), "HELLO", font=scraper._load_local_render_font(42, bold=True), fill="black")
    image.save(image_path)
    attempts = 0

    async def fake_post(*_: object, **__: object) -> dict[str, object]:
        nonlocal attempts
        attempts += 1
        regions: list[dict[str, object]] = []
        if attempts == 2:
            regions.append(
                {
                    "order": 1,
                    "bbox": [20, 30, 180, 120],
                    "source_text": "HELLO",
                    "direction": "horizontal",
                }
            )
        return {
            "choices": [
                {
                    "message": {
                        "content": '{"regions":' + scraper.json.dumps(regions, ensure_ascii=False) + "}"
                    }
                }
            ]
        }

    monkeypatch.setattr(scraper, "_post_translation_json", fake_post)

    payload = await scraper._request_openai_vision_ocr_regions_payload(
        base_url="https://gateway.example.test/v1",
        api_key="secret",
        model="vision-model",
        image_path=image_path,
        image_size=(640, 960),
        timeout_seconds=30,
        page_number=1,
    )

    assert attempts == 2
    assert len(payload.regions) == 1
    assert payload.diagnostics["vision_attempt_count"] == 2


def test_manga_text_cleanup_inpaints_textured_background_without_flat_patch() -> None:
    image = Image.new("RGBA", (220, 100), (235, 235, 235, 255))
    draw = ImageDraw.Draw(image)
    for current_x in range(0, image.width, 8):
        shade = 195 if (current_x // 8) % 2 else 235
        draw.rectangle((current_x, 0, current_x + 7, image.height), fill=(shade, shade, shade, 255))
    font = scraper._load_local_render_font(26, bold=True)
    draw.text((36, 32), "TEXT", font=font, fill=(170, 24, 36, 255))
    text_bbox = draw.textbbox((36, 32), "TEXT", font=font)
    style = scraper._estimate_manga_text_style(
        image,
        text_bbox,
        (235, 235, 235),
        preferred_color="#AA1824",
        direction="horizontal",
    )

    erased_pixels, method = scraper._erase_manga_source_text(
        image,
        text_bbox,
        style,
        (235, 235, 235),
    )

    assert erased_pixels > 0
    assert method == "inpaint"
    assert image.getpixel((4, 50))[:3] == (235, 235, 235)
    repaired_colors = {
        pixel[:3]
        for pixel in image.crop(text_bbox).get_flattened_data()
        if abs(pixel[0] - pixel[1]) <= 2 and abs(pixel[1] - pixel[2]) <= 2
    }
    assert len(repaired_colors) >= 2
    assert not any(
        pixel[0] >= 130 and pixel[0] >= pixel[1] * 2 and pixel[0] >= pixel[2] * 2
        for pixel in image.crop(text_bbox).get_flattened_data()
    )


@pytest.mark.asyncio
async def test_bika_api_retries_retryable_http_status(monkeypatch) -> None:
    attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            return httpx.Response(503, request=request)
        return httpx.Response(200, json={"code": 200, "data": {}}, request=request)

    async def no_sleep(_: float) -> None:
        return None

    monkeypatch.setattr(scraper.asyncio, "sleep", no_sleep)
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        payload = await scraper._bika_request_with_retry(client, "comics/example", max_retries=3)

    assert payload["code"] == 200
    assert attempts == 2


@pytest.mark.asyncio
async def test_multi_user_bika_never_auto_registers_or_persists_credentials(monkeypatch) -> None:
    settings = TranslationSettings()

    async def unexpected_registration(*_: object) -> tuple[str, str]:
        raise AssertionError("多用户请求不得自动注册全局 Bika 账号")

    monkeypatch.setattr(scraper, "multi_user_enabled", lambda: True)
    monkeypatch.setattr(scraper, "_register_bika_account", unexpected_registration)
    async with httpx.AsyncClient() as client:
        with pytest.raises(ValueError, match="请管理员先在模型设置中填写"):
            await scraper._ensure_bika_credentials(client, settings)

    assert settings.bika.email == ""
    assert settings.bika.password == ""


@pytest.mark.asyncio
async def test_supported_manga_failure_is_propagated(monkeypatch) -> None:
    async def fail(*_: object) -> scraper.ChapterFetchResult:
        raise ValueError("JM 图片接口暂时不可用")

    monkeypatch.setattr(scraper, "_fetch_18comic_chapter_data", fail)
    async with httpx.AsyncClient() as client:
        with pytest.raises(ValueError, match="JM 图片接口暂时不可用"):
            await scraper._fetch_chapter_data(
                client,
                "https://18comic.vip/photo/123456/",
                "测试章节",
            )


def test_mainstream_manga_sources_are_detected() -> None:
    supported_urls = (
        "https://18comic.vip/album/123456/",
        "https://bikawebapp.com/comic/abcdef123456",
        "https://www.pixiv.net/artworks/12345678",
        "https://comic.pixiv.net/works/10790",
        "https://comic.pixiv.net/viewer/stories/177714",
        "https://www.webtoons.com/zh-hant/fantasy/example/viewer?title_no=1&episode_no=2",
        "https://www.mangabz.com/m12345/",
        "https://www.manhuagui.com/comic/12345/67890.html",
        "https://www.copymanga.site/comic/example/chapter/1",
        "https://manhua.dmzj.com/example/123.shtml",
    )

    assert all(scraper._is_manga_source_url(url) for url in supported_urls)


def test_jm_chapter_uses_current_api_image_urls(monkeypatch) -> None:
    class FakePhoto(list[object]):
        title = "JM 测试章节"

    class FakeImage:
        download_url = "https://cdn.example.test/media/photos/123456/001.jpg"

    class FakeClient:
        def get_photo_detail(self, photo_id: str) -> FakePhoto:
            assert photo_id == "123456"
            return FakePhoto([FakeImage()])

    monkeypatch.setattr(scraper, "_jm_client", lambda: FakeClient())

    result = scraper._sync_fetch_18comic_chapter_data("https://18comic.vip/photo/123456/")

    assert result.image_urls == ["https://cdn.example.test/media/photos/123456/001.jpg"]
    assert "共 1 页" in result.text


@pytest.mark.asyncio
async def test_pixiv_manga_fetches_original_pages() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/ajax/illust/12345678/pages"
        return httpx.Response(
            200,
            json={
                "error": False,
                "body": [
                    {
                        "urls": {
                            "regular": "https://i.pximg.net/regular-1.jpg",
                            "original": "https://i.pximg.net/1.jpg",
                        }
                    },
                    {"urls": {"regular": "https://i.pximg.net/2.jpg"}},
                ],
            },
            request=request,
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await scraper._fetch_pixiv_manga_data(
            client,
            "https://www.pixiv.net/artworks/12345678",
            "Pixiv 测试漫画",
        )

    assert result.image_urls == ["https://i.pximg.net/1.jpg", "https://i.pximg.net/2.jpg"]
    assert "共 2 页" in result.text


def test_pixiv_comic_work_payload_builds_readable_chapters_in_reading_order() -> None:
    work_payload = {
        "data": {
            "official_work": {
                "id": 10790,
                "name": "ステラ・ステップ",
                "author": "漫画：りんご水,原作：林星悟",
                "description": "第一行<br>第二行",
                "image": {
                    "main": "https://public-img-comic.pximg.net/small.jpg",
                    "main_big": "https://public-img-comic.pximg.net/original.jpg",
                },
            }
        }
    }
    episodes_payload = {
        "data": {
            "episodes": [
                {
                    "state": "readable",
                    "episode": {
                        "id": 181852,
                        "numbering_title": "Step.1①",
                        "sub_title": "砂漠に降る雨",
                        "viewer_path": "/viewer/stories/181852",
                        "state": "readable",
                    },
                },
                {
                    "state": "locked",
                    "episode": {
                        "id": 180000,
                        "numbering_title": "Step.0.5",
                        "sub_title": "访问标记章节",
                        "viewer_path": "/viewer/stories/180000",
                        "state": "locked",
                    },
                },
                {"state": "not_publishing", "message": "掲載期間が終了しました"},
                {
                    "state": "readable",
                    "episode": {
                        "id": 177714,
                        "numbering_title": "Step.0",
                        "sub_title": "星が堕ちた日",
                        "viewer_path": "/viewer/stories/177714",
                        "state": "readable",
                    },
                },
            ]
        }
    }

    preview = scraper._pixiv_comic_preview_from_payloads(
        work_payload,
        episodes_payload,
        "https://comic.pixiv.net/works/10790",
    )

    assert preview.title == "ステラ・ステップ"
    assert preview.author == "漫画：りんご水,原作：林星悟"
    assert preview.synopsis == "第一行\n第二行"
    assert preview.cover == "https://public-img-comic.pximg.net/original.jpg"
    assert preview.bookKind == "漫画"
    assert [chapter.title for chapter in preview.chapters] == [
        "Step.0 星が堕ちた日",
        "Step.0.5 访问标记章节",
        "Step.1① 砂漠に降る雨",
    ]
    assert [chapter.url for chapter in preview.chapters] == [
        "https://comic.pixiv.net/viewer/stories/177714",
        "https://comic.pixiv.net/viewer/stories/180000",
        "https://comic.pixiv.net/viewer/stories/181852",
    ]
    assert [chapter.accessRestricted for chapter in preview.chapters] == [False, True, False]


@pytest.mark.asyncio
async def test_pixiv_comic_story_uses_signed_read_api_and_registers_page_keys() -> None:
    viewer_url = "https://comic.pixiv.net/viewer/stories/177714"
    image_url = "https://img-comic.pximg.net/c/q90_gridshuffle32:32/images/page/177714/1.jpg"
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.url.path == "/viewer/stories/177714":
            return httpx.Response(
                200,
                text=(
                    '<script id="__NEXT_DATA__" type="application/json">'
                    '{"props":{"pageProps":{"salt":"test-salt","id":"177714"}}}'
                    "</script>"
                ),
                request=request,
            )
        assert request.url.path == "/api/app/episodes/177714/read_v4"
        assert request.headers["X-Client-Time"]
        assert len(request.headers["X-Client-Hash"]) == 64
        return httpx.Response(
            200,
            json={
                "data": {
                    "reading_episode": {
                        "title": "Step.0 星が堕ちた日",
                        "is_displayable": False,
                        "pages": [
                            {
                                "url": image_url,
                                "height": 1024,
                                "width": 720,
                                "gridsize": 32,
                                "key": "page-key",
                            }
                        ],
                    }
                }
            },
            request=request,
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await scraper._fetch_pixiv_comic_chapter_data(client, viewer_url, "")

    assert len(requests) == 2
    assert result.image_urls == [image_url]
    assert result.access_restricted is True
    assert "共 1 页" in result.text
    assert scraper._PIXIV_COMIC_PAGE_KEYS[image_url] == ("page-key", 32)


def test_pixiv_comic_descrambles_grid_pages_without_changing_resolution() -> None:
    image = Image.new("RGB", (64, 32), "blue")
    ImageDraw.Draw(image).rectangle((32, 0, 63, 31), fill="red")
    source = BytesIO()
    image.save(source, format="PNG")

    restored = scraper._pixiv_comic_descramble_bytes(
        source.getvalue(),
        "38c0777c-a5fd-4031-b9eb-e7bb4cc96e67",
        32,
    )

    with Image.open(BytesIO(restored)) as result:
        assert result.size == (64, 32)
        assert result.getpixel((8, 8))[:3] == (255, 0, 0)
        assert result.getpixel((48, 8))[:3] == (0, 0, 255)


def test_generic_manga_html_extracts_lazy_and_script_images() -> None:
    html = """
    <div id="_imageList">
      <img data-url="//cdn.example.test/pages/001.webp">
      <img data-src="/pages/002.jpg">
    </div>
    <script>
      const chapterPath = "/pages/";
      const chapterImages = ["003.png", "004.png"];
    </script>
    """

    assert scraper._extract_generic_manga_image_urls(
        html,
        "https://www.webtoons.com/reader/chapter-1",
    ) == [
        "https://cdn.example.test/pages/001.webp",
        "https://www.webtoons.com/pages/002.jpg",
        "https://www.webtoons.com/pages/003.png",
        "https://www.webtoons.com/pages/004.png",
    ]


@pytest.mark.asyncio
async def test_generic_manga_chapter_returns_image_pages_without_browser() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            text='<div class="reader-main"><img data-original="/chapter/001.jpg"></div>',
            request=request,
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await scraper._fetch_generic_manga_chapter_data(
            client,
            "https://www.mangabz.com/m12345/",
            "第一话",
        )

    assert result.image_urls == ["https://www.mangabz.com/chapter/001.jpg"]
    assert "共 1 页" in result.text


@pytest.mark.asyncio
async def test_retry_requeues_the_same_task(monkeypatch, tmp_path) -> None:
    monkeypatch.setenv("QINGJUAN_DATA_DIR", str(tmp_path))
    main = importlib.import_module("app.main")
    task = TaskRecord(
        id="task-original",
        bookId="book-1",
        taskType="download",
        chapterIndexes=[1, 2],
        status="failed",
        totalCount=2,
        completedCount=1,
        progress=50,
        message="任务执行失败",
        error="图片下载失败",
        attempts=1,
        createdAt="2026-08-03 10:00:00",
        updatedAt="2026-08-03 10:01:00",
    )
    saved: list[TaskRecord] = []
    queue: asyncio.Queue[str] = asyncio.Queue()

    monkeypatch.setattr(main, "get_task", lambda _, __: task)
    monkeypatch.setattr(main, "_get_book_or_404", lambda _, __: object())
    monkeypatch.setattr(
        main,
        "require_user_access",
        lambda _: SimpleNamespace(owner_id="user-admin"),
    )
    monkeypatch.setattr(main, "save_task", lambda value: saved.append(value.model_copy(deep=True)))
    monkeypatch.setattr(main, "TASK_QUEUE", queue)
    monkeypatch.setattr(
        main,
        "_enqueue_task",
        lambda *_: pytest.fail("重试不应创建新的任务记录"),
    )

    retried = await main.post_retry_task(task.id, object())  # type: ignore[arg-type]

    assert retried.id == "task-original"
    assert retried.status == "queued"
    assert retried.completedCount == 0
    assert retried.progress == 0
    assert retried.error is None
    assert saved[-1].id == "task-original"
    assert queue.get_nowait() == "task-original"
