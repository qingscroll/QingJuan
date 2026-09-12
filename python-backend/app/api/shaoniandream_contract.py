"""少年梦登录的请求兼容与错误投影，仅作用于该站点的登录路由。"""

from __future__ import annotations

import json
from urllib.parse import parse_qsl

from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from fastapi.routing import APIRoute
from starlette.exceptions import HTTPException

from ..site_plugins.shaoniandream_account import LoginFlowError

PRIVATE_HEADERS = {
    "Cache-Control": "no-store",
    "Pragma": "no-cache",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
}
MAX_LOGIN_BODY = 16 * 1024
FIELD_LABELS = {
    "username": "账号",
    "password": "密码",
    "auto_login": "自动登录选项",
    "geetest_challenge": "人机验证",
    "geetest_validate": "人机验证",
    "geetest_seccode": "人机验证",
}


def error_response(exc: LoginFlowError, *, errors=None, headers=None) -> JSONResponse:
    detail = {"status": 0, "code": exc.code, "msg": str(exc), "hint": exc.hint}
    if errors is not None:
        detail["errors"] = errors
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": detail},
        headers={**(headers or {}), **PRIVATE_HEADERS},
    )


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


async def normalize_login(request: Request) -> Request:
    body = bytearray()
    async for chunk in request.stream():
        if len(body) + len(chunk) > MAX_LOGIN_BODY:
            raise LoginFlowError(
                "登录请求过大",
                code="request_too_large",
                status_code=413,
                hint="请只提交账号、密码和人机验证结果",
            )
        body.extend(chunk)
    content_type = request.headers.get("content-type", "").split(";", 1)[0].strip().lower()
    if content_type not in {"", "application/json", "application/x-www-form-urlencoded", "text/plain"}:
        raise LoginFlowError(
            "不支持此登录请求格式",
            code="unsupported_media_type",
            status_code=415,
            hint="请使用 JSON 或 application/x-www-form-urlencoded 表单提交",
        )
    try:
        text = body.decode("utf-8").strip()
        if content_type == "application/x-www-form-urlencoded" and not text.startswith(("{", "[")):
            payload = unique_object(
                parse_qsl(text, keep_blank_values=True, errors="strict", max_num_fields=16)
            )
        else:
            payload = json.loads(text, object_pairs_hook=unique_object)
        if not isinstance(payload, dict):
            raise ValueError("expected object")
    except (ValueError, RecursionError):
        raise LoginFlowError(
            "登录请求格式错误",
            code="validation_error",
            status_code=422,
            hint="请提交 UTF-8 编码的 JSON 对象或表单，字段不能重复",
        ) from None
    normalized = json.dumps(payload).encode("utf-8")
    scope = dict(request.scope)
    scope["headers"] = [
        (key, value)
        for key, value in scope["headers"]
        if key.lower() not in {b"content-type", b"content-length"}
    ] + [(b"content-type", b"application/json"), (b"content-length", str(len(normalized)).encode())]
    sent = False

    async def receive():
        nonlocal sent
        if sent:
            return {"type": "http.disconnect"}
        sent = True
        return {"type": "http.request", "body": normalized, "more_body": False}

    return Request(scope, receive)


def validation_response(exc: RequestValidationError) -> JSONResponse:
    errors = []
    for error in exc.errors()[:5]:
        # Never echo input, ctx, arbitrary field names or Pydantic error messages.
        field = next((part for part in error.get("loc", ()) if part in FIELD_LABELS), None)
        label = FIELD_LABELS.get(field, "请求参数")
        missing = error.get("type") == "missing"
        message = f"请填写{label}" if missing else f"{label}格式不正确"
        errors.append(
            {
                "loc": ["body", field] if field else ["body"],
                "msg": message,
                "type": "missing" if missing else "invalid_value",
            }
        )
    return error_response(
        LoginFlowError(
            errors[0]["msg"] if errors else "登录参数错误",
            code="validation_error",
            status_code=422,
            hint="请检查账号、密码及人机验证结果后重新提交",
        ),
        errors=errors,
    )


class ShaonianDreamRoute(APIRoute):
    def get_route_handler(self):
        original = super().get_route_handler()

        async def handler(request: Request):
            try:
                if request.method == "POST" and self.path.endswith("/site-login/shaoniandream/login"):
                    request = await normalize_login(request)
                return await original(request)
            except RequestValidationError as exc:
                return validation_response(exc)
            except LoginFlowError as exc:
                return error_response(exc)
            except HTTPException as exc:
                return error_response(
                    LoginFlowError(
                        exc.detail if isinstance(exc.detail, str) else "登录请求失败",
                        code="unauthorized" if exc.status_code == 401 else "http_error",
                        status_code=exc.status_code,
                        hint="请检查后端连接与登录状态后重试",
                    ),
                    headers=exc.headers,
                )

        return handler
