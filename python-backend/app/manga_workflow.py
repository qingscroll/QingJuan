from __future__ import annotations

import asyncio
import base64
import json
import time
import unicodedata
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any, cast

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageOps

from . import scraper
from .models import (
    MangaOcrRegion,
    MangaTranslatedPagePayload,
    MangaTranslatedRegion,
    MangaWorkflowMode,
    MangaWorkflowResponse,
    TranslationSettings,
)

WORKFLOW_MODES: frozenset[str] = frozenset(
    {
        "normal",
        "export_translation",
        "export_original",
        "translate_json_only",
        "import_translation_render",
        "colorize_only",
        "upscale_only",
        "inpaint_only",
        "replace_translation",
    }
)
REPLACEMENT_MIN_OVERLAP = 0.3


@dataclass(frozen=True)
class ParsedProject:
    image_key: str
    page: dict[str, Any]
    raw_regions: list[dict[str, Any]]
    regions: list[MangaTranslatedRegion]
    input_format: str


def _parse_json_input(value: str | dict[str, Any] | list[Any] | None, label: str) -> Any:
    if value is None or value == "":
        return None
    if not isinstance(value, str):
        return value
    try:
        return json.loads(value)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{label}不是有效 JSON：{exc.msg}") from exc


def _project_page_from_document(
    value: Any,
    *,
    default_image_key: str,
) -> tuple[str, dict[str, Any], str]:
    if isinstance(value, list):
        return default_image_key, {"regions": value}, "regions_list"
    if not isinstance(value, dict):
        raise ValueError("工程数据必须是 JSON 对象或 regions 数组")
    if isinstance(value.get("regions"), list):
        return default_image_key, dict(value), "page"

    preferred_keys = (
        default_image_key,
        Path(default_image_key).name,
        Path(default_image_key).stem,
    )
    for key in preferred_keys:
        page_value = value.get(key)
        if isinstance(page_value, list):
            return str(key), {"regions": page_value}, "upstream_document_legacy"
        if isinstance(page_value, dict) and isinstance(page_value.get("regions"), list):
            return str(key), dict(page_value), "upstream_document"

    for key, page_value in value.items():
        if isinstance(page_value, list):
            return str(key), {"regions": page_value}, "upstream_document_legacy"
        if isinstance(page_value, dict) and isinstance(page_value.get("regions"), list):
            return str(key), dict(page_value), "upstream_document"
    raise ValueError("工程数据中未找到 regions 数组")


def _flatten_line_points(value: Any) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []

    def visit(item: Any) -> None:
        if not isinstance(item, (list, tuple)):
            return
        if len(item) == 2 and isinstance(item[0], (int, float)) and isinstance(item[1], (int, float)):
            points.append((float(item[0]), float(item[1])))
            return
        for child in item:
            visit(child)

    visit(value)
    return points


def _bbox_from_lines(value: Any, image_size: tuple[int, int]) -> tuple[int, int, int, int] | None:
    points = _flatten_line_points(value)
    if not points:
        return None
    xs = [point[0] for point in points]
    ys = [point[1] for point in points]
    return scraper._normalize_region_bbox(
        [min(xs), min(ys), max(xs), max(ys)],
        image_size,
    )


def _normalize_direction(value: Any) -> str | None:
    normalized = str(value or "").strip().lower()
    if normalized in {"v", "vr", "vertical"} or normalized.startswith("vertical"):
        return "vertical"
    if normalized in {"h", "hr", "horizontal"} or normalized.startswith("horizontal"):
        return "horizontal"
    return None


def _target_language_code(value: str) -> str:
    normalized = str(value or "").strip()
    return {
        "中文": "CHS",
        "简体中文": "CHS",
        "英文": "ENG",
        "英语": "ENG",
        "日文": "JPN",
        "日语": "JPN",
    }.get(normalized, normalized)


def _source_text(raw_region: dict[str, Any]) -> str:
    direct = str(raw_region.get("source_text") or raw_region.get("text") or "").strip()
    if direct:
        return direct.replace("[BR]", "\n")
    texts = raw_region.get("texts")
    if isinstance(texts, list):
        return "\n".join(str(item).strip() for item in texts if str(item).strip()).replace("[BR]", "\n")
    return ""


def _translation_text(raw_region: dict[str, Any]) -> str:
    value = raw_region.get("translation")
    if value is None or value == "":
        value = raw_region.get("translation_raw")
    return str(value or "").strip().replace("[BR]", "\n")


