import json

import pytest

from app import manifest_storage


def test_failed_manifest_replacement_preserves_old_chapters(monkeypatch, tmp_path):
    original = {"chapters": [{"index": 1, "downloaded": True, "title": "已下载"}]}
    manifest_storage.save_manifest(tmp_path, original)

    def fail_replace(source, target):
        assert json.loads(source.read_text("utf-8"))["chapters"] == []
        assert json.loads(target.read_text("utf-8")) == original
        raise OSError("simulated disk error")

    monkeypatch.setattr(manifest_storage, "replace", fail_replace)
    with pytest.raises(OSError):
        manifest_storage.save_manifest(tmp_path, {"chapters": []})
    assert json.loads((tmp_path / "manifest.json").read_text("utf-8")) == original
    assert [path.name for path in tmp_path.iterdir()] == ["manifest.json"]


def test_successful_manifest_save_is_valid_utf8_json(tmp_path):
    manifest_storage.save_manifest(tmp_path, {"chapters": [], "title": "小说"})
    manifest_storage.save_manifest(tmp_path, {"chapters": [{"index": 1}], "title": "小说"})
    assert json.loads((tmp_path / "manifest.json").read_text("utf-8")) == {
        "chapters": [{"index": 1}], "title": "小说",
    }
