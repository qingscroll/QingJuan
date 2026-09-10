from __future__ import annotations

import asyncio
from io import BytesIO
from types import SimpleNamespace

import httpx
import pytest
from PIL import Image
from pydantic import ValidationError

from app import main, scraper
from app.api.routers import library_router
from app.application import create_application
from app.link_jobs import LinkJobStore
from app.models import AddBookPayload
from app.security import API_PREFIX


@pytest.mark.parametrize("source", [{"albumId": " 00123456 "}, {"albumId": 123456}, {"sourceUrl": "123456"}])
def test_number_input_normalizes_to_manga(source):
    payload = AddBookPayload.model_validate(source)
    assert payload.albumId == "123456"
    assert str(payload.sourceUrl) == "https://18comic.vip/album/123456/"
    assert payload.bookKind == "漫画"
    assert payload.language == "中文"
    assert payload.downloadMode == "all"
    assert AddBookPayload.model_validate(payload.model_dump(mode="json")) == payload


@pytest.mark.parametrize("album_id", ["", "0", "000", "-1", "12.3", "12/34", "１２３", True, [], 1.5])
def test_invalid_album_id_is_rejected(album_id):
    with pytest.raises(ValidationError, match="本子号必须为正整数"):
        AddBookPayload.model_validate({"albumId": album_id})


@pytest.mark.parametrize(
    "source",
    [
        "https://example.com/album/123456/",
        "https://18comic.vip/album/654321/",
        "https://18comic.vip/photo/123456/",
        "https://18comic.vip.evil.test/album/123456/",
    ],
)
def test_conflicting_or_untrusted_url_is_rejected(source):
    with pytest.raises(ValidationError, match="必须指向同一本"):
        AddBookPayload.model_validate({"albumId": "123456", "sourceUrl": source})


def test_number_input_cannot_override_the_builtin_parser():
    with pytest.raises(ValidationError, match="请勿同时指定 sourceId"):
        AddBookPayload.model_validate({"albumId": "123456", "sourceId": "some-rule"})
    existing = AddBookPayload(sourceUrl="https://example.com/book/1", bookKind="长小说", language="日文")
    assert existing.albumId is None
    assert existing.bookKind == "长小说"
    assert existing.language == "日文"


@pytest.fixture
def jm_api(monkeypatch):
    calls = []

    def album_detail(album_id):
        calls.append(("album", album_id))
        return SimpleNamespace(
            title="测试漫画",
            description="合成测试数据",
            authors=["测试作者"],
            episode_list=[("234561", "1", "第一话"), ("234562", "2", "第二话")],
        )

    def photo_detail(photo_id):
        calls.append(("photo", photo_id))
        return [
            SimpleNamespace(download_url=f"https://images.example.test/media/photos/{photo_id}/{page}.png")
            for page in (1, 2)
        ]

    def no_html(*args, **kwargs):
        raise AssertionError("Successful JM API requests must not use HTML")

    monkeypatch.setattr(
        scraper,
        "_jm_client",
        lambda: SimpleNamespace(get_album_detail=album_detail, get_photo_detail=photo_detail),
    )
    monkeypatch.setattr(
        scraper, "_jm_cover_url", lambda album_id: f"https://images.example.test/{album_id}.png"
    )
    monkeypatch.setattr(scraper, "_sync_fetch_18comic_html", no_html)
    monkeypatch.setattr(scraper, "is_site_plugin_enabled", lambda _: True)
    return calls


@pytest.mark.asyncio
async def test_number_preview_and_background_api_use_album_not_photo_id(monkeypatch, jm_api):
    store = LinkJobStore()
    monkeypatch.setattr(main, "LINK_JOB_STORE", store)
    monkeypatch.setattr(main.app.state, "link_job_tasks", set(), raising=False)
    application = create_application(routers=[library_router], api_prefix=API_PREFIX)
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=application), base_url="http://testserver"
    ) as client:
        invalid = await client.post(f"{API_PREFIX}/books/preview", json={"albumId": "not-an-id"})
        assert invalid.status_code == 422
        assert jm_api == []
        response = await client.post(f"{API_PREFIX}/books/preview", json={"albumId": "123456"})
        assert response.status_code == 200
        preview = response.json()
        assert preview["bookKind"] == "漫画"
        assert preview["chapterCount"] == 2
        assert preview["chapters"][0]["url"] == "https://18comic.vip/photo/234561/"
        started = await client.post(
            f"{API_PREFIX}/books/link-jobs", json={"mode": "preview", "payload": {"albumId": "123456"}}
        )
        assert started.status_code == 200
        await asyncio.gather(*main.app.state.link_job_tasks)
        job = await client.get(f"{API_PREFIX}/books/link-jobs/{started.json()['id']}")
        assert job.json()["status"] == "completed"
        assert job.json()["preview"]["chapterCount"] == 2
    assert jm_api == [("album", "123456"), ("album", "123456")]


@pytest.mark.asyncio
async def test_number_import_downloads_all_episode_images(tmp_path, monkeypatch, jm_api):
    payload = AddBookPayload.model_validate({"albumId": "123456"})
    preview = await scraper.preview_from_url(payload)
    buffer = BytesIO()
    Image.new("RGB", (16, 16), "white").save(buffer, format="PNG")
    downloads = []

    def fake_binary(url, referer):
        downloads.append((url, referer))
        return buffer.getvalue()

    monkeypatch.setattr(scraper, "_sync_fetch_18comic_binary", fake_binary)
    result = await scraper.download_book(payload, preview, tmp_path)
    manifest = scraper.load_manifest(result.local_path)
    assert manifest["book_kind"] == "漫画"
    assert manifest["source_url"] == "https://18comic.vip/album/123456/"
    assert manifest["chapter_count"] == 2
    assert jm_api == [("album", "123456"), ("photo", "234561"), ("photo", "234562")]
    for chapter in manifest["chapters"]:
        assert chapter["downloaded"] is True
        assert chapter["images_repaired"] is True
        assert chapter["page_count"] == 2
        assert len(chapter["image_files"]) == 2
        assert all((result.local_path / path).is_file() for path in chapter["image_files"])
    assert len(downloads) == 5  # Cover plus both pages of each episode.
    assert {referer for _, referer in downloads} == {
        str(payload.sourceUrl),
        "https://18comic.vip/photo/234561/",
        "https://18comic.vip/photo/234562/",
    }


@pytest.mark.asyncio
async def test_number_entry_respects_disabled_plugin(monkeypatch, jm_api):
    monkeypatch.setattr(scraper, "is_site_plugin_enabled", lambda _: False)
    with pytest.raises(ValueError, match="已停用"):
        await scraper.preview_from_url(AddBookPayload.model_validate({"albumId": "123456"}))
    assert jm_api == []