def _rgb_hex(value: Any) -> str | None:
    if isinstance(value, str):
        stripped = value.strip()
        return stripped if stripped.startswith("#") and len(stripped) == 7 else None
    if isinstance(value, (list, tuple)) and value and isinstance(value[0], (list, tuple)):
        value = value[0]
    if isinstance(value, (list, tuple)) and len(value) >= 3:
        try:
            channels = tuple(max(0, min(255, int(round(float(item))))) for item in value[:3])
        except (TypeError, ValueError):
            return None
        return "#{:02X}{:02X}{:02X}".format(*channels)
    return None


def _region_bbox(raw_region: dict[str, Any], image_size: tuple[int, int]) -> tuple[int, int, int, int] | None:
    bbox = scraper._normalize_region_bbox(raw_region.get("bbox"), image_size)
    if bbox is not None:
        return bbox
    bbox = _bbox_from_lines(raw_region.get("lines"), image_size)
    if bbox is not None:
        return bbox
    center = raw_region.get("center")
    if isinstance(center, (list, tuple)) and len(center) >= 2:
        try:
            center_x, center_y = float(center[0]), float(center[1])
            font_size = max(8.0, float(raw_region.get("font_size") or 24))
        except (TypeError, ValueError):
            return None
        return scraper._normalize_region_bbox(
            [
                center_x - font_size,
                center_y - font_size,
                center_x + font_size,
                center_y + font_size,
            ],
            image_size,
        )
    return None


def _region_from_project(
    raw_region: dict[str, Any],
    *,
    image_size: tuple[int, int],
    fallback_order: int,
) -> MangaTranslatedRegion:
    bbox = _region_bbox(raw_region, image_size)
    body_bbox = scraper._normalize_region_bbox(raw_region.get("body_bbox"), image_size) or bbox
    safe_box = scraper._normalize_region_bbox(raw_region.get("safe_box"), image_size) or body_bbox
    direction = _normalize_direction(raw_region.get("direction"))
    source_direction = _normalize_direction(raw_region.get("source_direction")) or direction
    try:
        order = max(1, int(raw_region.get("order") or fallback_order))
    except (TypeError, ValueError):
        order = fallback_order
    raw_shape = raw_region.get("shape")
    shape = (
        raw_shape if isinstance(raw_shape, str) and raw_shape in {"ellipse", "roundrect", "rect"} else None
    )
    try:
        padding_ratio = (
            float(raw_region["padding_ratio"]) if raw_region.get("padding_ratio") is not None else None
        )
    except (TypeError, ValueError):
        padding_ratio = None
    return MangaTranslatedRegion(
        order=order,
        bbox=bbox,
        body_bbox=body_bbox,
        safe_box=safe_box,
        source_text=_source_text(raw_region),
        source_direction=cast(Any, source_direction),
        direction=cast(Any, direction or source_direction),
        background=str(raw_region.get("background") or "").strip() or None,
        text_color=(
            str(raw_region.get("text_color") or raw_region.get("font_color") or "").strip()
            or _rgb_hex(raw_region.get("fg_colors"))
        ),
        shape=cast(Any, shape),
        padding_ratio=padding_ratio,
        translation=_translation_text(raw_region),
    )


def parse_manga_project(
    value: str | dict[str, Any] | list[Any],
    *,
    default_image_key: str,
    image_size: tuple[int, int],
    label: str = "工程数据",
) -> ParsedProject:
    parsed = _parse_json_input(value, label)
    image_key, page, input_format = _project_page_from_document(
        parsed,
        default_image_key=default_image_key,
    )
    try:
        declared_size = (
            max(1, int(page.get("original_width") or image_size[0])),
            max(1, int(page.get("original_height") or image_size[1])),
        )
    except (TypeError, ValueError):
        declared_size = image_size
    raw_regions = [dict(item) for item in page.get("regions", []) if isinstance(item, dict)]
    regions = [
        _region_from_project(item, image_size=declared_size, fallback_order=index)
        for index, item in enumerate(raw_regions, start=1)
    ]
    regions.sort(key=lambda item: item.order)
    regions = [region.model_copy(update={"order": index}) for index, region in enumerate(regions, 1)]
    return ParsedProject(
        image_key=image_key,
        page=page,
        raw_regions=raw_regions,
        regions=regions,
        input_format=input_format,
    )


