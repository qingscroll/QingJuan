from __future__ import annotations

from io import BytesIO

import pytest
from PIL import Image, ImageDraw, ImageFilter

from app import manga_workflow, scraper
from app.models import MangaTranslatedPagePayload, MangaTranslatedRegion


def _bubble_fixture(shape: str) -> tuple[Image.Image, Image.Image, list[tuple[int, int]]]:
    """Return original art, the true bubble interior, and source-only ink pixels.

    The annotation deliberately includes more than the bubble.  It models the
    loose OCR rectangles seen around connected/irregular speech balloons, not
    a perfect hand-authored ellipse that would hide cleanup regressions.
    """
    image = Image.new("RGB", (320, 260), (226, 226, 226))
    draw = ImageDraw.Draw(image)
    for y in range(0, image.height, 6):
        draw.line((0, y, image.width, y), fill=(232, 232, 232))

    silhouette = Image.new("L", image.size, 0)
    silhouette_draw = ImageDraw.Draw(silhouette)
    if shape == "concave":
        polygon = [
            (98, 28),
            (208, 28),
            (249, 63),
            (249, 100),
            (205, 120),
            (245, 150),
            (240, 201),
            (211, 229),
            (96, 229),
            (67, 200),
            (53, 140),
            (65, 75),
        ]
        silhouette_draw.polygon(polygon, fill=255)
        draw.polygon(polygon, fill="white", outline="black", width=4)
    else:
        bubble = (52, 28, 254, 232)
        silhouette_draw.ellipse(bubble, fill=255)
        draw.ellipse(bubble, fill="white", outline="black", width=4)
        if shape == "open":
            # A genuine opening must not let cleanup grow into the page art.
            draw.rectangle((248, 113, 257, 132), fill=(226, 226, 226))

    # An adjacent panel border and a connected character/hair contour lie inside
    # the inaccurate OCR box but are never part of the source text.
    draw.line((270, 8, 270, 250), fill="black", width=4)
    draw.line([(287, 250), (281, 202), (261, 191), (252, 165)], fill="black", width=4)
    interior = silhouette.filter(ImageFilter.MinFilter(11))

    source_ink: list[tuple[int, int]] = []
    for x in (113, 132, 151):
        for block in ((x, 70, x + 3, 89), (x + 8, 70, x + 11, 89), (x, 78, x + 11, 81)):
            draw.rectangle(block, fill="black")
            source_ink.extend(
                (px, py) for py in range(block[1], block[3] + 1) for px in range(block[0], block[2] + 1)
            )
    return image, interior, source_ink


def _loose_region(*, tight_body: bool = False) -> MangaTranslatedRegion:
    bbox = (70, 45, 284, 222)
    return MangaTranslatedRegion(
        order=1,
        bbox=bbox,
        body_bbox=bbox if tight_body else (44, 20, 291, 240),
        safe_box=bbox,
        source_text="原文テキスト",
        source_direction="horizontal",
        direction="horizontal",
        translation="译文",
        background="#ffffff",
        text_color="#000000",
    )


def _assert_artwork_preserved(before: Image.Image, after: Image.Image, interior: Image.Image) -> None:
    changed_outside = sum(
        source != result
        for source, result, allowed in zip(
            before.get_flattened_data(),
            after.get_flattened_data(),
            interior.get_flattened_data(),
            strict=True,
        )
        if allowed == 0
    )
    assert changed_outside == 0, f"cleanup/redrawing changed {changed_outside} original artwork pixels"


