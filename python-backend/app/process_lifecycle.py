from __future__ import annotations

import asyncio
import ctypes
import os
import threading
import time
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Literal

from fastapi import HTTPException, Request, status
from pydantic import BaseModel, ConfigDict

from .admin_auth import read_admin_session

PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
STILL_ACTIVE = 259

BackendServiceState = Literal["running", "stopped", "restarting"]
BackendServiceAction = Literal["start", "stop", "restart"]


class BackendServiceStatus(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schemaVersion: Literal[1] = 1
    state: BackendServiceState
    businessApiAvailable: bool
    managementApiAvailable: Literal[True] = True
    generation: int
    startedAt: str
    stoppedAt: str | None = None
    lastActionAt: str | None = None
    message: str


class BackendServiceActionPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    action: BackendServiceAction


class BackendServiceActionResponse(BackendServiceStatus):
    accepted: Literal[True] = True
    action: BackendServiceAction


class BackendServiceController:
    """Keep the business API controllable while the admin control plane stays online."""

    def __init__(self) -> None:
        self._state: BackendServiceState = "running"
        self._generation = 1
        self._started_at = _now()
        self._stopped_at: str | None = None
        self._last_action_at: str | None = None
        self._message = "后端业务服务运行中"
        self._running = asyncio.Event()
        self._running.set()
        self._action_lock = asyncio.Lock()

    @property
    def is_running(self) -> bool:
        return self._state == "running"

    async def wait_until_running(self) -> None:
        await self._running.wait()

    def status(self) -> BackendServiceStatus:
        return BackendServiceStatus(
            state=self._state,
            businessApiAvailable=self.is_running,
            generation=self._generation,
            startedAt=self._started_at,
            stoppedAt=self._stopped_at,
            lastActionAt=self._last_action_at,
            message=self._message,
        )

    async def apply(self, action: BackendServiceAction) -> BackendServiceActionResponse:
        async with self._action_lock:
            timestamp = _now()
            if action == "stop":
                self._running.clear()
                self._state = "stopped"
                self._stopped_at = timestamp
                self._last_action_at = timestamp
                self._message = "后端业务服务已关闭；管理通道仍在线，可随时重新开启"
            elif action == "start":
                if self._state != "running":
                    self._generation += 1
                    self._started_at = timestamp
                self._state = "running"
                self._stopped_at = None
                self._last_action_at = timestamp
                self._message = "后端业务服务运行中"
                self._running.set()
            else:
                self._state = "restarting"
                self._message = "后端业务服务正在重启"
                self._running.clear()
                await asyncio.sleep(0)
                completed_at = _now()
                self._generation += 1
                self._state = "running"
                self._started_at = completed_at
                self._stopped_at = None
                self._last_action_at = completed_at
                self._message = "后端业务服务已重新启动"
                self._running.set()
            return BackendServiceActionResponse(
                **self.status().model_dump(),
                accepted=True,
                action=action,
            )


def get_backend_service_controller(request: Request) -> BackendServiceController:
    controller = getattr(request.app.state, "backend_service_controller", None)
    if not isinstance(controller, BackendServiceController):
        raise RuntimeError("后端服务控制器尚未初始化")
    return controller


async def require_business_service_running(request: Request) -> None:
    controller = get_backend_service_controller(request)
    if controller.is_running or read_admin_session(request) is not None:
        return
    raise HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail="后端业务服务已由管理员关闭，请稍后重试",
        headers={"Retry-After": "5"},
    )


def _now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def is_process_running(process_id: int) -> bool:
    """Return whether a process exists without sending a signal to it."""

    if process_id <= 0:
        return False
    if os.name != "nt":
        try:
            os.kill(process_id, 0)
        except (OSError, ProcessLookupError):
            return False
        return True

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_bool, ctypes.c_uint32]
    kernel32.OpenProcess.restype = ctypes.c_void_p
    kernel32.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    kernel32.GetExitCodeProcess.restype = ctypes.c_bool
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel32.CloseHandle.restype = ctypes.c_bool

    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, process_id)
    if not handle:
        return False
    try:
        exit_code = ctypes.c_uint32()
        if not kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
            return False
        return exit_code.value == STILL_ACTIVE
    finally:
        kernel32.CloseHandle(handle)


def start_parent_process_watcher(
    parent_process_id: int,
    on_parent_exit: Callable[[], None],
    *,
    poll_interval: float = 0.5,
) -> threading.Thread:
    """Run a daemon watcher and invoke the callback after the parent exits."""

    def watch() -> None:
        while is_process_running(parent_process_id):
            time.sleep(poll_interval)
        on_parent_exit()

    thread = threading.Thread(
        target=watch,
        name="qingjuan-parent-process-watcher",
        daemon=True,
    )
    thread.start()
    return thread