def _as_translated_regions(regions: list[MangaOcrRegion]) -> list[MangaTranslatedRegion]:
    translated: list[MangaTranslatedRegion] = []
    for region in regions:
        region_data = region.model_dump()
        translation = str(region_data.pop("translation", "") or "")
        translated.append(MangaTranslatedRegion(**region_data, translation=translation))
    return translated


def _color_list(value: str | None, default: list[int]) -> list[int]:
    if isinstance(value, str) and value.startswith("#") and len(value) == 7:
        try:
            return [int(value[index : index + 2], 16) for index in (1, 3, 5)]
        except ValueError:
            pass
    return list(default)


def _project_region(
    region: MangaTranslatedRegion,
    raw_region: dict[str, Any] | None,
    *,
    target_language: str,
) -> dict[str, Any]:
    raw = dict(raw_region or {})
    bbox = region.bbox or region.body_bbox or region.safe_box
    if bbox is not None:
        x1, y1, x2, y2 = bbox
        default_lines: list[list[list[float]]] = [
            [
                [float(x1), float(y1)],
                [float(x2), float(y1)],
                [float(x2), float(y2)],
                [float(x1), float(y2)],
            ]
        ]
        center = [round((x1 + x2) / 2, 3), round((y1 + y2) / 2, 3)]
        estimated_font_size = max(8, min(128, int(round((y2 - y1) * 0.72))))
    else:
        default_lines = []
        center = [0.0, 0.0]
        estimated_font_size = 24
    source = region.source_text.strip()
    translation = region.translation.strip()
    raw_texts = raw.get("texts")
    texts = (
        [str(item) for item in raw_texts]
        if isinstance(raw_texts, list) and raw_texts
        else ([source] if source else [])
    )
    raw_translation = str(raw.get("translation") or "").strip()
    translation_changed = translation != raw_translation
    project_region: dict[str, Any] = dict(raw)
    project_region.update(
        {
            "order": region.order,
            "bbox": list(bbox) if bbox is not None else None,
            "body_bbox": list(region.body_bbox) if region.body_bbox is not None else None,
            "safe_box": list(region.safe_box) if region.safe_box is not None else None,
            "lines": raw.get("lines") if isinstance(raw.get("lines"), list) else default_lines,
            "center": raw.get("center") if isinstance(raw.get("center"), list) else center,
            "texts": texts,
            "text": source,
            "source_direction": region.source_direction,
            "translation": translation,
            "translation_raw": (
                translation if translation_changed else str(raw.get("translation_raw") or translation).strip()
            ),
            "angle": raw.get("angle", 0),
            "font_size": raw.get("font_size") or estimated_font_size,
            "fg_colors": raw.get("fg_colors")
            if isinstance(raw.get("fg_colors"), list)
            else _color_list(region.text_color, [0, 0, 0]),
            "bg_colors": raw.get("bg_colors") if isinstance(raw.get("bg_colors"), list) else [255, 255, 255],
            "direction": "v" if str(region.direction or region.source_direction or "") == "vertical" else "h",
            "alignment": raw.get("alignment") or "center",
            "target_lang": raw.get("target_lang") or target_language,
            "source_lang": raw.get("source_lang") or "",
            "line_spacing": raw.get("line_spacing", 1.0),
            "letter_spacing": raw.get("letter_spacing", 1.0),
            "stroke_width": raw.get("stroke_width", 0.2),
            "prob": raw.get("prob", 1.0),
            "font_family": raw.get("font_family") or "",
        }
    )
    optional_geometry = {
        "background": region.background,
        "text_color": region.text_color,
        "shape": region.shape,
        "padding_ratio": region.padding_ratio,
    }
    project_region.update({key: value for key, value in optional_geometry.items() if value is not None})
    project_region = {key: value for key, value in project_region.items() if value is not None}
    for optional_key in (
        "translation_rich",
        "render_box_rect_local",
        "layout_mode",
        "opacity",
        "shadow_radius",
        "shadow_strength",
        "shadow_color",
        "shadow_offset",
    ):
        if optional_key in raw:
            project_region[optional_key] = raw[optional_key]
    return project_region


