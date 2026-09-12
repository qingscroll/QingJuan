from __future__ import annotations

from fastapi import APIRouter, Depends, Request, Response
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, ConfigDict, Field, SecretStr, field_validator

from ..db import DEFAULT_ADMIN_USER_ID, list_site_plugin_enabled_states
from ..process_lifecycle import require_business_service_running
from ..site_plugins import shaoniandream_account as account
from ..site_plugins.shaoniandream_login_page import LOGIN_HTML
from ..user_auth import require_user_access
from .shaoniandream_contract import PRIVATE_HEADERS, ShaonianDreamRoute

router = APIRouter(prefix="/plugins/shaoniandream/account", route_class=ShaonianDreamRoute)
public_router = APIRouter(
    prefix="/site-login/shaoniandream",
    route_class=ShaonianDreamRoute,
    include_in_schema=False,
    dependencies=[Depends(require_business_service_running)],
)


class BrowserLoginFlow(BaseModel):
    flowId: str
    browserToken: str
    expiresAt: str


class BrowserLoginStatus(BaseModel):
    status: str
    message: str
    loggedIn: bool


class PasswordLogin(BaseModel):
    model_config = ConfigDict(extra="forbid")

    username: str = Field(min_length=1, max_length=128)
    password: SecretStr = Field(min_length=1, max_length=256)
    geetest_challenge: str = Field(min_length=1, max_length=256)
    geetest_validate: SecretStr = Field(min_length=1, max_length=256)
    geetest_seccode: SecretStr = Field(min_length=1, max_length=256)
    auto_login: int = Field(default=1, ge=0, le=1)

    @field_validator("username")
    @classmethod
    def nonblank_username(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("请输入少年梦账号")
        return value.strip()


def enabled() -> None:
    if not list_site_plugin_enabled_states().get("shaoniandream", True):
        raise account.LoginFlowError(
            "少年梦插件尚未启用",
            code="plugin_disabled",
            status_code=409,
            hint="请先在插件配置中启用少年梦，再重新登录",
        )


def runtime(request: Request):
    access = require_user_access(request)
    return account.ACCOUNTS.runtime(access.owner_id or DEFAULT_ADMIN_USER_ID)


@router.post("/login-browser", response_model=BrowserLoginFlow)
async def start(request: Request, response: Response):
    response.headers.update(PRIVATE_HEADERS)
    current = runtime(request)
    enabled()
    return current.start_login()


@router.get("/login-browser/{flow_id}", response_model=BrowserLoginStatus)
async def poll(flow_id: str, request: Request, response: Response):
    response.headers.update(PRIVATE_HEADERS)
    current = runtime(request)
    enabled()
    return current.poll_login(flow_id)


@router.delete("/login-browser/{flow_id}", status_code=204)
async def cancel(flow_id: str, request: Request, response: Response):
    response.headers.update(PRIVATE_HEADERS)
    runtime(request).cancel_login(flow_id)


@public_router.get("", response_class=HTMLResponse)
async def page():
    return HTMLResponse(
        LOGIN_HTML,
        headers={
            **PRIVATE_HEADERS,
            "Content-Security-Policy": "default-src 'none'; script-src 'self' 'unsafe-inline' https://*.geetest.com https://*.geevisit.com https://*.gsensebot.com; "
            "style-src 'unsafe-inline' https://*.geetest.com https://*.geevisit.com https://*.gsensebot.com; "
            "img-src data: https://*.geetest.com https://*.geevisit.com https://*.gsensebot.com; "
            "connect-src 'self' https://*.geetest.com https://*.geevisit.com https://*.gsensebot.com; "
            "frame-src https://*.geetest.com https://*.geevisit.com https://*.gsensebot.com; "
            "base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        },
    )


def browser_token(request: Request) -> str:
    enabled()
    token = request.headers.get("X-Login-Token", "")
    if len(token) != 43 or not token.isascii():
        raise account.LoginFlowError(
            "登录链接无效", code="invalid_token", status_code=404, hint="请从青卷发起登录"
        )
    return token


@public_router.get("/geetest")
async def geetest(request: Request, response: Response):
    response.headers.update(PRIVATE_HEADERS)
    return await account.ACCOUNTS.geetest(browser_token(request))


@public_router.post("/login")
async def login(payload: PasswordLogin, request: Request, response: Response):
    response.headers.update(PRIVATE_HEADERS)
    await account.ACCOUNTS.login(
        browser_token(request),
        {
            "username": payload.username.strip(),
            "password": payload.password.get_secret_value(),
            "geetest_challenge": payload.geetest_challenge,
            "geetest_validate": payload.geetest_validate.get_secret_value(),
            "geetest_seccode": payload.geetest_seccode.get_secret_value(),
        },
        auto_login=payload.auto_login,
    )
    return {"loggedIn": True}
