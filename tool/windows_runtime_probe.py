"""Appended to the isolated smoke-test plugin; runs inside the frozen backend.

Never shipped as an application module. Exercises native dependencies whose
packaging can regress when removing unused files or changing bundle layout.
"""
import asyncio
import json
import sys
from io import BytesIO
from pathlib import Path


def _probe_windows_runtime():
    import certifi
    import cv2
    import numpy as np
    import pypdfium2 as pdfium
    from Crypto.Cipher import AES
    from PIL import Image, ImageDraw, ImageFont

    assert getattr(sys, "frozen", False), "Runtime probe must execute in the packaged backend"
    assert Path(cv2.__file__).resolve().is_relative_to(Path(sys._MEIPASS).resolve())
    assert Path(certifi.where()).read_text().find("BEGIN CERTIFICATE") >= 0
    assert not list(Path(sys._MEIPASS).rglob("opencv_videoio_ffmpeg*.dll"))
    assert not (Path(sys._MEIPASS) / "_tcl_data").exists()

    image = Image.new("RGB", (480, 100), "white")
    ImageDraw.Draw(image).text((20, 20), "QINGJUAN 123", font=ImageFont.truetype("arial.ttf", 44), fill="black")
    for format_name in ("PNG", "JPEG", "GIF", "BMP", "TIFF", "WEBP", "AVIF"):
        encoded = BytesIO()
        image.save(encoded, format=format_name)
        encoded.seek(0)
        with Image.open(encoded) as decoded:
            decoded.load()
            assert decoded.size == image.size, format_name

    pdf_bytes = BytesIO()
    image.save(pdf_bytes, format="PDF")
    with pdfium.PdfDocument(pdf_bytes.getvalue()) as pdf:
        page = pdf[0]
        bitmap = page.render(scale=1)
        assert bitmap.to_pil().size == image.size
        bitmap.close()
        page.close()

    key, plaintext = b"0123456789abcdef", b"packaged-runtime"
    encrypted = AES.new(key, AES.MODE_ECB).encrypt(plaintext)
    assert AES.new(key, AES.MODE_ECB).decrypt(encrypted) == plaintext
    gray = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2GRAY)
    assert cv2.dilate(gray, np.ones((3, 3), dtype=np.uint8)).shape == (100, 480)

    # Exercise the application's real OCR path and its bundled default models.
    from app.scraper import _run_rapid_ocr_sync
    import rapidocr

    assert len(list((Path(rapidocr.__file__).parent / "models").glob("*.onnx"))) >= 2
    from tempfile import TemporaryDirectory

    with TemporaryDirectory(prefix="qingjuan-runtime-probe-") as directory:
        image_path = Path(directory) / "sample.png"
        image.save(image_path)
        result = _run_rapid_ocr_sync(image_path)
    recognized = " ".join(result.txts or []).upper()
    assert "123" in recognized, f"Bundled OCR did not recognize fixture text: {recognized}"
    return ["image-codecs", "pdf", "aes", "opencv", "offline-ocr", "https-certificates"]


_original_smoke_search = search  # noqa: F821 -- defined by the preceding demo plugin


async def search(keyword, limit, context):
    try:
        checks = await asyncio.to_thread(_probe_windows_runtime)
        report = {"ok": True, "checks": checks}
    except Exception as error:
        report = {"ok": False, "error": f"{type(error).__name__}: {error}"}
    results = await _original_smoke_search(keyword, limit, context)
    for item in results:
        item["synopsis"] = json.dumps(report)
    return results