def _mask_raw_base64(
    regions: list[MangaTranslatedRegion],
    image_size: tuple[int, int],
) -> str:
    mask = Image.new("L", image_size, 0)
    draw = ImageDraw.Draw(mask)
    for region in regions:
        bbox = scraper._normalize_region_bbox(
            region.body_bbox or region.bbox or region.safe_box,
            image_size,
        )
        if bbox is not None:
            draw.rectangle(bbox, fill=255)
    if mask.getbbox() is None:
        return ""
    output = BytesIO()
    mask.save(output, format="PNG")
    return base64.b64encode(output.getvalue()).decode("ascii")


def _build_project_page(
    parsed_project: ParsedProject | None,
    regions: list[MangaTranslatedRegion],
    *,
    image_size: tuple[int, int],
    target_language: str,
    mode: MangaWorkflowMode,
) -> dict[str, Any]:
    page = dict(parsed_project.page) if parsed_project is not None else {}
    raw_by_order = (
        {index: raw_region for index, raw_region in enumerate(parsed_project.raw_regions, start=1)}
        if parsed_project is not None
        else {}
    )
    page["regions"] = [
        _project_region(
            region,
            raw_by_order.get(region.order),
            target_language=_target_language_code(target_language),
        )
        for region in regions
    ]
    page["original_width"] = image_size[0]
    page["original_height"] = image_size[1]
    page["skip_font_scaling"] = mode not in {"export_original", "translate_json_only"}
    generated_mask = _mask_raw_base64(regions, image_size)
    if generated_mask:
        page.setdefault("mask_raw", generated_mask)
        page.setdefault("mask_is_refined", False)
    if mode in {"normal", "import_translation_render", "replace_translation"}:
        page["skip_text_replacements"] = True
    return page


def _text_sidecars(
    regions: list[MangaTranslatedRegion],
) -> tuple[dict[str, str], dict[str, str]]:
    original: dict[str, str] = {}
    translated: dict[str, str] = {}
    for region in regions:
        source = region.source_text.strip()
        if not source:
            continue
        translation = region.translation.strip()
        original[source] = translation or source
        translated[source] = translation
    return original, translated


def _normalized_text(value: Any) -> str:
    return "".join(
        character
        for character in unicodedata.normalize("NFKC", str(value or "")).casefold()
        if not character.isspace()
    )


def _sidecar_mapping(value: Any) -> dict[str, str]:
    if not isinstance(value, dict):
        return {}
    if isinstance(value.get("translated"), dict):
        value = value["translated"]
    return {str(key): str(item) for key, item in value.items() if isinstance(item, (str, int, float))}


def _apply_sidecar_mapping(
    regions: list[MangaTranslatedRegion],
    mapping: dict[str, str],
) -> tuple[list[MangaTranslatedRegion], int]:
    normalized_mapping = {_normalized_text(key): value for key, value in mapping.items()}
    updated: list[MangaTranslatedRegion] = []
    match_count = 0
    for region in regions:
        translation = mapping.get(region.source_text)
        if translation is None:
            translation = normalized_mapping.get(_normalized_text(region.source_text))
        if translation is None:
            translation = mapping.get(str(region.order))
        if translation is None:
            updated.append(region)
            continue
        updated.append(region.model_copy(update={"translation": str(translation).strip()}))
        match_count += 1
    return updated, match_count


def _small_box_overlap(
    first: tuple[int, int, int, int],
    second: tuple[int, int, int, int],
) -> float:
    left = max(first[0], second[0])
    top = max(first[1], second[1])
    right = min(first[2], second[2])
    bottom = min(first[3], second[3])
    intersection = max(0, right - left) * max(0, bottom - top)
    first_area = max(1, first[2] - first[0]) * max(1, first[3] - first[1])
    second_area = max(1, second[2] - second[0]) * max(1, second[3] - second[1])
    return intersection / max(1, min(first_area, second_area))


def _scaled_bbox(
    bbox: tuple[int, int, int, int],
    *,
    source_size: tuple[int, int],
    target_size: tuple[int, int],
) -> tuple[int, int, int, int]:
    scale_x = target_size[0] / max(1, source_size[0])
    scale_y = target_size[1] / max(1, source_size[1])
    return (
        int(round(bbox[0] * scale_x)),
        int(round(bbox[1] * scale_y)),
        int(round(bbox[2] * scale_x)),
        int(round(bbox[3] * scale_y)),
    )


