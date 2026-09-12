"""少年梦直连登录；只在当前后端进程保存按青卷用户隔离的 Cookie。"""

from __future__ import annotations

import secrets
import threading
import time
from dataclasses import dataclass, field
from datetime import UTC, datetime

import httpx

from ..scraper_network_security import create_public_http_client
from .shaoniandream_client import _json_request

FLOW_TTL = 300
ACCOUNT_TTL = 24 * 60 * 60
MAX_FLOWS = 256
MAX_ATTEMPTS = 5


def now() -> float:
    return time.time()


def iso(value: float) -> str:
    return datetime.fromtimestamp(value, UTC).isoformat().replace("+00:00", "Z")


class LoginFlowError(ValueError):
    def __init__(
        self,
        message: str,
        *,
        code: str = "upstream_error",
        status_code: int = 502,
        hint: str = "请稍后重新加载验证后重试",
    ) -> None:
        super().__init__(message)
        self.code = code
        self.status_code = status_code
        self.hint = hint


def ended_flow() -> LoginFlowError:
    return LoginFlowError(
        "登录已取消或过期", code="session_revoked", status_code=401, hint="请回到青卷重新发起登录"
    )


def exhausted_flow() -> LoginFlowError:
    return LoginFlowError(
        "登录尝试次数已用完", code="too_many_attempts", status_code=429, hint="请回到青卷重新发起登录"
    )


@dataclass
class LoginFlow:
    owner: str
    flow_id: str
    token: str = field(repr=False)
    expires: float
    cookies: httpx.Cookies = field(default_factory=httpx.Cookies, repr=False)
    status: str = "pending"
    busy: bool = False
    attempts: int = 0
    challenge: str = ""


class ShaonianDreamRuntime:
    def __init__(self, accounts: ShaonianDreamAccounts, owner: str) -> None:
        self.accounts = accounts
        self.owner = owner
        self._cookies: dict[str, str] = {}
        self._expires = 0.0

    def account_status(self) -> dict:
        with self.accounts.lock:
            if self._expires <= now():
                self._cookies.clear()
            return {
                "loggedIn": bool(self._cookies),
                "expiresAt": iso(self._expires) if self._cookies else None,
            }

    def cookies(self) -> dict[str, str]:
        with self.accounts.lock:
            self.account_status()
            return dict(self._cookies)

    def start_login(self) -> dict:
        with self.accounts.lock:
            self.accounts.purge()
            self.accounts.cancel_owner(self.owner)
            if len(self.accounts.flows) >= MAX_FLOWS:
                raise LoginFlowError(
                    "当前登录请求较多，请稍后重试", code="too_many_requests", status_code=429
                )
            flow = LoginFlow(
                self.owner, secrets.token_urlsafe(24), secrets.token_urlsafe(32), now() + FLOW_TTL
            )
            self.accounts.flows[flow.flow_id] = flow
            return {"flowId": flow.flow_id, "browserToken": flow.token, "expiresAt": iso(flow.expires)}

    def poll_login(self, flow_id: str) -> dict:
        with self.accounts.lock:
            self.accounts.purge()
            flow = self.accounts.flows.get(flow_id)
            if flow is None or flow.owner != self.owner:
                return {"status": "expired", "message": "登录已取消或过期，请重新登录", "loggedIn": False}
            success = flow.status == "success" and self.account_status()["loggedIn"]
            return {
                "status": flow.status,
                "message": "登录成功"
                if success
                else ("登录尝试次数已用完，请重新登录" if flow.status == "failed" else "请在浏览器完成登录"),
                "loggedIn": success,
            }

    def cancel_login(self, flow_id: str) -> None:
        with self.accounts.lock:
            flow = self.accounts.flows.get(flow_id)
            if flow is not None and flow.owner == self.owner:
                self.accounts.flows.pop(flow_id)

    def logout(self) -> None:
        with self.accounts.lock:
            self._cookies.clear()
            self._expires = 0.0
            self.accounts.cancel_owner(self.owner)


