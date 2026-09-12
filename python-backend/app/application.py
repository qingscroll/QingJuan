from __future__ import annotations

import os
import re
import sys
import time
from collections.abc import AsyncIterator, Callable, Iterable
from contextlib import AbstractAsyncContextManager
from pathlib import Path

from fastapi import APIRouter, Depends, FastAPI, Request, Response
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from .maintenance import MaintenanceGate, MaintenanceMiddleware
from .process_lifecycle import BackendServiceController, require_business_service_running
from .resource_limits import ResourceLimitError
from .security import API_PREFIX, authentication_enabled, require_api_authentication
from .service_diagnostics import RequestMetrics, should_track_request
from .storage_models import StorageError

APP_TITLE = "青卷后端"
DISABLE_ADMIN_WEB_ENV = "QINGJUAN_DISABLE_ADMIN_WEB"
_VERSION_PATTERN = re.compile(r"^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$")


def admin_web_enabled() -> bool:
    return os.getenv(DISABLE_ADMIN_WEB_ENV, "").strip() != "1"


def read_app_version(pubspec_path: Path) -> str:
    for line in pubspec_path.read_text(encoding="utf-8").splitlines():
        match = _VERSION_PATTERN.fullmatch(line)
        if match is not None:
            return match.group(1)
    raise RuntimeError(f"无法从 {pubspec_path} 读取应用版本")


def _pubspec_path() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "pubspec.yaml"
    return Path(__file__).resolve().parents[2] / "pubspec.yaml"


APP_VERSION = read_app_version(_pubspec_path())

Lifespan = Callable[[FastAPI], AbstractAsyncContextManager[AsyncIterator[None]]]


def create_application(
    *,
    routers: Iterable[APIRouter],
    public_routers: Iterable[APIRouter] = (),
    management_routers: Iterable[APIRouter] = (),
    api_prefix: str = "",
    authenticate: bool = False,
    lifespan: Lifespan | None = None,
    admin_static_path: Path | None = None,
) -> FastAPI:
    """创建 FastAPI 应用；入口文件只负责组装，不再内联基础设施配置。"""

    application = FastAPI(
        title=APP_TITLE,
        version=APP_VERSION,
        lifespan=lifespan,
        docs_url=None if authentication_enabled() else "/docs",
        redoc_url=None if authentication_enabled() else "/redoc",
        openapi_url=None if authentication_enabled() else "/openapi.json",
    )

    @application.exception_handler(RequestValidationError)
    async def sanitized_validation_error(
        _request: Request,
        error: RequestValidationError,
    ) -> JSONResponse:
        # FastAPI includes the original input in its default 422 response. Registration and
        # settings payloads contain passwords, verification codes and identity badges, so
        # validation responses must report locations/messages without reflecting input values.
        details = [
            {key: value for key, value in item.items() if key not in {"input", "url"}}
            for item in error.errors()
        ]
        return JSONResponse(status_code=422, content={"detail": jsonable_encoder(details)})

    @application.exception_handler(ResourceLimitError)
    @application.exception_handler(StorageError)
    async def resource_error(_request: Request, error: ResourceLimitError | StorageError) -> JSONResponse:
        return JSONResponse(status_code=error.status_code, content={"detail": str(error)},
            headers={"Cache-Control": "no-store"})

    request_metrics = RequestMetrics()
    application.state.request_metrics = request_metrics
    application.state.backend_service_controller = BackendServiceController()
    router_prefix = api_prefix or (API_PREFIX if authenticate else "")
    auth_prefix = f"{router_prefix}/auth" or "/auth"

    @application.middleware("http")
    async def prevent_auth_response_storage(request: Request, call_next: Callable) -> Response:
        response = await call_next(request)
        if (
            request.url.path == auth_prefix
            or request.url.path.startswith(f"{auth_prefix}/")
            or request.url.path.startswith("/site-login/shaoniandream")
        ):
            response.headers["Cache-Control"] = "no-store"
            response.headers["Pragma"] = "no-cache"
        return response

    @application.middleware("http")
    async def collect_request_metrics(request: Request, call_next: Callable) -> Response:
        if not should_track_request(request.url.path):
            return await call_next(request)
        started = time.perf_counter()
        status_code = 500
        try:
            response = await call_next(request)
            status_code = response.status_code
            return response
        finally:
            request_metrics.record(status_code, (time.perf_counter() - started) * 1000)

    for router in public_routers:
        application.include_router(router)
    for router in management_routers:
        # These routes perform their own authentication inside a short admission.
        # Their exclusive maintenance operation must not hold outer admission.
        application.include_router(router, prefix=router_prefix)
    dependencies = (
        [Depends(require_api_authentication), Depends(require_business_service_running)]
        if authenticate
        else None
    )
    for router in routers:
        application.include_router(
            router,
            prefix=router_prefix,
            dependencies=dependencies,
        )

    if admin_static_path is not None:

        @application.middleware("http")
        async def add_admin_security_headers(request: Request, call_next: Callable) -> Response:
            response = await call_next(request)
            if request.url.path == "/admin" or request.url.path.startswith("/admin/"):
                response.headers["Content-Security-Policy"] = (
                    "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
                    "img-src 'self' data:; font-src 'self' data:; connect-src 'self'; "
                    "object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
                )
                response.headers["Referrer-Policy"] = "no-referrer"
                response.headers["X-Content-Type-Options"] = "nosniff"
                response.headers["X-Frame-Options"] = "DENY"
                if request.url.path.startswith("/admin/assets/"):
                    response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
                else:
                    response.headers["Cache-Control"] = "no-store"
            return response

        application.mount(
            "/admin",
            StaticFiles(directory=admin_static_path, html=True, check_dir=True),
            name="admin",
        )

    gate = MaintenanceGate()
    application.state.maintenance_gate = gate
    application.add_middleware(
        MaintenanceMiddleware, gate=gate, backup_prefix=f"{router_prefix}/backups",
    )
    return application