def match_replacement_regions(
    source_regions: list[MangaTranslatedRegion],
    replacement_regions: list[MangaTranslatedRegion],
    *,
    source_size: tuple[int, int],
    replacement_size: tuple[int, int],
) -> tuple[list[MangaTranslatedRegion], dict[str, Any]]:
    available = set(range(len(replacement_regions)))
    resolved: list[MangaTranslatedRegion] = []
    overlaps: list[float] = []
    for source_region in source_regions:
        source_bbox = source_region.bbox or source_region.body_bbox
        best_index: int | None = None
        best_overlap = 0.0
        if source_bbox is not None:
            for candidate_index in available:
                candidate = replacement_regions[candidate_index]
                candidate_bbox = candidate.bbox or candidate.body_bbox
                if candidate_bbox is None:
                    continue
                scaled = _scaled_bbox(
                    candidate_bbox,
                    source_size=replacement_size,
                    target_size=source_size,
                )
                score = _small_box_overlap(source_bbox, scaled)
                if score > best_overlap:
                    best_overlap = score
                    best_index = candidate_index
        if best_index is None or best_overlap < REPLACEMENT_MIN_OVERLAP:
            resolved.append(source_region)
            continue
        candidate = replacement_regions[best_index]
        translation = candidate.translation.strip() or candidate.source_text.strip()
        if not translation:
            resolved.append(source_region)
            continue
        available.remove(best_index)
        resolved.append(source_region.model_copy(update={"translation": translation}))
        overlaps.append(best_overlap)
    return resolved, {
        "matchedRegionCount": len(overlaps),
        "unmatchedRegionCount": max(0, len(source_regions) - len(overlaps)),
        "matchMetric": "intersection_over_smaller_box",
        "minimumRequiredOverlap": REPLACEMENT_MIN_OVERLAP,
        "averageMatchOverlap": (round(sum(overlaps) / len(overlaps), 4) if overlaps else 0.0),
        "minimumMatchOverlap": round(min(overlaps), 4) if overlaps else 0.0,
    }


def _encode_png(image: Image.Image) -> bytes:
    output = BytesIO()
    image.save(output, format="PNG")
    return output.getvalue()


def _colorize_image(image_path: Path) -> tuple[bytes, dict[str, Any]]:
    with Image.open(image_path) as source:
        rgb = source.convert("RGB")
    red, green, blue = rgb.split()
    is_grayscale = (
        ImageChops.difference(red, green).getbbox() is None
        and ImageChops.difference(red, blue).getbbox() is None
    )
    if is_grayscale:
        gray = ImageOps.grayscale(rgb)
        result = ImageOps.colorize(gray, black=(20, 28, 52), white=(255, 244, 218))
        algorithm = "duotone"
    else:
        result = ImageEnhance.Color(rgb).enhance(1.2)
        result = ImageEnhance.Contrast(result).enhance(1.03)
        algorithm = "saturation_enhance"
    return _encode_png(result), {"colorizeAlgorithm": algorithm, "outputSize": list(result.size)}


def _upscale_image(image_path: Path, factor: int) -> tuple[bytes, dict[str, Any]]:
    if factor < 1 or factor > 4:
        raise ValueError("upscaleFactor 必须在 1 到 4 之间")
    with Image.open(image_path) as source:
        converted = source.convert("RGBA") if source.mode in {"RGBA", "LA", "P"} else source.convert("RGB")
        output_size = (converted.width * factor, converted.height * factor)
        result = converted.resize(output_size, Image.Resampling.LANCZOS)
    return _encode_png(result), {
        "upscaleAlgorithm": "lanczos",
        "upscaleFactor": factor,
        "outputSize": list(output_size),
    }


