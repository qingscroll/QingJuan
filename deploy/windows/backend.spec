# -*- mode: python ; coding: utf-8 -*-
"""Keep the backend in one directory so Inno can compress its native libraries."""
from pathlib import Path

from PyInstaller.utils.hooks import collect_all, collect_data_files, collect_submodules, copy_metadata

project_root = Path(SPECPATH).resolve().parents[1]
backend_root = project_root / "python-backend"
datas = [
    (str(backend_root / "app/windows_ocr.ps1"), "app"),
    (str(backend_root / "app/admin_static"), "admin_static"),
    (str(project_root / "pubspec.yaml"), "."),
]
binaries = []
hiddenimports = ["rapidocr", "rapidocr.inference_engine.onnxruntime", "onnxruntime", "yaml"]
datas += collect_data_files("rapidocr")  # Keep all offline recognition models.
for distribution in ("Pillow", "pycryptodome"):
    datas += copy_metadata(distribution)  # Retain version metadata and licenses.

# These packages use dynamic imports. Sources are already stored in the PYZ;
# collect their resources without also shipping duplicate .py files.
for package in ("curl_cffi", "websockets", "pypdfium2", "jmcomic", "common"):
    package_data, package_binaries, package_imports = collect_all(package, include_py_files=False)
    datas += package_data
    binaries += package_binaries
    hiddenimports += package_imports

# Keep the crypto algorithms, without bundling their development self-tests.
# PyInstaller's standard Crypto hook collects the native algorithm libraries.
hiddenimports += collect_submodules("Crypto", filter=lambda name: not name.startswith("Crypto.SelfTest"))
# The standard PIL.Image hook includes all image codecs without ImageTk/Qt.
a = Analysis(
    [str(backend_root / "app/main.py")],
    pathex=[str(backend_root)],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    excludes=[
        "tkinter", "_tkinter", "PIL.ImageTk", "PIL.ImageQt", "Crypto.SelfTest",
        "rapidocr.inference_engine.mnn", "rapidocr.inference_engine.openvino",
        "rapidocr.inference_engine.paddle", "rapidocr.inference_engine.pytorch",
        "rapidocr.inference_engine.tensorrt", "onnxruntime.quantization",
        "onnxruntime.tools", "onnxruntime.transformers", "torch",
    ],
    noarchive=False,
    optimize=0,  # Preserve assertions used by the application and plugins.
)

# OpenCV loads FFmpeg only for video I/O. QingJuan processes still images;
# keep cv2 and all image codecs, omit this unused 29 MiB video plugin.
a.binaries = [entry for entry in a.binaries
              if not Path(entry[0]).name.lower().startswith("opencv_videoio_ffmpeg")]

pyz = PYZ(a.pure)
exe = EXE(
    pyz, a.scripts, [],
    exclude_binaries=True,
    name="qingjuan-desktop",
    console=True,
    debug=False,
    strip=False,
    upx=False,
    contents_directory="_internal",
)
# Keep the executable at backend/qingjuan-desktop.exe: backend/data remains
# beside it, independent of _internal and compatible with existing installs.
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name="backend")
