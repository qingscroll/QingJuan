from __future__ import annotations

import json
import os
import subprocess
import sys
from urllib.parse import parse_qs, urlencode

import httpx
import pytest
from fastapi.testclient import TestClient

from app.api import shaoniandream_account as routes
from app.application import create_application
from app.site_plugins import shaoniandream_account as account


def test_windows_local_mode_keeps_login_page_without_admin_web():
    script = """
from fastapi.testclient import TestClient
from app.main import app
client = TestClient(app)
response = client.get('/site-login/shaoniandream')
assert response.status_code == 200, response.status_code
assert response.headers['cache-control'] == 'no-store'
assert client.get('/admin/').status_code == 404
assert not any(route.path.startswith('/admin/') for route in app.routes)
"""
    result = subprocess.run(
        [sys.executable, "-c", script],
        env={**os.environ, "QINGJUAN_DISABLE_ADMIN_WEB": "1"},
        check=False,
        capture_output=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stderr.decode("utf-8", "replace")


@pytest.fixture
def login_api(monkeypatch):
    accounts = account.ShaonianDreamAccounts()
    calls = []

    def upstream(request):
        if request.url.path == "/author/startcaptchaservlet":
            return httpx.Response(
                200,
                json={"gt": "test-gt", "challenge": "test-challenge", "success": 1, "new_captcha": 1},
                headers={"set-cookie": "PHPSESSID=captcha; Path=/"},
            )
        calls.append(parse_qs(request.content.decode()))
        assert "PHPSESSID=captcha" in request.headers["cookie"]
        if calls[-1]["password"] == ["wrong"]:
            return httpx.Response(200, json={"status": 2, "msg": "untrusted-private-message"})
        return httpx.Response(200, json={"status": 1}, headers={"set-cookie": "auth=private; Path=/"})

    monkeypatch.setattr(account, "ACCOUNTS", accounts)
    monkeypatch.setattr(routes, "list_site_plugin_enabled_states", lambda: {})
    monkeypatch.setattr(
        account,
        "create_public_http_client",
        lambda **kw: httpx.AsyncClient(transport=httpx.MockTransport(upstream), **kw),
    )
    application = create_application(routers=[], public_routers=[routes.public_router])
    with TestClient(application) as client:
        flow = accounts.runtime("alice").start_login()
        headers = {"X-Login-Token": flow["browserToken"]}
        assert client.get("/site-login/shaoniandream/geetest", headers=headers).status_code == 200
        yield client, headers, accounts, flow, calls


def credentials():
    return {
        "username": "读者+name@example.com",
        "password": " 密码+&=秘密 ",
        "geetest_challenge": "test-challenge",
        "geetest_validate": "verified",
        "geetest_seccode": "verified|jordan",
        "auto_login": 0,
    }


@pytest.mark.parametrize("encoding", ["json", "form", "bare-json", "no-content-type"])
def test_updated_login_encodings_preserve_credentials(login_api, encoding):
    client, headers, accounts, flow, calls = login_api
    payload = credentials()
    body = json.dumps(payload, ensure_ascii=False).encode()
    if encoding == "form":
        body = urlencode(payload).encode()
    if encoding != "no-content-type":
        headers["Content-Type"] = (
            "application/json" if encoding == "json" else "application/x-www-form-urlencoded"
        )
    response = client.post("/site-login/shaoniandream/login", headers=headers, content=body)
    assert response.status_code == 200
    assert response.json() == {"loggedIn": True}
    assert response.headers["cache-control"] == "no-store"
    assert calls[-1]["password"] == [payload["password"]]
    assert calls[-1]["username"] == [payload["username"]]
    assert calls[-1]["autoLogin"] == ["0"]
    assert "auto_login" not in calls[-1]
    assert accounts.runtime("alice").poll_login(flow["flowId"])["loggedIn"] is True
    assert accounts.runtime("bob").cookies() == {}


@pytest.mark.parametrize(
    ("body", "content_type", "status"),
    [
        (b'{"password":"secret-marker",', "application/json", 422),
        (b'{"password":"secret-marker",', "application/x-www-form-urlencoded", 422),
        (b'{"password":"secret-marker"}', "application/json", 422),
        (b'{"username":{},"password":{"secret-marker":1}}', "application/json", 422),
        (b'{"secret-marker":true}', "application/json", 422),
        (b'["secret-marker"]', "application/json", 422),
        (b"username=secret-marker&username=other", "application/x-www-form-urlencoded", 422),
        (b'{"password":"secret-marker","password":"other"}', "application/json", 422),
        (b"password=%FFsecret-marker", "application/x-www-form-urlencoded", 422),
        (b"\xffsecret-marker", "application/json", 422),
        (b"secret-marker", "application/octet-stream", 415),
        (b"secret-marker" * 1600, "application/json", 413),
    ],
)
def test_bad_requests_have_safe_structured_errors(login_api, body, content_type, status):
    client, headers, _, _, calls = login_api
    response = client.post(
        "/site-login/shaoniandream/login",
        content=body,
        headers={**headers, "Content-Type": content_type},
    )
    assert response.status_code == status
    detail = response.json()["detail"]
    assert detail["status"] == 0
    assert detail["code"] and detail["msg"] and detail["hint"]
    assert "secret-marker" not in response.text
    assert '"input"' not in response.text
    assert response.headers["cache-control"] == "no-store"
    assert not calls


def test_failed_login_retries_then_terminates_flow(login_api):
    client, headers, accounts, flow, calls = login_api
    payload = {**credentials(), "password": "wrong"}
    for attempt in range(5):
        if attempt:
            assert client.get("/site-login/shaoniandream/geetest", headers=headers).status_code == 200
        response = client.post("/site-login/shaoniandream/login", headers=headers, json=payload)
        assert response.status_code == (429 if attempt == 4 else 401)
        assert response.json()["detail"]["code"] == (
            "too_many_attempts" if attempt == 4 else "invalid_credentials"
        )
        assert "untrusted-private-message" not in response.text
    assert len(calls) == 5
    assert accounts.runtime("alice").poll_login(flow["flowId"])["status"] == "failed"
    response = client.get("/site-login/shaoniandream/geetest", headers=headers)
    assert response.status_code == 429
    assert response.json()["detail"]["code"] == "too_many_attempts"


def test_cancelled_flow_returns_actionable_error(login_api):
    client, headers, accounts, flow, _ = login_api
    accounts.runtime("alice").cancel_login(flow["flowId"])
    response = client.get("/site-login/shaoniandream/geetest", headers=headers)
    assert response.status_code == 401
    assert response.json()["detail"]["code"] == "session_revoked"
    assert response.json()["detail"]["hint"]