def _inpaint_regions(
    image_path: Path,
    regions: list[MangaTranslatedRegion],
) -> tuple[bytes, dict[str, Any]]:
    with Image.open(image_path) as source:
        canvas = source.convert("RGBA")
    original = canvas.copy()
    erased_pixels = 0
    inpainted_count = 0
    unsafe_count = 0
    for region in regions:
        bbox = scraper._normalize_region_bbox(region.bbox, canvas.size)
        if bbox is None:
            continue
        body_bbox = scraper._normalize_region_bbox(region.body_bbox or bbox, canvas.size) or bbox
        fill_color = scraper._sample_region_fill_color(
            original,
            body_bbox,
            region.background,
            body_bbox=body_bbox,
        )
        style = scraper._estimate_manga_text_style(
            original,
            bbox,
            fill_color,
            preferred_color=region.text_color,
            direction=str(region.source_direction or region.direction or "horizontal"),
        )
        if scraper._manga_ink_mask_is_unsafe(style.ink_mask):
            unsafe_count += 1
            continue
        direction = str(region.source_direction or region.direction or "horizontal")
        fill_shape = scraper._resolve_region_fill_shape(
            region.model_dump(exclude_none=True),
            body_bbox,
            direction,
        )
        bubble_mask = scraper._extract_precise_bubble_mask(original, body_bbox, fill_color, fill_shape)
        if scraper._manga_bubble_mask_is_unsafe(style.ink_mask, bbox, body_bbox, bubble_mask):
            unsafe_count += 1
            continue
        region_erased, _ = scraper._erase_manga_source_text(
            canvas,
            bbox,
            style,
            fill_color,
            limit_bbox=body_bbox,
            limit_mask=bubble_mask,
        )
        if region_erased:
            erased_pixels += region_erased
            inpainted_count += 1
    return _encode_png(canvas), {
        "inpaintedRegionCount": inpainted_count,
        "inpaintedPixelCount": erased_pixels,
        "skippedUnsafeInpaintRegionCount": unsafe_count,
    }


def _optional_provider_config(
    settings: TranslationSettings,
    *,
    required: bool,
) -> tuple[str, str, str]:
    try:
        return scraper._resolve_manga_image_provider_config(settings)
    except ValueError:
        if required:
            raise
        model_config = settings.translationModel
        return (
            str(model_config.baseUrl or "").strip().rstrip("/"),
            str(model_config.apiKey or "").strip(),
            str(model_config.model or "").strip(),
        )


async def _ocr_regions(
    *,
    settings: TranslationSettings,
    image_path: Path,
    page_number: int,
) -> tuple[list[MangaTranslatedRegion], dict[str, Any]]:
    base_url, api_key, model = _optional_provider_config(settings, required=False)
    payload = await scraper._request_manga_ocr_regions_payload(
        settings=settings,
        base_url=base_url,
        api_key=api_key,
        model=model,
        image_path=image_path,
        timeout_seconds=scraper.BUILTIN_MANGA_IMAGE_TIMEOUT_SECONDS,
        page_number=page_number,
    )
    return _as_translated_regions(payload.regions), dict(payload.diagnostics or {})


async def _translate_regions(
    *,
    settings: TranslationSettings,
    regions: list[MangaTranslatedRegion],
    target_language: str,
    title: str,
) -> tuple[list[MangaTranslatedRegion], dict[str, Any]]:
    base_url, api_key, model = _optional_provider_config(settings, required=True)
    translated = await scraper._translate_manga_region_batch(
        settings=settings,
        base_url=base_url,
        api_key=api_key,
        model=model,
        target_language=target_language,
        chapter_title=title,
        chapter_index=1,
        page_number=1,
        total_pages=1,
        regions=regions,
        timeout_seconds=scraper.BUILTIN_MANGA_IMAGE_TIMEOUT_SECONDS,
    )
    return translated, {
        "translationModel": model,
        "translatedRegionCount": sum(1 for region in translated if region.translation.strip()),
    }


async def _render_regions(
    *,
    image_path: Path,
    image_size: tuple[int, int],
    regions: list[MangaTranslatedRegion],
    target_language: str,
    diagnostics: dict[str, Any],
) -> tuple[bytes, str, dict[str, Any]]:
    page_translation = "\n".join(
        region.translation.strip() for region in regions if region.translation.strip()
    )
    payload = MangaTranslatedPagePayload(
        page_number=1,
        image_size=image_size,
        target_language=target_language,
        render_mode="ocr_pipeline",
        source_image_file=image_path.name,
        page_translation=page_translation,
        regions=regions,
        diagnostics=diagnostics,
    )
    output, rendered_text, render_diagnostics = await asyncio.to_thread(
        scraper._render_translated_manga_page_to_image,
        image_path,
        payload,
    )
    return scraper._ensure_png_image_bytes(output), rendered_text, render_diagnostics


