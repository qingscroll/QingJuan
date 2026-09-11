from __future__ import annotations

import asyncio
import hashlib
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from app import main, scraper
from app.api.routers import plugins_router
from app.api.shaoniandream_account import public_router
from app.application import create_application
from app.site_plugins import shaoniandream_account as account


@pytest.fixture
def upstream(monkeypatch):
    calls = []

    def handle(request):
        calls.append(request)
        if request.url.path == "/author/startcaptchaservlet":
            return httpx.Response(
                200,
                json={"gt": "test-gt", "challenge": "test-challenge", "success": 1, "new_captcha": 1},
                headers={"set-cookie": "PHPSESSID=captcha; Path=/"},
            )
        assert request.url.path == "/user/loginaction"
        assert "PHPSESSID=captcha" in request.headers["cookie"]
        assert b"geetest_validate=verified" in request.content
        assert b"autoLogin=1" in request.content
        return httpx.Response(
            200,
            json={"status": 1, "data": {"id": "private-user"}},
            headers={"set-cookie": "auth=private-cookie; Path=/"},
        )

    monkeypatch.setattr(
        account,
        "create_public_http_client",
        lambda **kw: httpx.AsyncClient(transport=httpx.MockTransport(handle), **kw),
    )
    return calls


def credentials():
    return {
        "username": "reader",
        "password": "private-password",
        "geetest_challenge": "test-challenge",
        "geetest_validate": "verified",
        "geetest_seccode": "verified|jordan",
    }


@pytest.mark.asyncio
async def test_password_login_is_private_scoped_and_single_use(upstream):
    accounts = account.ShaonianDreamAccounts()
    runtime = accounts.runtime("alice")
    flow = runtime.start_login()
    token = flow["browserToken"]
    await accounts.geetest(token)
    await accounts.login(token, credentials())
    assert runtime.poll_login(flow["flowId"])["loggedIn"] is True
    assert accounts.runtime("bob").account_status()["loggedIn"] is False
    assert runtime.cookies()["auth"] == "private-cookie"
    assert "private" not in json.dumps(runtime.account_status())
    with pytest.raises(account.LoginFlowError):
        await accounts.login(token, credentials())
    runtime.logout()
    assert runtime.cookies() == {}


@pytest.mark.asyncio
async def test_cancel_and_expiry_prevent_late_login(upstream, monkeypatch):
    accounts = account.ShaonianDreamAccounts()
    runtime = accounts.runtime("alice")
    flow = runtime.start_login()
    await accounts.geetest(flow["browserToken"])
    runtime.cancel_login(flow["flowId"])
    with pytest.raises(account.LoginFlowError):
        await accounts.login(flow["browserToken"], credentials())
    flow = runtime.start_login()
    monkeypatch.setattr(account, "now", lambda: 10**12)
    assert runtime.poll_login(flow["flowId"])["status"] == "expired"
    with pytest.raises(account.LoginFlowError):
        await accounts.geetest(flow["browserToken"])


def test_browser_login_routes_and_secrets(upstream, monkeypatch):
    accounts = account.ShaonianDreamAccounts()
    monkeypatch.setattr(account, "ACCOUNTS", accounts)
    application = create_application(routers=[plugins_router], public_routers=[public_router])
    with TestClient(application) as client:
        response = client.post("/plugins/shaoniandream/account/login-browser")
        assert response.status_code == 200
        assert response.headers["cache-control"] == "no-store"
        flow = response.json()
        headers = {"X-Login-Token": flow["browserToken"]}
        assert client.get("/site-login/shaoniandream/geetest").status_code == 404
        assert client.get("/site-login/shaoniandream/geetest", headers=headers).status_code == 200
        login = client.post("/site-login/shaoniandream/login", headers=headers, json=credentials())
        assert login.status_code == 200
        assert "private" not in login.text
        status = client.get(f"/plugins/shaoniandream/account/login-browser/{flow['flowId']}")
        assert status.json()["loggedIn"] is True
        assert "private" not in status.text
        assert client.delete("/plugins/shaoniandream/account").json()["loggedIn"] is False


def test_shaoniandream_cookies_are_resolved_for_book_owner(monkeypatch):
    accounts = account.ShaonianDreamAccounts()
    monkeypatch.setattr(account, "ACCOUNTS", accounts)
    monkeypatch.setattr(accounts.runtime("alice"), "cookies", lambda: {"auth": "alice-cookie"})
    assert main._site_account_download_kwargs("alice", "https://www.shaoniandream.com/book_detail/1") == {
        "shaoniandream_cookies": {"auth": "alice-cookie"}
    }
    assert main._site_account_download_kwargs("bob", "https://www.shaoniandream.com/book_detail/1") == {
        "shaoniandream_cookies": {}
    }
    assert main._site_account_download_kwargs("alice", "https://example.com/book") == {}


