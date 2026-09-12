"""Metadata overlays must survive hydration without replacing source metadata."""

import json

import httpx
import pytest

from app import db, main
from app.maintenance import MaintenanceGate
from app.models import BookRecord


@pytest.mark.asyncio
async def test_metadata_is_consistent_in_library_detail_and_exports(monkeypatch, tmp_path):
    monkeypatch.setenv("QINGJUAN_MULTI_USER", "0")
    monkeypatch.setenv("QINGJUAN_TRUST_LOCAL_ADMIN", "1")
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "qingjuan.db")
    monkeypatch.setattr(db, "_DATA_DIR_READY", True)
    monkeypatch.setattr(db, "_SITE_PLUGIN_STATE_CACHE", None)
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "LIBRARY_ROOT", tmp_path / "library")
    monkeypatch.setattr(main, "EXPORT_ROOT", tmp_path / "exports")
    monkeypatch.setattr(main.app.state, "maintenance_gate", MaintenanceGate())
    db.init_db()
    book_dir = tmp_path / "library" / "book-metadata"
    book_dir.mkdir(parents=True)
    (book_dir / "chapter.txt").write_text("完整正文", encoding="utf-8")
    source = {"title": "原书名", "author": "原作者", "synopsis": "原简介",
              "chapters": [{"index": 1, "title": "第一章", "file_name": "chapter.txt", "downloaded": True}]}
    db.save_book(BookRecord(id="book-metadata", title="原书名", sourceUrl="", bookKind="长小说",
                           language="中文", status="已下载", chapterCount=1, translated=False,
                           localPath="library/book-metadata", synopsis="原简介"))
    main.save_manifest(book_dir, source)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=main.app), base_url="http://127.0.0.1") as client:
        prefix = "/api/v1/books/book-metadata"
        response = await client.patch(f"{prefix}/metadata", json={
            "expectedRevision": 0, "title": "我的书名", "author": "我的作者", "synopsis": "我的简介",
            "tags": ["悬疑"], "groupName": "收藏", "pinned": True, "readingState": "finished",
        })
        assert response.status_code == 200, response.text
        assert response.json()["revision"] == 1
        for _ in range(2):
            detail = (await client.get(prefix)).json()
            books = (await client.get("/api/v1/books")).json()
            assert detail["title"] == detail["book"]["title"] == books[0]["title"] == "我的书名"
            assert detail["author"] == books[0]["author"] == "我的作者"
            assert detail["synopsis"] == "我的简介"
            assert detail["book"]["pinned"] is True
        exported = await client.post(f"{prefix}/export", json={"format": "txt"})
        assert exported.status_code == 200, exported.text
        assert "我的书名" in exported.json()["fileName"]
        artifact = await client.get("/api/v1" + exported.json()["downloadUrl"])
        assert "我的书名" in artifact.text and "我的作者" in artifact.text and "完整正文" in artifact.text
        assert db.get_book("book-metadata").title == "原书名"
        stored = json.loads((book_dir / "manifest.json").read_text("utf-8"))
        assert stored["title"] == "原书名" and stored["author"] == "原作者" and stored["synopsis"] == "原简介"
        reset = await client.patch(f"{prefix}/metadata", json={
            "expectedRevision": 1, "title": None, "author": None, "synopsis": None,
        })
        assert reset.status_code == 200
        assert reset.json()["title"] == "原书名"
        assert reset.json()["groupName"] == "收藏" and reset.json()["pinned"] is True