async def run_manga_workflow(
    *,
    image_bytes: bytes,
    original_name: str,
    mode: str,
    target_language: str,
    settings: TranslationSettings,
    title: str = "",
    project: str | dict[str, Any] | list[Any] | None = None,
    companion: str | dict[str, Any] | list[Any] | None = None,
    translated_image_bytes: bytes | None = None,
    translated_image_name: str = "translated.png",
    upscale_factor: int = 2,
) -> MangaWorkflowResponse:
    if mode not in WORKFLOW_MODES:
        raise ValueError(f"不支持的漫画工作流模式：{mode}")
    if not image_bytes:
        raise ValueError("漫画图片文件为空")
    resolved_mode = cast(MangaWorkflowMode, mode)
    safe_name = Path(original_name or "upload.png").name or "upload.png"
    started_at = time.perf_counter()

    with TemporaryDirectory(prefix="qingjuan-manga-workflow-") as temporary_directory:
        source_path = Path(temporary_directory) / safe_name
        source_path.write_bytes(image_bytes)
        try:
            with Image.open(source_path) as source_image:
                image_size = source_image.size
                source_image.verify()
        except Exception as exc:
            raise ValueError("上传图片无法解码：文件可能损坏或当前环境未安装该格式解码器") from exc

        parsed_project = (
            parse_manga_project(
                project,
                default_image_key=safe_name,
                image_size=image_size,
            )
            if project is not None and project != ""
            else None
        )
        image_key = parsed_project.image_key if parsed_project is not None else safe_name
        companion_value = _parse_json_input(companion, "伴随数据")
        diagnostics: dict[str, Any] = {
            "mode": mode,
            "inputSize": list(image_size),
            "inputProjectFormat": parsed_project.input_format if parsed_project is not None else "none",
        }
        regions = list(parsed_project.regions) if parsed_project is not None else []
        output_bytes: bytes | None = None
        inpainted_bytes: bytes | None = None
        page_translation = ""

        async def ensure_source_regions() -> list[MangaTranslatedRegion]:
            nonlocal regions
            if regions:
                return regions
            regions, ocr_diagnostics = await _ocr_regions(
                settings=settings,
                image_path=source_path,
                page_number=1,
            )
            diagnostics.update(ocr_diagnostics)
            return regions

        if resolved_mode == "colorize_only":
            output_bytes, mode_diagnostics = await asyncio.to_thread(_colorize_image, source_path)
            diagnostics.update(mode_diagnostics)
        elif resolved_mode == "upscale_only":
            output_bytes, mode_diagnostics = await asyncio.to_thread(
                _upscale_image,
                source_path,
                upscale_factor,
            )
            diagnostics.update(mode_diagnostics)
        elif resolved_mode == "export_original":
            await ensure_source_regions()
        elif resolved_mode == "translate_json_only":
            if parsed_project is None:
                raise ValueError("仅翻译（JSON）模式需要 project 工程数据")
            regions, mode_diagnostics = await _translate_regions(
                settings=settings,
                regions=regions,
                target_language=target_language,
                title=title or Path(safe_name).stem,
            )
            diagnostics.update(mode_diagnostics)
        elif resolved_mode == "import_translation_render":
            if parsed_project is None:
                raise ValueError("导入翻译并渲染模式需要 project 工程数据")
            companion_mapping = _sidecar_mapping(companion_value)
            if companion_mapping:
                regions, matched = _apply_sidecar_mapping(regions, companion_mapping)
                diagnostics["companionMatchedRegionCount"] = matched
            if not any(region.translation.strip() for region in regions):
                raise ValueError("工程数据中没有可渲染的译文")
            inpainted_bytes, inpaint_diagnostics = await asyncio.to_thread(
                _inpaint_regions,
                source_path,
                regions,
            )
            diagnostics.update(inpaint_diagnostics)
            output_bytes, page_translation, render_diagnostics = await _render_regions(
                image_path=source_path,
                image_size=image_size,
                regions=regions,
                target_language=target_language,
                diagnostics=diagnostics,
            )
            diagnostics.update(render_diagnostics)
        elif resolved_mode == "inpaint_only":
            await ensure_source_regions()
            inpainted_bytes, mode_diagnostics = await asyncio.to_thread(
                _inpaint_regions,
                source_path,
                regions,
            )
            output_bytes = inpainted_bytes
            diagnostics.update(mode_diagnostics)
        elif resolved_mode == "replace_translation":
            await ensure_source_regions()
            if companion_value is None and not translated_image_bytes:
                raise ValueError("替换翻译模式需要 translatedFile 配对译图")
            replacement_regions: list[MangaTranslatedRegion] = []
            replacement_size = image_size
            replacement_project: ParsedProject | None = None
            companion_matched = 0
            if companion_value is not None:
                try:
                    replacement_project = parse_manga_project(
                        companion_value,
                        default_image_key=translated_image_name,
                        image_size=image_size,
                        label="替换翻译工程数据",
                    )
                except ValueError:
                    companion_mapping = _sidecar_mapping(companion_value)
                    regions, companion_matched = _apply_sidecar_mapping(
                        regions,
                        companion_mapping,
                    )
                    diagnostics["companionMatchedRegionCount"] = companion_matched
                else:
                    replacement_regions = replacement_project.regions
                    try:
                        replacement_size = (
                            int(replacement_project.page.get("original_width") or image_size[0]),
                            int(replacement_project.page.get("original_height") or image_size[1]),
                        )
                    except (TypeError, ValueError):
                        replacement_size = image_size
            if not replacement_regions and translated_image_bytes:
                replacement_path = (
                    Path(temporary_directory) / f"translated-{Path(translated_image_name).name}"
                )
                replacement_path.write_bytes(translated_image_bytes)
                try:
                    with Image.open(replacement_path) as replacement_image:
                        replacement_size = replacement_image.size
                except Exception as exc:
                    raise ValueError("translatedFile 不是有效图片") from exc
                replacement_regions, replacement_ocr_diagnostics = await _ocr_regions(
                    settings=settings,
                    image_path=replacement_path,
                    page_number=1,
                )
                diagnostics["replacementOcr"] = replacement_ocr_diagnostics
            if replacement_regions:
                regions, match_diagnostics = match_replacement_regions(
                    regions,
                    replacement_regions,
                    source_size=image_size,
                    replacement_size=replacement_size,
                )
                diagnostics.update(match_diagnostics)
            elif companion_matched == 0:
                raise ValueError("替换翻译模式未从配对译图或伴随数据中识别到文字区域")
            if not any(region.translation.strip() for region in regions):
                raise ValueError("替换翻译模式未找到可匹配的译文区域")
            inpainted_bytes, inpaint_diagnostics = await asyncio.to_thread(
                _inpaint_regions,
                source_path,
                regions,
            )
            diagnostics.update(inpaint_diagnostics)
            output_bytes, page_translation, render_diagnostics = await _render_regions(
                image_path=source_path,
                image_size=image_size,
                regions=regions,
                target_language=target_language,
                diagnostics=diagnostics,
            )
            diagnostics.update(render_diagnostics)
        else:
            await ensure_source_regions()
            regions, translation_diagnostics = await _translate_regions(
                settings=settings,
                regions=regions,
                target_language=target_language,
                title=title or Path(safe_name).stem,
            )
            diagnostics.update(translation_diagnostics)
            if resolved_mode == "normal":
                inpainted_bytes, inpaint_diagnostics = await asyncio.to_thread(
                    _inpaint_regions,
                    source_path,
                    regions,
                )
                diagnostics.update(inpaint_diagnostics)
                output_bytes, page_translation, render_diagnostics = await _render_regions(
                    image_path=source_path,
                    image_size=image_size,
                    regions=regions,
                    target_language=target_language,
                    diagnostics=diagnostics,
                )
                diagnostics.update(render_diagnostics)

        if not page_translation:
            page_translation = "\n".join(
                region.translation.strip() for region in regions if region.translation.strip()
            )
        should_persist_project = resolved_mode not in {"colorize_only", "upscale_only"}
        project_page = (
            _build_project_page(
                parsed_project,
                regions,
                image_size=image_size,
                target_language=target_language,
                mode=resolved_mode,
            )
            if should_persist_project
            else {}
        )
        project_document = {image_key: project_page} if should_persist_project else {}
        original_sidecar, translated_sidecar = _text_sidecars(regions)
        diagnostics["shouldPersistProject"] = should_persist_project
        diagnostics["regionCount"] = len(regions)
        diagnostics["outputBytes"] = len(output_bytes or b"")
        diagnostics["inpaintedBytes"] = len(inpainted_bytes or b"")
        diagnostics["elapsedMs"] = round((time.perf_counter() - started_at) * 1000, 1)
        return MangaWorkflowResponse(
            mode=resolved_mode,
            imageKey=image_key,
            outputImageBase64=(base64.b64encode(output_bytes).decode("ascii") if output_bytes else None),
            inpaintedImageBase64=(
                base64.b64encode(inpainted_bytes).decode("ascii") if inpainted_bytes else None
            ),
            project=project_page,
            projectDocument=project_document,
            original=original_sidecar,
            translated=translated_sidecar,
            pageTranslation=page_translation,
            diagnostics=diagnostics,
        )