@pytest.mark.parametrize("shape", ["ellipse", "concave", "open"])
@pytest.mark.parametrize("tight_body", [False, True], ids=["loose-container", "ocr-box-only"])
def test_inpainting_preserves_real_bubble_outline_and_adjacent_artwork(tmp_path, shape, tight_body) -> None:
    original, interior, source_ink = _bubble_fixture(shape)
    source = tmp_path / "original.png"
    original.save(source)

    output_bytes, diagnostics = manga_workflow._inpaint_regions(
        source, [_loose_region(tight_body=tight_body)]
    )
    with Image.open(BytesIO(output_bytes)) as output:
        cleaned = output.convert("RGB")

    # Requiring erasure as well as preservation prevents a no-op/skip from
    # satisfying the regression.  These glyphs are well inside the balloon.
    assert diagnostics["inpaintedRegionCount"] == 1
    assert all(min(cleaned.getpixel(point)) >= 245 for point in source_ink)
    _assert_artwork_preserved(original, cleaned, interior)


@pytest.mark.parametrize("shape", ["ellipse", "concave", "open"])
@pytest.mark.parametrize("tight_body", [False, True], ids=["loose-container", "ocr-box-only"])
def test_translated_text_and_cleanup_stay_inside_original_bubble(tmp_path, shape, tight_body) -> None:
    original, interior, source_ink = _bubble_fixture(shape)
    source = tmp_path / "original.png"
    original.save(source)
    payload = MangaTranslatedPagePayload(
        page_number=1,
        image_size=original.size,
        target_language="Chinese",
        regions=[_loose_region(tight_body=tight_body)],
    )

    output_bytes, translated_text, diagnostics = scraper._render_translated_manga_page_to_image(
        source, payload
    )
    with Image.open(BytesIO(output_bytes)) as output:
        translated = output.convert("RGB")

    assert translated_text == "译文"
    assert diagnostics["rendered_region_count"] == 1
    assert diagnostics["source_text_erased_region_count"] == 1
    assert all(min(translated.getpixel(point)) >= 245 for point in source_ink)
    assert any(
        before == (255, 255, 255) and min(after) < 128
        for before, after, allowed in zip(
            original.get_flattened_data(),
            translated.get_flattened_data(),
            interior.get_flattened_data(),
            strict=True,
        )
        if allowed
    ), "translation must actually be drawn in the bubble"
    _assert_artwork_preserved(original, translated, interior)


@pytest.mark.parametrize("shape", ["concave", "open"])
def test_bubble_mask_without_optional_numeric_libraries_matches_accelerated_mask(monkeypatch, shape) -> None:
    if scraper.cv2 is None or scraper.np is None:
        pytest.skip("accelerated implementation is unavailable for comparison")
    original, _, _ = _bubble_fixture(shape)
    body = _loose_region().body_bbox
    expected = scraper._extract_precise_bubble_mask(original, body, (255, 255, 255), "ellipse")

    monkeypatch.setattr(scraper, "cv2", None)
    monkeypatch.setattr(scraper, "np", None)
    fallback = scraper._extract_precise_bubble_mask(original, body, (255, 255, 255), "ellipse")

    assert fallback.getbbox() is not None
    assert fallback.size == expected.size
    assert fallback.tobytes() == expected.tobytes()


@pytest.mark.parametrize("shape", ["concave", "open"])
@pytest.mark.parametrize("mode", ["inpaint", "render"])
def test_bubble_cleanup_without_optional_numeric_libraries_preserves_artwork(
    tmp_path, monkeypatch, shape, mode
) -> None:
    monkeypatch.setattr(scraper, "cv2", None)
    monkeypatch.setattr(scraper, "np", None)
    original, interior, source_ink = _bubble_fixture(shape)
    source = tmp_path / "original.png"
    original.save(source)
    region = _loose_region(tight_body=True)

    if mode == "inpaint":
        output_bytes, diagnostics = manga_workflow._inpaint_regions(source, [region])
        assert diagnostics["inpaintedRegionCount"] == 1
    else:
        output_bytes, _, diagnostics = scraper._render_translated_manga_page_to_image(
            source, MangaTranslatedPagePayload(image_size=original.size, regions=[region])
        )
        assert diagnostics["rendered_region_count"] == 1
    with Image.open(BytesIO(output_bytes)) as output:
        result = output.convert("RGB")

    assert all(min(result.getpixel(point)) >= 245 for point in source_ink)
    _assert_artwork_preserved(original, result, interior)


