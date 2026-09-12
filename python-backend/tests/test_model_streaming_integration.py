from __future__ import annotations

import json

import httpx
import pytest

from app import scraper
from app.models import MangaOcrRegion, OpenAICompatibleConfig, TranslationSettings
from app.translation_model_health import probe_translation_model

MODEL_URL = "https://models.example.test/v1/chat/completions"
TEST_KEY = "streaming-integration-secret"


def chunk(delta=None, *, finish=None, usage=None):
    value = {
        "id": "chat-test",
        "object": "chat.completion.chunk",
        "model": "test-model",
        "choices": [{"index": 0, "delta": delta or {}, "finish_reason": finish}],
    }
    if usage is not None:
        value["choices"] = []
        value["usage"] = usage
    return value


def sse(*events, done=True):
    body = ": keepalive\r\n\r\n"
    for event in events:
        body += "data: " + json.dumps(event, ensure_ascii=False) + "\r\n\r\n"
    if done:
        body += "data: [DONE]\r\n\r\n"
    return body.encode()


class SplitBytes(httpx.AsyncByteStream):
    """Split UTF-8 characters and SSE delimiters across network reads."""

    def __init__(self, body):
        self.body = body

    async def __aiter__(self):
        for offset in range(0, len(self.body), 7):
            yield self.body[offset : offset + 7]


def response(body):
    return httpx.Response(
        200,
        headers={"content-type": "text/event-stream; charset=utf-8"},
        stream=SplitBytes(body),
    )


def client_for(responses, requests):
    results = iter(responses)

    def handler(request):
        requests.append(json.loads(request.content))
        assert request.url == MODEL_URL
        assert request.headers["Authorization"] == f"Bearer {TEST_KEY}"
        assert request.headers["Accept"] == "application/json"
        return response(next(results))

    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


def settings():
    return TranslationSettings(
        translationModel=OpenAICompatibleConfig(
            enabled=True,
            baseUrl="https://models.example.test/v1",
            apiKey=TEST_KEY,
            model="test-model",
        )
    )


