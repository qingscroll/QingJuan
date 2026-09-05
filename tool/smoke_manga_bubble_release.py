"""Verify an isolated packaged Windows backend against local manga redraws.

Only the backend started by this script is contacted. Windows Job Object
ownership is checked before every HTTP request, and all owned child processes
are terminated when the job closes. Original images/projects are read-only.
"""

from __future__ import annotations

import argparse
import base64
import ctypes
import hashlib
import json
import os
import socket
import subprocess
import time
from ctypes import wintypes
from datetime import UTC, datetime
from io import BytesIO
from pathlib import Path
from typing import Any

import httpx
from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]


class _BasicLimit(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_longlong),
        ("PerJobUserTimeLimit", ctypes.c_longlong),
        ("LimitFlags", wintypes.DWORD),
        ("MinimumWorkingSetSize", ctypes.c_size_t),
        ("MaximumWorkingSetSize", ctypes.c_size_t),
        ("ActiveProcessLimit", wintypes.DWORD),
        ("Affinity", ctypes.c_size_t),
        ("PriorityClass", wintypes.DWORD),
        ("SchedulingClass", wintypes.DWORD),
    ]


class _IoCounters(ctypes.Structure):
    _fields_ = [
        (name, ctypes.c_ulonglong)
        for name in (
            "ReadOperationCount",
            "WriteOperationCount",
            "OtherOperationCount",
            "ReadTransferCount",
            "WriteTransferCount",
            "OtherTransferCount",
        )
    ]


class _ExtendedLimit(ctypes.Structure):
    _fields_ = [
        ("BasicLimitInformation", _BasicLimit),
        ("IoInfo", _IoCounters),
        ("ProcessMemoryLimit", ctypes.c_size_t),
        ("JobMemoryLimit", ctypes.c_size_t),
        ("PeakProcessMemoryUsed", ctypes.c_size_t),
        ("PeakJobMemoryUsed", ctypes.c_size_t),
    ]


class _TcpRow(ctypes.Structure):
    _fields_ = [
        (name, wintypes.DWORD)
        for name in (
            "state",
            "localAddress",
            "localPort",
            "remoteAddress",
            "remotePort",
            "pid",
        )
    ]