@pytest.mark.parametrize("mode", ["inpaint", "render"])
def test_pure_halftone_is_not_replaced_with_a_white_text_rectangle(tmp_path, mode) -> None:
    original = Image.new("RGB", (240, 192), "white")
    draw = ImageDraw.Draw(original)
    for y in range(0, original.height, 4):
        for x in range(0, original.width, 4):
            draw.rectangle((x, y, x + 1, y + 1), fill="black")
    source = tmp_path / "halftone.png"
    original.save(source)
    region = MangaTranslatedRegion(
        order=1,
        bbox=(12, 12, 228, 180),
        source_text="誤検出された原文",
        direction="horizontal",
        translation="人工补译",
        background="#ffffff",
    )

    if mode == "inpaint":
        output_bytes, _ = manga_workflow._inpaint_regions(source, [region])
    else:
        output_bytes, _, _ = scraper._render_translated_manga_page_to_image(
            source, MangaTranslatedPagePayload(image_size=original.size, regions=[region])
        )
    with Image.open(BytesIO(output_bytes)) as output:
        result = output.convert("RGB")

    # Conservative skipping is valid here.  There is no real bubble or source
    # text: a regular screen tone must not become a collection of glyph holes.
    for y in range(12, 180, 12):
        for x in range(12, 228, 12):
            tile = (x, y, x + 12, y + 12)
            original_dark = sum(min(pixel) < 128 for pixel in original.crop(tile).get_flattened_data())
            remaining_dark = sum(min(pixel) < 128 for pixel in result.crop(tile).get_flattened_data())
            assert remaining_dark >= original_dark * 0.75, f"screen tone erased in tile {tile}"
    outside = Image.new("L", original.size, 0)
    ImageDraw.Draw(outside).rectangle((12, 12, 227, 179), fill=255)
    _assert_artwork_preserved(original, result, outside)


@pytest.mark.parametrize("mode", ["inpaint", "render"])
def test_overlapping_regions_measure_original_artwork_after_previous_region_changes(
    tmp_path, monkeypatch, mode
) -> None:
    original, _, _ = _bubble_fixture("concave")
    source = tmp_path / "original.png"
    original.save(source)
    original_pixels = original.tobytes()
    measurements: dict[str, int] = {}

    def track_measurement(name, implementation):
        def measured(image, *args, **kwargs):
            measurements[name] = measurements.get(name, 0) + 1
            assert image.convert("RGB").tobytes() == original_pixels, (
                f"{name} sampled a previously erased/redrawn page instead of original artwork"
            )
            return implementation(image, *args, **kwargs)

        return measured

    for name in ("_sample_region_fill_color", "_estimate_manga_text_style", "_extract_precise_bubble_mask"):
        monkeypatch.setattr(scraper, name, track_measurement(name, getattr(scraper, name)))
    regions = [_loose_region(), _loose_region().model_copy(update={"order": 2, "translation": "补译"})]

    if mode == "inpaint":
        output_bytes, _ = manga_workflow._inpaint_regions(source, regions)
    else:
        output_bytes, _, _ = scraper._render_translated_manga_page_to_image(
            source, MangaTranslatedPagePayload(image_size=original.size, regions=regions)
        )

    assert len(measurements) == 3
    assert all(count == 2 for count in measurements.values())
    with Image.open(BytesIO(output_bytes)) as output:
        assert output.convert("RGB").tobytes() != original_pixels


