from __future__ import annotations

import asyncio
import json

import httpx
import pytest
import test_translation_quality as base

from app import db, scraper
from app.translation_quality_models import GlossaryPatch, RetranslateSelection, TranslationQualityError
from app.translation_quality_retranslate import retranslate
from app.translation_quality_service import get_chapter, save_chapter, save_glossary
from app.translation_quality_usage import list_usage

quality_book = base.quality_book


def payload(book, operation="test-operation-one"):
    current = get_chapter(book, 1)
    return RetranslateSelection(
        expectedRevision=current.revision,
        sourceHash=current.sourceHash,
        translationHash=current.translationHash,
        operationId=operation,
        sourceStart=0,
        sourceEnd=12,
    )


def mock_model(monkeypatch, handler):
    monkeypatch.setattr(
        scraper,
        "_resolve_openai_compatible_model_config",
        lambda *args, **kwargs: ("https://model.example.test/v1", "private-provider-key", "test-model"),
    )
    monkeypatch.setattr(
        scraper,
        "_create_model_http_client",
        lambda **kwargs: httpx.AsyncClient(transport=httpx.MockTransport(handler)),
    )


@pytest.mark.asyncio
async def test_explicit_selection_uses_glossary_single_request_and_records_usage_without_applying(
    quality_book, monkeypatch
):
    book, _ = quality_book
    requests = []
    before = get_chapter(book, 1)
    save_glossary(
        book,
        GlossaryPatch(expectedRevision=0, entries=[{"source": "Alice", "target": "艾丽丝", "kind": "name"}]),
    )

    def handler(request):
        requests.append(json.loads(request.content))
        return httpx.Response(
            200,
            json={
                "choices": [{"message": {"content": "你好，艾丽丝。"}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 50, "completion_tokens": 10, "total_tokens": 60},
                "secret": "private-provider-data",
            },
        )

    mock_model(monkeypatch, handler)
    request = payload(book)
    result = await retranslate(book, 1, request)
    replay = await retranslate(book, 1, request)
    assert result == replay
    assert len(requests) == 1
    assert requests[0]["max_tokens"] == 8000
    assert "艾丽丝" in requests[0]["messages"][1]["content"]
    assert get_chapter(book, 1) == before
    assert result.usage.totalTokens == 60
    usage = list_usage(book)
    assert len(usage) == 1
    assert usage[0].model == "test-model"
    assert "private" not in usage[0].model_dump_json()


@pytest.mark.asyncio
async def test_provider_failure_is_not_retried_or_exposed_and_same_operation_cannot_bill_again(
    quality_book, monkeypatch
):
    book, _ = quality_book
    calls = 0

    def failed(request):
        nonlocal calls
        calls += 1
        return httpx.Response(503, json={"error": {"message": "private-provider-key /private/path"}})

    mock_model(monkeypatch, failed)
    request = payload(book)
    for _ in range(2):
        with pytest.raises(TranslationQualityError) as error:
            await retranslate(book, 1, request)
        assert "private" not in str(error.value)
    assert calls == 1
    assert list_usage(book)[0].inputTokens is None
    assert list_usage(book)[0].status == "failed"


@pytest.mark.asyncio
async def test_paid_suggestion_is_rejected_if_translation_changes_while_model_runs(quality_book, monkeypatch):
    book, _ = quality_book
    entered, release = asyncio.Event(), asyncio.Event()

    async def handler(request):
        entered.set()
        await release.wait()
        return httpx.Response(200, json={"choices": [{"message": {"content": "迟到的译文"}}]})

    mock_model(monkeypatch, handler)
    pending = asyncio.create_task(retranslate(book, 1, payload(book)))
    await entered.wait()
    before = get_chapter(book, 1)
    save_chapter(book, 1, base.edit(before, "用户刚保存的译文"))
    with pytest.raises(TranslationQualityError) as error:
        await retranslate(book, 1, payload(book, "parallel-request"))
    assert error.value.status_code == 409
    release.set()
    with pytest.raises(TranslationQualityError) as error:
        await pending
    assert error.value.status_code == 409
    assert get_chapter(book, 1).translatedText == "用户刚保存的译文"


@pytest.mark.asyncio
async def test_invalid_selection_does_not_call_provider_and_cancelled_call_is_closed(
    quality_book, monkeypatch
):
    book, _ = quality_book
    entered = asyncio.Event()

    async def handler(request):
        entered.set()
        await asyncio.Event().wait()

    mock_model(monkeypatch, handler)
    with pytest.raises(TranslationQualityError):
        await retranslate(book, 1, payload(book).model_copy(update={"sourceEnd": 99999}))
    assert not entered.is_set()
    pending = asyncio.create_task(retranslate(book, 1, payload(book)))
    await entered.wait()
    pending.cancel()
    with pytest.raises(asyncio.CancelledError):
        await pending
    assert list_usage(book)[0].status == "cancelled"
    with db.get_connection() as conn:
        assert conn.execute("SELECT status FROM translation_quality_requests").fetchone()[0] == "failed"
