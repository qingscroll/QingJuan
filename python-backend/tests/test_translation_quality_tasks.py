from __future__ import annotations

import json

import httpx
import pytest
import test_translation_quality as base

from app import db, scraper
from app.translation_quality_models import GlossaryPatch
from app.translation_quality_service import get_chapter, save_glossary
from app.translation_quality_usage import list_usage

quality_book = base.quality_book


@pytest.mark.asyncio
async def test_regular_novel_translation_uses_glossary_and_preserves_previous_version(
    quality_book, monkeypatch
):
    book, directory = quality_book
    original = get_chapter(book, 1)
    save_glossary(
        book,
        GlossaryPatch(expectedRevision=0, entries=[{"source": "Alice", "target": "艾丽丝", "kind": "name"}]),
    )
    requests = []

    def handler(request):
        requests.append(json.loads(request.content))
        return httpx.Response(
            200,
            json={
                "choices": [{"message": {"content": "普通任务的新译文"}}],
                "usage": {"prompt_tokens": 11, "completion_tokens": 9, "total_tokens": 20},
            },
        )

    monkeypatch.setattr(
        scraper,
        "_resolve_openai_compatible_model_config",
        lambda *args, **kwargs: ("https://model.example.test/v1", "private-key", "model-name"),
    )
    monkeypatch.setattr(
        scraper,
        "_create_model_http_client",
        lambda **kwargs: httpx.AsyncClient(transport=httpx.MockTransport(handler)),
    )
    await scraper.translate_selected_chapters(
        directory, scraper.load_manifest(directory), [1], book.language, db.load_settings()
    )
    result = get_chapter(book, 1)
    assert result.translatedText == "普通任务的新译文"
    assert result.history[0].kind == "translate"
    assert result.history[-1].translationHash == original.translationHash
    assert "艾丽丝" in requests[0]["messages"][1]["content"]
    assert list_usage(book)[0].totalTokens == 20
    assert list_usage(book)[0].operation == "translate"


@pytest.mark.asyncio
async def test_truncated_model_output_is_not_saved(quality_book, monkeypatch):
    from test_translation_quality_retranslate import mock_model, payload

    from app.translation_quality_models import TranslationQualityError
    from app.translation_quality_retranslate import retranslate

    book, _ = quality_book
    before = get_chapter(book, 1)
    mock_model(
        monkeypatch,
        lambda request: httpx.Response(
            200, json={"choices": [{"message": {"content": "不完整的内容"}, "finish_reason": "length"}]}
        ),
    )
    with pytest.raises(TranslationQualityError) as error:
        await retranslate(book, 1, payload(book))
    assert error.value.status_code == 502
    assert get_chapter(book, 1) == before