@pytest.mark.parametrize(
    ("background_rows", "permitted_ink_pixels", "unsafe"),
    [
        (30, 100, False),  # Small genuine bubble still contains all source ink.
        (60, 48, False),  # Loose OCR box includes artwork around a genuine bubble.
        (39, 69, True),  # Both background and source-ink evidence are insufficient.
        (39, 70, False),  # The source-ink threshold is inclusive.
        (40, 20, False),  # The body-coverage threshold is inclusive.
        (0, 0, True),  # There is no measured bubble at all.
    ],
)
def test_sparse_bubble_safety_requires_both_background_and_ink_evidence_to_fail(
    background_rows, permitted_ink_pixels, unsafe
) -> None:
    # Offset text/body coordinates exercise the real coordinate conversion; the
    # 100 source pixels make the coverage boundary independent of font rendering.
    body_bbox = (40, 30, 140, 130)
    text_bbox = (60, 40, 120, 130)
    bubble_mask = Image.new("L", (100, 100), 0)
    if background_rows:
        ImageDraw.Draw(bubble_mask).rectangle((0, 0, 99, background_rows - 1), fill=255)
    ink_mask = Image.new("L", (60, 90), 0)
    for index in range(permitted_ink_pixels):
        ink_mask.putpixel((index % 10, index // 10), 255)
    for index in range(100 - permitted_ink_pixels):
        ink_mask.putpixel((index % 10, 70 + index // 10), 255)

    assert scraper._manga_bubble_mask_is_unsafe(ink_mask, text_bbox, body_bbox, bubble_mask) is unsafe


@pytest.mark.parametrize("mode", ["inpaint", "render"])
@pytest.mark.parametrize("mask_kind", ["sparse", "empty"])
def test_unreliable_bubble_measurement_preserves_mixed_artwork_and_reports_skip(
    tmp_path, monkeypatch, mode, mask_kind
) -> None:
    original = Image.new("RGB", (180, 160), "white")
    draw = ImageDraw.Draw(original)
    # Mixed page art: a white patch adjacent to screentone with disconnected
    # dark markings on both.  A partial white component is not a whole balloon.
    for y in range(0, original.height, 5):
        for x in range(92, original.width, 5):
            draw.rectangle((x, y, x + 1, y + 1), fill="black")
    for x in (48, 110):
        draw.rectangle((x, 52, x + 3, 82), fill="black")
        draw.rectangle((x + 10, 52, x + 13, 82), fill="black")
        draw.rectangle((x, 66, x + 13, 69), fill="black")
    source = tmp_path / "mixed-artwork.png"
    original.save(source)
    region = MangaTranslatedRegion(
        order=1,
        bbox=(30, 30, 150, 130),
        body_bbox=(20, 20, 160, 140),
        source_text="原文テキスト",
        translation="人工补译",
        direction="horizontal",
        background="#ffffff",
    )
    measured_mask = Image.new("L", (140, 120), 0)
    if mask_kind == "sparse":
        ImageDraw.Draw(measured_mask).rectangle((10, 10, 59, 89), fill=255)
    measured = 0

    def controlled_measurement(image, bbox, fill_color, fill_shape):
        nonlocal measured
        measured += 1
        assert image.convert("RGB").tobytes() == original.tobytes()
        assert bbox == region.body_bbox
        return measured_mask.copy()

    monkeypatch.setattr(scraper, "_extract_precise_bubble_mask", controlled_measurement)
    if mode == "inpaint":
        output_bytes, diagnostics = manga_workflow._inpaint_regions(source, [region])
        assert diagnostics["skippedUnsafeInpaintRegionCount"] == 1
        assert diagnostics["inpaintedRegionCount"] == 0
        assert diagnostics["inpaintedPixelCount"] == 0
    else:
        output_bytes, _, diagnostics = scraper._render_translated_manga_page_to_image(
            source, MangaTranslatedPagePayload(image_size=original.size, regions=[region])
        )
        assert diagnostics["skipped_unsafe_cleanup_region_count"] == 1
        assert diagnostics["rendered_region_count"] == 0
        assert diagnostics["source_text_erased_region_count"] == 0
    assert measured == 1, "the test must reach bubble safety instead of an earlier skip guard"
    with Image.open(BytesIO(output_bytes)) as output:
        assert output.convert("RGB").tobytes() == original.tobytes()
