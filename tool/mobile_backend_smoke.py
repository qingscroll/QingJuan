"""Exercise the Android API contract against an isolated, real HTTP backend.

Run with python-backend/.venv/Scripts/python.exe tool/mobile_backend_smoke.py.
This is a loopback service check, not an Android device or external-site test.
The service, data directory, accounts, and credentials exist only for this run.
"""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
from datetime import UTC, datetime
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parents[1]
BACKEND = ROOT / "python-backend"
REPORT = ROOT / "build" / "mobile-backend-smoke.json"


def _password_hash(password: str) -> str:
    salt = secrets.token_bytes(16)
    iterations = 600_000
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    return f"pbkdf2_sha256:{iterations}:{salt.hex()}:{digest.hex()}"


def _port() -> int:
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return int(reservation.getsockname()[1])


def main() -> int:
    started = time.monotonic()
    checks: list[dict[str, object]] = []
    report: dict[str, object] = {
        "scope": "isolated real loopback HTTP service; not Android device validation",
        "createdAt": datetime.now(UTC).isoformat(),
        "externalContentServicesUsed": False,
        "paidTranslationServicesUsed": False,
        "checks": checks,
    }
    process: subprocess.Popen[bytes] | None = None
    stage = "startup"
    try:
        with tempfile.TemporaryDirectory(
            prefix="qingjuan-mobile-smoke-", ignore_cleanup_errors=True
        ) as temporary:
            data = Path(temporary)
            # An empty data directory triggers legacy migration. This marker prevents
            # touching or copying any user's existing backend library/configuration.
            (data / ".smoke-isolation").write_text("isolated test data", encoding="utf-8")
            connection_token = secrets.token_urlsafe(36)
            password = secrets.token_urlsafe(24)
            env = {key: value for key, value in os.environ.items() if not key.startswith("QINGJUAN_")}
            env.update(
                {
                    "QINGJUAN_DATA_DIR": str(data),
                    "QINGJUAN_MULTI_USER": "1",
                    "QINGJUAN_AUTH_TOKEN_SHA256": hashlib.sha256(connection_token.encode()).hexdigest(),
                    "QINGJUAN_2FA_ENCRYPTION_KEY": secrets.token_hex(32),
                    "QINGJUAN_ADMIN_SESSION_SECRET": secrets.token_hex(32),
                    "QINGJUAN_ADMIN_PASSWORD_HASH": _password_hash(secrets.token_urlsafe(32)),
                    "QINGJUAN_DISABLE_ADMIN_WEB": "1",
                    "PYTHONUNBUFFERED": "1",
                    "PYTHONUTF8": "1",
                }
            )
            port = _port()
            executable = BACKEND / ".venv" / "Scripts" / "python.exe"
            process = subprocess.Popen(
                [
                    str(executable),
                    "-m",
                    "uvicorn",
                    "app.main:app",
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(port),
                    "--no-access-log",
                    "--log-level",
                    "warning",
                ],
                cwd=BACKEND,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
            )
            try:
                with httpx.Client(
                    base_url=f"http://127.0.0.1:{port}",
                    timeout=20,
                    trust_env=False,
                    headers={"Authorization": f"Bearer {connection_token}"},
                ) as client:
                    deadline = time.monotonic() + 45
                    while True:
                        if process.poll() is not None:
                            raise RuntimeError("temporary backend exited during startup")
                        try:
                            if client.get("/healthz").status_code == 200:
                                break
                        except httpx.TransportError:
                            pass
                        if time.monotonic() > deadline:
                            raise RuntimeError("temporary backend startup timed out")
                        time.sleep(0.2)

                    def request(label: str, method: str, path: str, *, expected: int = 200, **kwargs):
                        nonlocal stage
                        stage = label
                        response = client.request(method, "/api/v1" + path, **kwargs)
                        if response.status_code != expected:
                            raise RuntimeError(
                                f"HTTP status mismatch: expected {expected}, got {response.status_code}"
                            )
                        checks.append({"name": label, "passed": True, "httpStatus": response.status_code})
                        return response.json() if response.content else None

                    def verify(label: str, condition: bool, **details: object) -> None:
                        nonlocal stage
                        stage = label
                        if not condition:
                            raise RuntimeError("response did not meet the expected contract")
                        checks.append({"name": label, "passed": True, **details})

                    def wait_task(task_id: str, target: str) -> dict:
                        deadline = time.monotonic() + 25
                        while True:
                            response = client.get("/api/v1/tasks")
                            if response.status_code != 200:
                                raise RuntimeError("task polling was rejected")
                            task = next((item for item in response.json() if item["id"] == task_id), None)
                            if task and task["status"] in ("completed", "failed"):
                                verify(
                                    f"task reaches {target}",
                                    task["status"] == target,
                                    taskType=task["taskType"],
                                    status=task["status"],
                                    progress=task["progress"],
                                )
                                return task
                            if time.monotonic() > deadline:
                                raise RuntimeError("task did not reach a final state before timeout")
                            time.sleep(0.15)

                    meta = request("connection metadata", "GET", "/meta")
                    verify(
                        "multi-user capability advertised",
                        meta.get("capabilities", {}).get("multiUser") is True,
                    )
                    request(
                        "invalid connection token rejected",
                        "GET",
                        "/meta",
                        expected=401,
                        headers={"Authorization": "Bearer invalid-smoke-token"},
                    )
                    policy = request("registration policy", "GET", "/auth/registration-policy")
                    verify(
                        "isolated registration has no external mail requirement",
                        not policy["emailVerificationRequired"] and not policy["identityBadgeRequired"],
                    )
                    first = request(
                        "register reader",
                        "POST",
                        "/auth/register",
                        expected=201,
                        json={
                            "username": "smoke_reader",
                            "displayName": "Smoke reader",
                            "email": "smoke-reader@example.test",
                            "password": password,
                        },
                    )
                    reader_token = first["token"]
                    client.headers["X-QingJuan-User-Token"] = reader_token
                    request("restore registered session", "GET", "/auth/session")
                    request(
                        "ordinary reader cannot import sources",
                        "POST",
                        "/sources/import-text",
                        expected=403,
                        json={"content": "[]"},
                    )
                    novel = (
                        "第一章 清晨\n\n窗外的风轻轻翻过书页。\n这是青卷的隔离阅读验证文本。\n\n"
                        "第二章 归途\n\n读完这一章，留下一个位置，稍后从这里继续。\n"
                    )
                    book = request(
                        "upload TXT through multipart API",
                        "POST",
                        "/books/import-local",
                        files={"file": ("smoke-novel.txt", novel.encode("utf-8"), "text/plain")},
                        data={
                            "bookKind": "长小说",
                            "language": "中文",
                            "needTranslation": "false",
                            "title": "Smoke novel",
                        },
                    )
                    book_id = book["id"]
                    library = request("list personal library", "GET", "/books")
                    verify(
                        "imported work belongs to reader", len(library) == 1 and library[0]["id"] == book_id
                    )
                    detail = request("load work details and chapters", "GET", f"/books/{book_id}")
                    chapters = detail["chapters"]
                    verify("TXT chapter parsing", len(chapters) >= 2, chapterCount=len(chapters))
                    chapter_index = chapters[-1]["index"]
                    chapter = request(
                        "read original chapter",
                        "GET",
                        f"/books/{book_id}/chapters/{chapter_index}",
                        params={"mode": "original"},
                    )
                    verify(
                        "reader receives real text", bool(chapter["content"]) and bool(chapter["paragraphs"])
                    )
                    progress = request(
                        "save anchored reading position",
                        "PUT",
                        f"/books/{book_id}/progress",
                        json={
                            "chapterIndex": chapter_index,
                            "scrollRatio": 0.42,
                            "anchorType": "paragraph",
                            "anchorIndex": 0,
                            "anchorOffsetRatio": 0.3,
                        },
                    )
                    verify(
                        "progress retained",
                        progress["lastChapterIndex"] == chapter_index and progress["lastScrollRatio"] == 0.42,
                    )
                    download = request(
                        "enqueue chapter download",
                        "POST",
                        f"/books/{book_id}/chapters/download",
                        json={"chapterIndexes": [item["index"] for item in chapters]},
                    )
                    completed = wait_task(download["id"], "completed")
                    verify(
                        "download counts agree with total",
                        completed["completedCount"] == len(chapters) and completed["progress"] == 100,
                    )
                    model = request("read translation availability", "POST", "/translation-model/check")
                    verify(
                        "unconfigured translation reported honestly",
                        not model["available"] and model["status"] in ("disabled", "unconfigured"),
                        status=model["status"],
                    )
                    request(
                        "remote reader cannot force admin probe",
                        "POST",
                        "/translation-model/check",
                        expected=401,
                        params={"force": "true"},
                    )
                    translation = request(
                        "enqueue translation with disabled model",
                        "POST",
                        f"/books/{book_id}/chapters/translate",
                        json={"chapterIndexes": [chapter_index]},
                    )
                    failed = wait_task(translation["id"], "failed")
                    verify(
                        "translation failure explains recovery",
                        "模型" in str(failed.get("error"))
                        and any(reason in str(failed.get("error")) for reason in ("未启用", "未配置")),
                        errorCategory="model not enabled/configured",
                    )
                    # A second genuine user validates server ownership instead of
                    # relying on filtering or permissions in Flutter alone.
                    second = request(
                        "register second isolated reader",
                        "POST",
                        "/auth/register",
                        expected=201,
                        json={
                            "username": "smoke_second",
                            "displayName": "Second reader",
                            "email": "smoke-second@example.test",
                            "password": secrets.token_urlsafe(24),
                        },
                    )
                    client.headers["X-QingJuan-User-Token"] = second["token"]
                    second_books = request("second reader library", "GET", "/books")
                    verify("libraries isolated between users", second_books == [])
                    request("other reader cannot access book", "GET", f"/books/{book_id}", expected=404)
                    client.headers["X-QingJuan-User-Token"] = reader_token
                    request("logout original reader", "POST", "/auth/logout", expected=204)
                    request("revoked session rejected", "GET", "/auth/session", expected=401)
                    client.headers.pop("X-QingJuan-User-Token", None)
                    session = request(
                        "login reader again",
                        "POST",
                        "/auth/login",
                        json={"username": "smoke_reader", "password": password},
                    )
                    client.headers["X-QingJuan-User-Token"] = session["token"]
                    restored = request("restore reading context after login", "GET", f"/books/{book_id}")
                    verify(
                        "chapter and paragraph position survive login",
                        restored["progress"]["lastChapterIndex"] == chapter_index
                        and restored["progress"]["lastScrollRatio"] == 0.42
                        and restored["progress"]["lastAnchorOffsetRatio"] == 0.3,
                    )
                    report["passed"] = True
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=12)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                report["temporaryServerStopped"] = process.poll() is not None
        report["temporaryDataRemoved"] = not data.exists()
    except Exception as error:
        report["passed"] = False
        report["failedStage"] = stage
        # Never serialize backend payloads, credentials, or raw server logs.
        report["failureType"] = type(error).__name__
        report["failureSummary"] = (
            str(error)
            if isinstance(error, RuntimeError)
            else "Verification could not complete; see failing stage."
        )
    if "data" in locals():
        # Windows antivirus/indexing may briefly retain the just-closed SQLite file.
        # Retry only the exact temporary directory created by this invocation.
        if data.resolve().parent != Path(tempfile.gettempdir()).resolve() or not data.name.startswith(
            "qingjuan-mobile-smoke-"
        ):
            raise RuntimeError("unexpected temporary cleanup target")
        for _attempt in range(40):
            try:
                if data.exists():
                    shutil.rmtree(data)
                break
            except PermissionError:
                time.sleep(0.25)
        report["temporaryDataRemoved"] = not data.exists()
        if data.exists():
            report["passed"] = False
            report["failedStage"] = "temporary data cleanup"
            report["failureSummary"] = "The isolated temporary data directory remained locked."
    report["elapsedSeconds"] = round(time.monotonic() - started, 2)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