@pytest.mark.asyncio
async def test_chapter_uses_isolated_authenticated_client(monkeypatch):
    async def chapter(client, chapter_id):
        assert chapter_id == "21"
        assert client.cookies.get("auth") == "private-cookie"
        return "完整章节正文"

    monkeypatch.setattr(scraper, "get_shaoniandream_chapter", chapter)
    monkeypatch.setattr(
        scraper, "_require_enabled_site_plugin", lambda _: main.get_site_plugin("shaoniandream")
    )
    monkeypatch.setattr(scraper, "_build_http_client", lambda: httpx.AsyncClient())
    async with httpx.AsyncClient() as shared:
        result = await scraper._fetch_chapter_data(
            shared,
            "https://www.shaoniandream.com/readchapter/21",
            shaoniandream_cookies={"auth": "private-cookie"},
        )
        assert result.text == "完整章节正文"
        assert result.authorization_method == "shaoniandream-web-session"
        assert not shared.cookies


@pytest.mark.asyncio
async def test_failed_login_does_not_leak_upstream_response_or_create_account(monkeypatch):
    def handle(request):
        if request.method == "GET":
            return httpx.Response(200, json={"gt": "gt", "challenge": "test-challenge"})
        return httpx.Response(200, json={"status": 0, "msg": "private-password private-cookie"})

    monkeypatch.setattr(
        account,
        "create_public_http_client",
        lambda **kw: httpx.AsyncClient(transport=httpx.MockTransport(handle), **kw),
    )
    accounts = account.ShaonianDreamAccounts()
    runtime = accounts.runtime("alice")
    flow = runtime.start_login()
    for _ in range(5):
        await accounts.geetest(flow["browserToken"])
        with pytest.raises(account.LoginFlowError) as caught:
            await accounts.login(flow["browserToken"], credentials())
        assert "private" not in str(caught.value)
    with pytest.raises(account.LoginFlowError):
        await accounts.geetest(flow["browserToken"])
    assert runtime.account_status()["loggedIn"] is False


@pytest.mark.asyncio
async def test_logout_during_upstream_login_prevents_session_resurrection(monkeypatch):
    entered = asyncio.Event()
    release = asyncio.Event()

    async def handle(request):
        if request.method == "GET":
            return httpx.Response(200, json={"gt": "gt", "challenge": "test-challenge"})
        entered.set()
        await release.wait()
        return httpx.Response(200, json={"status": 1}, headers={"set-cookie": "auth=private; Path=/"})

    monkeypatch.setattr(
        account,
        "create_public_http_client",
        lambda **kw: httpx.AsyncClient(transport=httpx.MockTransport(handle), **kw),
    )
    accounts = account.ShaonianDreamAccounts()
    runtime = accounts.runtime("alice")
    flow = runtime.start_login()
    await accounts.geetest(flow["browserToken"])
    task = asyncio.create_task(accounts.login(flow["browserToken"], credentials()))
    await entered.wait()
    runtime.logout()
    release.set()
    with pytest.raises(account.LoginFlowError):
        await task
    assert runtime.cookies() == {}


def test_production_auth_boundary_and_validation_redaction(monkeypatch):
    monkeypatch.setenv("QINGJUAN_AUTH_TOKEN_SHA256", hashlib.sha256(b"connection-secret").hexdigest())
    application = create_application(
        routers=[plugins_router], public_routers=[public_router], authenticate=True
    )
    with TestClient(application) as client:
        assert client.post("/api/v1/plugins/shaoniandream/account/login-browser").status_code == 401
        page = client.get("/site-login/shaoniandream")
        assert page.status_code == 200
        assert page.headers["referrer-policy"] == "no-referrer"
        assert "frame-ancestors 'none'" in page.headers["content-security-policy"]
        assert client.get("/site-login/shaoniandream/geetest").status_code == 404
        bad = client.post("/site-login/shaoniandream/login", json={"password": "private-password"})
        assert bad.status_code == 422
        assert "private-password" not in bad.text
        assert bad.headers["cache-control"] == "no-store"


def test_disabled_plugin_cannot_start_or_complete_browser_login(monkeypatch):
    from app.api import shaoniandream_account as routes

    monkeypatch.setattr(routes, "list_site_plugin_enabled_states", lambda: {"shaoniandream": False})
    application = create_application(routers=[plugins_router], public_routers=[public_router])
    with TestClient(application) as client:
        assert client.post("/plugins/shaoniandream/account/login-browser").status_code == 409
        assert (
            client.post(
                "/site-login/shaoniandream/login", json=credentials(), headers={"X-Login-Token": "a" * 43}
            ).status_code
            == 409
        )