class OwnedBackend:
    def __init__(
        self, executable: Path, port: int, output: Path, env: dict[str, str]
    ) -> None:
        self.port = port
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        self.kernel.CreateJobObjectW.restype = wintypes.HANDLE
        self.kernel.SetInformationJobObject.argtypes = [
            wintypes.HANDLE,
            ctypes.c_int,
            ctypes.c_void_p,
            wintypes.DWORD,
        ]
        self.kernel.AssignProcessToJobObject.argtypes = [
            wintypes.HANDLE,
            wintypes.HANDLE,
        ]
        self.kernel.IsProcessInJob.argtypes = [
            wintypes.HANDLE,
            wintypes.HANDLE,
            ctypes.POINTER(wintypes.BOOL),
        ]
        self.kernel.OpenProcess.argtypes = [
            wintypes.DWORD,
            wintypes.BOOL,
            wintypes.DWORD,
        ]
        self.kernel.OpenProcess.restype = wintypes.HANDLE
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.kernel.QueryInformationJobObject.argtypes = [
            wintypes.HANDLE,
            ctypes.c_int,
            ctypes.c_void_p,
            wintypes.DWORD,
            ctypes.c_void_p,
        ]
        self.job = self.kernel.CreateJobObjectW(None, None)
        if not self.job:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = _ExtendedLimit()
        limits.BasicLimitInformation.LimitFlags = (
            0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        )
        if not self.kernel.SetInformationJobObject(
            self.job, 9, ctypes.byref(limits), ctypes.sizeof(limits)
        ):
            self.kernel.CloseHandle(self.job)
            raise ctypes.WinError(ctypes.get_last_error())
        self.process: subprocess.Popen[bytes] | None = None
        self.stopped = False
        self.stdout = (output / "backend.stdout.log").open("wb")
        self.stderr = (output / "backend.stderr.log").open("wb")
        try:
            # Assign the suspended process before it can create PyInstaller children.
            self.process = subprocess.Popen(
                [
                    str(executable),
                    "serve",
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(port),
                    "--parent-pid",
                    str(os.getpid()),
                ],
                cwd=executable.parent,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=self.stdout,
                stderr=self.stderr,
                creationflags=subprocess.CREATE_NO_WINDOW
                | 0x00000004,  # CREATE_SUSPENDED
            )
            handle = wintypes.HANDLE(int(self.process._handle))
            if not self.kernel.AssignProcessToJobObject(self.job, handle):
                raise ctypes.WinError(ctypes.get_last_error())
            resume = ctypes.WinDLL("ntdll").NtResumeProcess
            resume.argtypes = [wintypes.HANDLE]
            resume.restype = wintypes.LONG
            status = resume(handle)
            if status:
                raise RuntimeError(
                    f"Could not resume owned backend: NTSTATUS {status:#x}"
                )
        except BaseException:
            if self.process is not None and self.process.poll() is None:
                self.process.kill()
            self.close()
            raise

    def listener_owned(self) -> bool:
        if self.process is None or self.process.poll() is not None:
            raise RuntimeError("The isolated backend exited before completing the test")
        api = ctypes.WinDLL("iphlpapi").GetExtendedTcpTable
        api.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(wintypes.DWORD),
            wintypes.BOOL,
            wintypes.ULONG,
            ctypes.c_int,
            wintypes.ULONG,
        ]
        api.restype = wintypes.DWORD
        size = wintypes.DWORD(0)
        api(None, ctypes.byref(size), False, socket.AF_INET, 3, 0)
        buffer = ctypes.create_string_buffer(size.value)
        result = api(buffer, ctypes.byref(size), False, socket.AF_INET, 3, 0)
        if result:
            raise RuntimeError(f"Could not query listener ownership: {result}")
        count = wintypes.DWORD.from_buffer(buffer).value
        found = False
        for index in range(count):
            row = _TcpRow.from_buffer(
                buffer, ctypes.sizeof(wintypes.DWORD) + index * ctypes.sizeof(_TcpRow)
            )
            if socket.ntohs(row.localPort & 0xFFFF) != self.port:
                continue
            handle = self.kernel.OpenProcess(
                0x1000, False, row.pid
            )  # QUERY_LIMITED_INFORMATION
            if not handle:
                raise RuntimeError("Cannot establish ownership of the selected port")
            owned = wintypes.BOOL(False)
            try:
                checked = self.kernel.IsProcessInJob(
                    handle, self.job, ctypes.byref(owned)
                )
                if not checked or not owned.value:
                    raise RuntimeError(
                        "Refusing HTTP: port listener is outside the test-owned process tree"
                    )
            finally:
                self.kernel.CloseHandle(handle)
            found = True
        return found

    def close(self) -> None:
        if self.stopped:
            return
        self.stopped = True
        handles = []
        buffer = ctypes.create_string_buffer(8192)
        if self.kernel.QueryInformationJobObject(
            self.job, 3, buffer, len(buffer), None
        ):
            count = wintypes.DWORD.from_buffer(buffer, 4).value
            for index in range(count):
                pid = ctypes.c_size_t.from_buffer(
                    buffer, 8 + index * ctypes.sizeof(ctypes.c_size_t)
                ).value
                handle = self.kernel.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
                if handle:
                    handles.append(handle)
        self.kernel.CloseHandle(self.job)
        failed = False
        for handle in handles:
            try:
                if self.kernel.WaitForSingleObject(handle, 10000) != 0:
                    failed = True
            finally:
                self.kernel.CloseHandle(handle)
        if self.process is not None:
            self.process.wait(timeout=10)
        self.stdout.close()
        self.stderr.close()
        if failed:
            raise RuntimeError(
                "An owned backend process failed to exit when its Job Object closed"
            )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", type=Path, required=True)
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--reference-dir",
        type=Path,
        default=ROOT / "build" / "bubble-redraw-qa" / "final",
    )
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("The packaged backend lifecycle test requires Windows")
    backend = args.backend.expanduser().resolve(strict=True)
    source = args.source_dir.expanduser().resolve(strict=True)
    reference = args.reference_dir.expanduser().resolve(strict=True)
    output = args.output_dir.expanduser().resolve()
    if output == source or source in output.parents or output in source.parents:
        parser.error("--output-dir must be separate from the source chapter")
    output.mkdir(parents=True, exist_ok=True)
    data = output / "isolated-data"
    data.mkdir(exist_ok=False)
    # Nonempty isolated data prevents any migration of the user's library.
    (data / ".smoke-isolation").write_text(
        "isolated release redraw test", encoding="utf-8"
    )
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("QINGJUAN_")
    }
    env.update(
        {
            "QINGJUAN_DATA_DIR": str(data),
            "QINGJUAN_TRUST_LOCAL_ADMIN": "1",
            "QINGJUAN_DISABLE_ADMIN_WEB": "1",
            "QINGJUAN_MULTI_USER": "0",
        }
    )
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reservation:
        reservation.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    report: dict[str, Any] = {
        "createdAt": datetime.now(UTC).isoformat(),
        "backend": str(backend),
        "backendSha256": hashlib.sha256(backend.read_bytes()).hexdigest(),
        "port": port,
        "externalServicesUsed": False,
        "userDataModified": False,
        "pages": [],
        "passed": False,
        "ownedProcessesStopped": False,
    }
    owned: OwnedBackend | None = None
    try:
        owned = OwnedBackend(backend, port, output, env)
        report["ownedRootPid"] = owned.process.pid
        with httpx.Client(
            base_url=f"http://127.0.0.1:{port}",
            trust_env=False,
            follow_redirects=False,
            timeout=120,
        ) as client:
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                if owned.listener_owned():
                    try:
                        health = client.get("/healthz", timeout=2)
                        health.raise_for_status()
                        if health.json().get("status") == "ok":
                            report["health"] = health.json()
                            break
                    except httpx.HTTPError:
                        pass
                time.sleep(0.25)
            else:
                raise RuntimeError("Isolated packaged backend health check timed out")
            if not owned.listener_owned():
                raise RuntimeError(
                    "Owned backend listener disappeared before metadata check"
                )
            metadata = client.get("/api/v1/meta")
            metadata.raise_for_status()
            report["meta"] = metadata.json()
            if report["meta"].get("service") != "qingjuan-backend":
                raise RuntimeError("Unexpected packaged backend metadata")
            for number in (4, 5):
                stem = f"page-{number:04d}"
                image_path = source / f"{stem}.jpg"
                project_path = (
                    source
                    / "manga_translator_work"
                    / "json"
                    / f"{stem}_translations.json"
                )
                input_bytes = image_path.read_bytes()
                project_bytes = project_path.read_bytes()
                if not owned.listener_owned():
                    raise RuntimeError(
                        "Owned backend listener disappeared before rendering"
                    )
                response = client.post(
                    "/api/v1/images/workflow",
                    headers={"X-QingJuan-Local-Request": "1"},
                    data={
                        "mode": "import_translation_render",
                        "language": "中文",
                        "title": "Isolated bubble redraw release test",
                        "project": project_bytes.decode("utf-8-sig"),
                    },
                    files={"file": (image_path.name, input_bytes, "image/jpeg")},
                )
                response.raise_for_status()
                result = response.json()
                if result.get("mode") != "import_translation_render" or not result.get(
                    "outputImageBase64"
                ):
                    raise RuntimeError(
                        f"{stem}: workflow did not return the requested rendered image"
                    )
                rendered = base64.b64decode(result["outputImageBase64"], validate=True)
                (output / f"{stem}-redrawn.png").write_bytes(rendered)
                if result.get("inpaintedImageBase64"):
                    (output / f"{stem}-inpainted.png").write_bytes(
                        base64.b64decode(result["inpaintedImageBase64"], validate=True)
                    )
                with (
                    Image.open(BytesIO(rendered)) as image,
                    Image.open(reference / stem / "redrawn.png") as expected,
                ):
                    actual = image.convert("RGB")
                    expected_rgb = expected.convert("RGB")
                    same_size = actual.size == expected_rgb.size
                    difference = (
                        ImageChops.difference(actual, expected_rgb)
                        if same_size
                        else None
                    )
                    difference_bounds = (
                        difference.getbbox() if difference is not None else None
                    )
                    identical = same_size and difference_bounds is None
                    if difference is not None and not identical:
                        difference.save(output / f"{stem}-pixel-difference.png")
                if (
                    image_path.read_bytes() != input_bytes
                    or project_path.read_bytes() != project_bytes
                ):
                    raise RuntimeError(
                        "Read-only source files changed during the smoke test"
                    )
                page_report = {
                    "page": stem,
                    "pixelIdenticalToLocal": identical,
                    "differenceBounds": difference_bounds,
                    "imageSize": actual.size,
                    "renderedSha256": hashlib.sha256(rendered).hexdigest(),
                    "diagnostics": result.get("diagnostics", {}),
                }
                report["pages"].append(page_report)
                print(
                    f"{stem}: packaged workflow completed; pixel-identical to local final = {identical}",
                    flush=True,
                )
                if not identical:
                    raise RuntimeError(
                        f"{stem}: packaged image differs from the local final redraw"
                    )
            report["passed"] = True
    except BaseException as error:
        report["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        try:
            if owned is not None:
                owned.close()
                report["ownedProcessesStopped"] = True
        finally:
            (output / "report.json").write_text(
                json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
            )
    print(
        f"Packaged backend smoke passed; all owned processes stopped. Report: {output / 'report.json'}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
