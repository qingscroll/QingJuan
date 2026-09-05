"""Render saved manga projects locally and capture the actual cleanup masks.

Example (run with the backend virtualenv Python):
    python tool/qa_manga_bubble_redraw.py --source-dir CHAPTER --output-dir QA

No OCR, translation provider, database, or HTTP endpoint is invoked. Source
images/projects are read-only; all generated artifacts stay in --output-dir.
Use --backend-dir to compare an isolated previous backend with current code.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime
from io import BytesIO
from pathlib import Path
from typing import Any

from PIL import Image, ImageChops, ImageDraw, ImageOps

ROOT = Path(__file__).resolve().parents[1]


def _page_stems(values: list[str]) -> list[str]:
    stems: list[str] = []
    for value in values:
        for token in value.split(","):
            token = token.strip()
            stem = f"page-{int(token):04d}" if token.isdigit() else Path(token).stem
            if not stem.startswith("page-") or not stem[5:].isdigit():
                raise ValueError(f"Invalid page identifier: {token!r}")
            if stem not in stems:
                stems.append(stem)
    return stems


def _difference_mask(first: Image.Image, second: Image.Image) -> Image.Image:
    difference = ImageChops.difference(first.convert("RGB"), second.convert("RGB"))
    channels = difference.split()
    return ImageChops.lighter(
        ImageChops.lighter(channels[0], channels[1]), channels[2]
    ).point(lambda value: 255 if value else 0)


def _sheet(
    panels: list[tuple[str, Image.Image]], destination: Path, *, width: int = 400
) -> None:
    prepared: list[tuple[str, Image.Image]] = []
    for label, image in panels:
        thumbnail = ImageOps.contain(image.convert("RGB"), (width, width * 2))
        prepared.append((label, thumbnail))
    height = max(image.height for _, image in prepared) + 32
    sheet = Image.new("RGB", (width * len(prepared), height), "#e9e9e9")
    draw = ImageDraw.Draw(sheet)
    for index, (label, image) in enumerate(prepared):
        left = index * width
        draw.text((left + 8, 8), label, fill="black")
        sheet.paste(image, (left + (width - image.width) // 2, 30))
    sheet.save(destination)


class MaskRecorder:
    """Observe production helper return values without replacing their behavior."""

    def __init__(self, scraper: Any, regions: list[Any], output: Path) -> None:
        self.scraper = scraper
        self.output = output
        self.current = "unassigned"
        self.stage = "render"
        self.by_bbox = {
            tuple(region.bbox): region.order for region in regions if region.bbox
        }
        self.events: list[dict[str, Any]] = []
        self.counts: dict[tuple[str, str, str], int] = {}
        self.mask_panels: dict[str, list[tuple[str, Image.Image]]] = {}

    def mask(self, label: str, mask: Any) -> None:
        if not isinstance(mask, Image.Image):
            return
        mask = mask.convert("L")
        key = (self.stage, self.current, label)
        number = self.counts.get(key, 0) + 1
        self.counts[key] = number
        filename = f"{self.stage}-{self.current}-{label}-{number:02d}.png"
        mask.save(self.output / filename)
        histogram = mask.histogram()
        self.events.append(
            {
                "stage": self.stage,
                "region": self.current,
                "kind": label,
                "file": filename,
                "size": list(mask.size),
                "bounds": mask.getbbox(),
                "nonzeroPixels": sum(histogram[1:]),
                "coverage": round(
                    sum(histogram[1:]) / max(1, mask.width * mask.height), 6
                ),
            }
        )
        if self.stage == "render" and number == 1:
            self.mask_panels.setdefault(self.current, []).append((label, mask.copy()))

    @contextmanager
    def capture(self) -> Iterator[None]:
        originals: dict[str, Any] = {}

        def install(name: str, wrapper: Any) -> None:
            if hasattr(self.scraper, name):
                originals[name] = getattr(self.scraper, name)
                setattr(self.scraper, name, wrapper(originals[name]))

        def estimate(original: Any) -> Any:
            def call(*args: Any, **kwargs: Any) -> Any:
                bbox = kwargs.get("text_bbox", args[1] if len(args) > 1 else None)
                order = self.by_bbox.get(tuple(bbox)) if bbox else None
                self.current = (
                    f"region-{order:02d}" if order is not None else "unassigned"
                )
                result = original(*args, **kwargs)
                self.mask("ink", result.ink_mask)
                return result

            return call

        def mask_result(label: str, *, tuple_result: bool = False) -> Any:
            def wrap(original: Any) -> Any:
                def call(*args: Any, **kwargs: Any) -> Any:
                    result = original(*args, **kwargs)
                    self.mask(label, result[0] if tuple_result else result)
                    return result

                return call

            return wrap

        def erase(original: Any) -> Any:
            def call(*args: Any, **kwargs: Any) -> Any:
                canvas = kwargs.get("canvas", args[0] if args else None)
                bbox = kwargs.get("text_bbox", args[1] if len(args) > 1 else None)
                before = canvas.crop(bbox)
                self.mask("erase-limit", kwargs.get("limit_mask"))
                result = original(*args, **kwargs)
                self.mask("actual-erased", _difference_mask(before, canvas.crop(bbox)))
                return result

            return call

        install("_estimate_manga_text_style", estimate)
        install("_extract_precise_bubble_mask", mask_result("bubble-outline"))
        install("_build_region_fill_area_mask", mask_result("bubble-fill"))
        install(
            "_resolve_manga_cleanup_limit_mask",
            mask_result("cleanup-limit", tuple_result=True),
        )
        install("_build_region_safe_text_mask", mask_result("safe-text"))
        install("_erase_manga_source_text", erase)
        try:
            yield
        finally:
            for name, original in originals.items():
                setattr(self.scraper, name, original)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--backend-dir", type=Path, default=ROOT / "python-backend")
    parser.add_argument(
        "--pages",
        nargs="+",
        default=["4", "5"],
        help="Page numbers or stems, space/comma separated",
    )
    args = parser.parse_args()
    source_dir = args.source_dir.expanduser().resolve(strict=True)
    output_dir = args.output_dir.expanduser().resolve()
    backend_dir = args.backend_dir.expanduser().resolve(strict=True)
    if (
        output_dir == source_dir
        or source_dir in output_dir.parents
        or output_dir in source_dir.parents
    ):
        parser.error("--output-dir must be separate from the source chapter directory")
    if not (backend_dir / "app" / "manga_workflow.py").is_file():
        parser.error("--backend-dir must contain app/manga_workflow.py")
    try:
        stems = _page_stems(args.pages)
    except ValueError as error:
        parser.error(str(error))
    output_dir.mkdir(parents=True, exist_ok=True)
    os.environ["QINGJUAN_DATA_DIR"] = str(output_dir / "isolated-runtime-data")
    sys.path.insert(0, str(backend_dir))
    from app import manga_workflow, scraper
    from app.models import MangaTranslatedPagePayload

    report: dict[str, Any] = {
        "createdAt": datetime.now(UTC).isoformat(),
        "backendDir": str(backend_dir),
        "backendSha256": {
            name: hashlib.sha256((backend_dir / "app" / name).read_bytes()).hexdigest()
            for name in ("scraper.py", "manga_workflow.py")
        },
        "externalServicesUsed": False,
        "sourceFilesModified": False,
        "pages": [],
    }
    for stem in stems:
        source_path = source_dir / f"{stem}.jpg"
        project_path = (
            source_dir / "manga_translator_work" / "json" / f"{stem}_translations.json"
        )
        with Image.open(source_path) as image:
            original = image.convert("RGB")
        project = manga_workflow.parse_manga_project(
            json.loads(project_path.read_text(encoding="utf-8-sig")),
            default_image_key=str(source_path),
            image_size=original.size,
        )
        page_dir = output_dir / stem
        mask_dir = page_dir / "masks"
        mask_dir.mkdir(parents=True, exist_ok=True)
        recorder = MaskRecorder(scraper, project.regions, mask_dir)
        payload = MangaTranslatedPagePayload(
            page_number=int(stem[5:]),
            image_size=original.size,
            target_language="中文",
            regions=project.regions,
        )
        with recorder.capture():
            rendered_bytes, _, render_diagnostics = (
                scraper._render_translated_manga_page_to_image(source_path, payload)
            )
            recorder.stage = "inpaint"
            inpainted_bytes, inpaint_diagnostics = manga_workflow._inpaint_regions(
                source_path, project.regions
            )
        (page_dir / "redrawn.png").write_bytes(rendered_bytes)
        (page_dir / "inpainted.png").write_bytes(inpainted_bytes)
        with Image.open(BytesIO(rendered_bytes)) as image:
            rendered = image.convert("RGB")
        with Image.open(BytesIO(inpainted_bytes)) as image:
            inpainted = image.convert("RGB")
        panels = [("Original", original)]
        existing_path = source_dir / "manga_translator_work" / "result" / f"{stem}.png"
        if existing_path.is_file():
            with Image.open(existing_path) as image:
                panels.append(("Existing result", image.convert("RGB")))
        panels.extend([("Redrawn", rendered), ("Inpainted", inpainted)])
        _sheet(panels, page_dir / "comparison.png")
        changed_mask = _difference_mask(original, rendered)
        changed_mask.save(page_dir / "changed-pixels.png")
        tint = Image.new("RGB", original.size, "#ff2b74")
        Image.composite(Image.blend(original, tint, 0.65), original, changed_mask).save(
            page_dir / "changes-overlay.png"
        )
        for region in project.regions:
            key = f"region-{region.order:02d}"
            bbox = region.body_bbox or region.bbox
            if bbox:
                _sheet(
                    [
                        ("Original", original.crop(bbox)),
                        ("Redrawn", rendered.crop(bbox)),
                        ("Inpainted", inpainted.crop(bbox)),
                    ],
                    page_dir / f"{key}-comparison.png",
                    width=320,
                )
            if key in recorder.mask_panels:
                _sheet(
                    recorder.mask_panels[key],
                    mask_dir / f"{key}-overview.png",
                    width=220,
                )
        page_report = {
            "page": stem,
            "imageSize": original.size,
            "sourceSha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
            "projectSha256": hashlib.sha256(project_path.read_bytes()).hexdigest(),
            "render": render_diagnostics,
            "inpaint": inpaint_diagnostics,
            "regions": [
                {
                    "order": region.order,
                    "bbox": region.bbox,
                    "body_bbox": region.body_bbox,
                    "safe_box": region.safe_box,
                }
                for region in project.regions
            ],
            "masks": recorder.events,
        }
        (page_dir / "diagnostics.json").write_text(
            json.dumps(page_report, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        report["pages"].append(page_report)
        print(
            f"{stem}: saved redraw, inpaint, comparisons and {len(recorder.events)} masks",
            flush=True,
        )
    (output_dir / "diagnostics.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"QA artifacts: {output_dir}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