@pytest.mark.asyncio
async def test_translation_helper_reassembles_chinese_sse_and_does_not_mutate_payload():
    requests = []
    payload = {
        "model": "test-model",
        "messages": [],
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    body = sse(
        chunk({"role": "assistant", "content": ""}),
        chunk({"content": "你好，"}),
        chunk({"content": "世界。\n第二行"}),
        chunk(finish="stop"),
    )
    async with client_for([body], requests) as client:
        result = await scraper._post_translation_completion_text(
            client,
            MODEL_URL,
            headers={"Authorization": f"Bearer {TEST_KEY}"},
            payload=payload,
            feature_name="测试翻译模型",
        )
    assert result == "你好，世界。\n第二行"
    assert requests[0]["stream"] is False
    assert "stream_options" not in requests[0]
    assert payload == {
        "model": "test-model",
        "messages": [],
        "stream": True,
        "stream_options": {"include_usage": True},
    }


@pytest.mark.asyncio
async def test_shared_translation_response_preserves_usage_and_separates_reasoning(monkeypatch):
    from app import translation_quality_usage

    usage = {"prompt_tokens": 12, "completion_tokens": 8, "total_tokens": 20}
    recorded = []
    monkeypatch.setattr(
        translation_quality_usage,
        "record_model_usage",
        lambda model, decoded, status, elapsed: recorded.append((decoded, status)),
    )
    requests = []
    body = sse(
        chunk({"reasoning_content": "思考过程"}),
        chunk({"content": "正式"}),
        chunk({"content": "译文"}),
        chunk(finish="stop"),
        chunk(usage=usage),
    )
    async with client_for([body], requests) as client:
        result = await scraper._post_translation_json(
            client,
            MODEL_URL,
            headers={"Authorization": f"Bearer {TEST_KEY}"},
            payload={"model": "test-model", "messages": []},
        )
    assert result["choices"][0]["message"]["content"] == "正式译文"
    assert result["choices"][0]["message"]["reasoning_content"] == "思考过程"
    assert result["choices"][0]["finish_reason"] == "stop"
    assert result["usage"] == usage
    assert recorded == [(result, "completed")]


@pytest.mark.asyncio
async def test_manga_region_translation_consumes_json_split_across_sse_chunks(monkeypatch):
    requests = []
    text = json.dumps({"translations": [{"order": 1, "translation": "你好"}]}, ensure_ascii=False)
    body = sse(
        *(chunk({"content": text[offset : offset + 3]}) for offset in range(0, len(text), 3)),
        chunk(finish="stop"),
    )
    monkeypatch.setattr(scraper, "_create_model_http_client", lambda **_: client_for([body], requests))
    result = await scraper._translate_manga_region_batch(
        settings=settings(),
        base_url="https://models.example.test/v1",
        api_key=TEST_KEY,
        model="test-model",
        target_language="中文",
        chapter_title="测试漫画",
        chapter_index=1,
        page_number=1,
        total_pages=1,
        regions=[MangaOcrRegion(order=1, bbox=(10, 10, 500, 200), source_text="こんにちは")],
        timeout_seconds=2,
    )
    assert result[0].translation == "你好"
    assert requests[0]["stream"] is False


@pytest.mark.asyncio
async def test_model_selfcheck_accepts_complete_sse_and_requests_non_streaming():
    requests = []
    async with client_for(
        [sse(chunk({"content": "O"}), chunk({"content": "K"}), chunk(finish="stop"))], requests
    ) as client:
        result = await probe_translation_model(settings(), client=client)
    assert result.available is True
    assert result.status == "ready"
    assert requests[0]["stream"] is False


@pytest.mark.asyncio
async def test_reasoning_only_length_stream_retains_existing_budget_retry():
    requests = []
    payload = {"model": "test-model", "messages": [], "max_tokens": 5}
    responses = [
        sse(chunk({"reasoning_content": "先思考"}), chunk(finish="length")),
        sse(chunk({"content": "完整译文"}), chunk(finish="stop")),
    ]
    async with client_for(responses, requests) as client:
        result = await scraper._post_translation_completion_text(
            client,
            MODEL_URL,
            headers={"Authorization": f"Bearer {TEST_KEY}"},
            payload=payload,
            feature_name="测试翻译模型",
        )
    assert result == "完整译文"
    assert len(requests) == 2
    assert requests[0]["max_tokens"] == 5
    assert requests[1]["max_tokens"] >= 8000
    assert all(request["stream"] is False for request in requests)
    assert payload == {"model": "test-model", "messages": [], "max_tokens": 5}


BROKEN_STREAMS = [
    sse(
        chunk({"content": "不应采用的半截译文"}), {"error": {"message": f"Provider failed Bearer {TEST_KEY}"}}
    ),
    sse(chunk({"content": "不应采用的半截译文"}), done=False),
    b'data: {"choices": [\r\n\r\ndata: [DONE]\r\n\r\n',
]


@pytest.mark.asyncio
@pytest.mark.parametrize("body", BROKEN_STREAMS, ids=["late-error", "truncated", "malformed"])
async def test_broken_translation_stream_fails_without_returning_partial_text_or_secrets(body):
    requests = []
    async with client_for([body], requests) as client:
        with pytest.raises(ValueError) as error:
            await scraper._post_translation_completion_text(
                client,
                MODEL_URL,
                headers={"Authorization": f"Bearer {TEST_KEY}"},
                payload={"model": "test-model", "messages": []},
                feature_name="测试翻译模型",
            )
    assert len(requests) == 1
    assert TEST_KEY not in str(error.value)
    assert "不应采用的半截译文" not in str(error.value)


@pytest.mark.asyncio
@pytest.mark.parametrize("body", BROKEN_STREAMS[:2], ids=["late-error", "truncated"])
async def test_broken_stream_cannot_report_selfcheck_ready(body, caplog):
    requests = []
    async with client_for([body], requests) as client:
        result = await probe_translation_model(settings(), client=client)
    assert result.available is False
    assert result.status == "failed"
    assert TEST_KEY not in result.model_dump_json()
    assert "不应采用的半截译文" not in result.model_dump_json()
    assert TEST_KEY not in caplog.text


@pytest.mark.asyncio
async def test_filtered_partial_stream_is_neither_translation_success_nor_model_ready():
    body = sse(chunk({"content": "仅生成了一部分"}), chunk(finish="content_filter"))
    requests = []
    async with client_for([body], requests) as client:
        with pytest.raises(ValueError):
            await scraper._post_translation_completion_text(
                client,
                MODEL_URL,
                headers={"Authorization": f"Bearer {TEST_KEY}"},
                payload={"model": "test-model", "messages": []},
                feature_name="测试翻译模型",
            )
    async with client_for([body], requests) as client:
        result = await probe_translation_model(settings(), client=client)
    assert result.available is False
    assert result.status == "failed"
    assert "仅生成了一部分" not in result.model_dump_json()


@pytest.mark.asyncio
async def test_external_ocr_payload_remains_unchanged_by_chat_stream_preference():
    payload = {"file": "image-data", "fileType": 1, "returnWordBox": True}
    captured = []

    def handler(request):
        captured.append(json.loads(request.content))
        return httpx.Response(200, json={"result": {"ocrResults": []}})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await scraper._post_translation_json(
            client, "https://ocr.example.test/ocr", headers={}, payload=payload
        )
    assert result == {"result": {"ocrResults": []}}
    assert captured == [payload]
    assert "stream" not in payload