class ShaonianDreamAccounts:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.flows: dict[str, LoginFlow] = {}
        self.runtimes: dict[str, ShaonianDreamRuntime] = {}

    def runtime(self, owner: str) -> ShaonianDreamRuntime:
        with self.lock:
            if owner not in self.runtimes:
                self.runtimes[owner] = ShaonianDreamRuntime(self, owner)
            return self.runtimes[owner]

    def purge(self) -> None:
        for flow_id, flow in list(self.flows.items()):
            if flow.expires <= now():
                self.flows.pop(flow_id)

    def cancel_owner(self, owner: str) -> None:
        for flow_id, flow in list(self.flows.items()):
            if flow.owner == owner:
                self.flows.pop(flow_id)

    def clear(self) -> None:
        with self.lock:
            self.flows.clear()
            self.runtimes.clear()

    def reserve(self, token: str) -> LoginFlow:
        with self.lock:
            self.purge()
            flow = next((f for f in self.flows.values() if secrets.compare_digest(f.token, token)), None)
            if flow is not None and flow.status == "failed":
                raise exhausted_flow()
            if flow is None or flow.status != "pending":
                raise ended_flow()
            if flow.busy:
                raise LoginFlowError("正在处理登录，请稍后重试", code="conflict", status_code=409)
            flow.busy = True
            return flow

    def check_active(self, flow: LoginFlow) -> None:
        if self.flows.get(flow.flow_id) is not flow or flow.expires <= now():
            raise ended_flow()

    @staticmethod
    def client():
        return create_public_http_client(
            timeout=20,
            follow_redirects=False,
            headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36",
                "Accept-Language": "zh-CN,zh;q=0.9",
            },
        )

    async def geetest(self, token: str) -> dict:
        flow = self.reserve(token)
        try:
            async with self.client() as client:
                client.cookies.update(flow.cookies)
                config = await _json_request(
                    client, "GET", "/author/startcaptchaservlet", params={"t": int(now() * 1000)}
                )
                if not isinstance(config.get("gt"), str) or not isinstance(config.get("challenge"), str):
                    raise ValueError("invalid captcha")
                with self.lock:
                    self.check_active(flow)
                    flow.cookies = httpx.Cookies(client.cookies)
                    flow.challenge = config["challenge"]
                return {
                    "gt": config["gt"],
                    "challenge": flow.challenge,
                    "success": int(config.get("success", 1)),
                    "new_captcha": int(config.get("new_captcha", 1)),
                }
        except LoginFlowError:
            raise
        except Exception:
            raise LoginFlowError("获取少年梦验证码失败，请重试") from None
        finally:
            with self.lock:
                flow.busy = False

    async def login(self, token: str, credentials: dict[str, str], *, auto_login: int = 1) -> None:
        flow = self.reserve(token)
        try:
            with self.lock:
                flow.attempts += 1
                # GeeTest may append two characters to its original challenge.
                if not flow.challenge or not credentials["geetest_challenge"].startswith(flow.challenge):
                    raise LoginFlowError(
                        "人机验证已失效",
                        code="missing_geetest",
                        status_code=422,
                        hint="请重新完成人机验证后登录",
                    )
                flow.challenge = ""
            async with self.client() as client:
                client.cookies.update(flow.cookies)
                payload = await _json_request(
                    client,
                    "POST",
                    "/user/loginaction",
                    data={"type": "pc", "autoLogin": auto_login, **credentials},
                )
                if str(payload.get("status")) != "1":
                    invalid = str(payload.get("status")) in {"2", "3"}
                    raise LoginFlowError(
                        "少年梦登录失败",
                        code="invalid_credentials" if invalid else "upstream_error",
                        status_code=401 if invalid else 502,
                        hint="请检查账号密码并重新完成人机验证",
                    )
                cookies = {
                    c.name: c.value
                    for c in client.cookies.jar
                    if c.domain.lstrip(".") in {"shaoniandream.com", "www.shaoniandream.com"}
                }
                if not cookies:
                    raise LoginFlowError("少年梦未返回有效会话，请重新登录")
                with self.lock:
                    self.check_active(flow)
                    runtime = self.runtime(flow.owner)
                    runtime._cookies = cookies
                    runtime._expires = now() + ACCOUNT_TTL
                    flow.status = "success"
                    flow.cookies.clear()
        except LoginFlowError:
            if flow.attempts >= MAX_ATTEMPTS:
                raise exhausted_flow() from None
            raise
        except Exception:
            if flow.attempts >= MAX_ATTEMPTS:
                raise exhausted_flow() from None
            raise LoginFlowError("少年梦登录请求失败，请稍后重试") from None
        finally:
            with self.lock:
                if flow.status == "pending" and flow.attempts >= MAX_ATTEMPTS:
                    flow.status = "failed"
                    flow.cookies.clear()
                    flow.challenge = ""
                flow.busy = False


ACCOUNTS = ShaonianDreamAccounts()
