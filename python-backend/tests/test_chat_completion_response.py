import json

import httpx
import pytest

from app.chat_completion_response import CompletionStreamError, decode_chat_completion_response


def chunk(delta=None, *, index=0, finish=None, **extra):
    return {
        "object": "chat.completion.chunk",
        "choices": [{"index": index, "delta": delta or {}, "finish_reason": finish}],
        **extra,
    }


def event(value):
    return "data: " + (value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)) + "\n\n"


def response(body, content_type="text/event-stream"):
    return httpx.Response(200, content=body.encode("utf-8"), headers={"Content-Type": content_type})


@pytest.mark.parametrize("value", [{"choices": []}, [1], "data: ordinary JSON", None, 5])
def test_ordinary_json_keeps_response_json_behavior_even_with_stream_header(value):
    assert decode_chat_completion_response(response(json.dumps(value), "application/json")) == value
    assert decode_chat_completion_response(response(json.dumps(value))) == value


@pytest.mark.parametrize("newline", ["\n", "\r\n", "\r"])
@pytest.mark.parametrize("content_type", ["text/event-stream; charset=utf-8", "application/octet-stream"])
def test_decodes_bom_multiline_events_heartbeats_and_all_sse_line_endings(newline, content_type):
    body = "\ufeff: heartbeat\n\nevent: message\nid: 1\nretry: 1000\n"
    pretty = json.dumps(
        chunk({"role": "assistant", "content": "你好"}, id="chat-1"), ensure_ascii=False, indent=2
    )
    body += "\n".join("data: " + line for line in pretty.splitlines()) + "\n\n"
    body += event(chunk({"content": "世界"}, finish="stop")) + event("[DONE]") + ": done heartbeat\n"
    result = decode_chat_completion_response(response(body.replace("\n", newline), content_type))
    assert result["id"] == "chat-1" and result["object"] == "chat.completion"
    assert result["choices"] == [
        {"index": 0, "message": {"role": "assistant", "content": "你好世界"}, "finish_reason": "stop"}
    ]


def test_keeps_choices_reasoning_and_usage_separate_without_done_marker():
    body = event(chunk({"content": "第二", "reasoning_content": "推理二"}, index=1))
    body += event(chunk({"role": "assistant", "content": "第一", "reasoning_content": "推理一"}))
    body += event(chunk({"content": "项"}, finish="stop"))
    body += event(chunk({"content": "项"}, index=1, finish="length"))
    body += event({"choices": [], "usage": {"total_tokens": 12}}).rstrip("\n")
    result = decode_chat_completion_response(response(body))
    assert result["usage"] == {"total_tokens": 12}
    assert [choice["index"] for choice in result["choices"]] == [0, 1]
    assert [choice["message"]["content"] for choice in result["choices"]] == ["第一项", "第二项"]
    assert [choice["message"]["reasoning_content"] for choice in result["choices"]] == ["推理一", "推理二"]


def test_reasoning_only_length_completion_is_preserved_for_caller_retry():
    result = decode_chat_completion_response(
        response(event(chunk({"reasoning_content": "推理"}, finish="length")))
    )
    assert result["choices"][0] == {
        "index": 0,
        "message": {"role": "assistant", "content": "", "reasoning_content": "推理"},
        "finish_reason": "length",
    }


@pytest.mark.parametrize("done", [False, True])
@pytest.mark.parametrize("error_event", [False, True])
def test_late_errors_discard_content_and_never_expose_upstream_secrets(done, error_event):
    body = event(chunk({"content": "不得返回的部分正文"}, finish="stop"))
    body += event("[DONE]") if done else ""
    body += (
        "event: error\ndata: sk-sensitive-upstream-body\n\n"
        if error_event
        else event({"error": {"message": "sk-sensitive-upstream-body"}})
    )
    result = decode_chat_completion_response(response(body))
    assert "error" in result and "choices" not in result
    assert "sk-sensitive" not in str(result) and "部分正文" not in str(result)


@pytest.mark.parametrize(
    "body",
    [
        "",
        ": heartbeat\n\n",
        event("[DONE]"),
        event({"choices": [], "usage": {"total_tokens": 1}}),
        event(chunk({"content": "partial"})),
        event(chunk({"content": "partial"})) + event("[DONE]"),
        event(chunk({"content": "done"}, finish="stop")) + event(chunk({}, index=1)) + event("[DONE]"),
        event("not-json sk-sensitive-upstream-body"),
        event([]),
        event({"choices": "invalid"}),
        event({"object": [], "choices": []}),
        event('{"choices": [], "usage": {"total_tokens": NaN}}'),
        event({"choices": [{"index": 0, "message": {"content": "not a delta"}, "finish_reason": "stop"}]}),
        event(chunk({"content": ["nontext"]}, finish="stop")),
        event(chunk({"tool_calls": [{"name": "run"}]}, finish="stop")),
        event(chunk({"content": "text"}, finish="tool_calls")),
        event(chunk({"content": "text"}, index=True, finish="stop")),
        event(chunk({"content": "text"}, finish="stop")) + event(chunk({"content": "late"}, finish="stop")),
        event(chunk({}, finish="stop")) + event("[DONE]") + event(chunk({"content": "late"}, finish="stop")),
        event(chunk({}, finish="stop")) + event("[DONE]") + "unexpected trailing bytes",
    ],
)
def test_incomplete_invalid_nontext_or_post_finish_data_fails_without_leaking_body(body):
    with pytest.raises(CompletionStreamError) as captured:
        decode_chat_completion_response(response(body))
    assert str(captured.value) == "模型服务返回的流式响应不完整或格式不受支持，请重试"
    assert "sk-sensitive" not in str(captured.value)


def test_non_sse_invalid_json_still_raises_original_json_error():
    with pytest.raises(json.JSONDecodeError):
        decode_chat_completion_response(response("not JSON", "application/json"))


@pytest.mark.parametrize("content_type", ["text/event-stream", "application/octet-stream"])
def test_invalid_utf8_stream_has_sanitized_error(content_type):
    with pytest.raises(CompletionStreamError):
        decode_chat_completion_response(
            httpx.Response(200, content=b"data: \xff", headers={"Content-Type": content_type})
        )


def azure_annotation(*, index=0, filtered=False, finish=None):
    return {
        "id": "",
        "object": "",
        "created": 0,
        "model": "",
        "usage": None,
        "choices": [
            {
                "index": index,
                "finish_reason": finish,
                "content_filter_results": {"hate": {"filtered": filtered, "severity": "safe"}},
                "content_filter_offsets": {"check_offset": 506, "start_offset": 44, "end_offset": 571},
            }
        ],
    }


@pytest.mark.parametrize("prompt_key", ["prompt_filter_results", "prompt_annotations"])
@pytest.mark.parametrize("done", [False, True])
def test_azure_prompt_and_trailing_choice_annotations_preserve_completed_text_and_metadata(prompt_key, done):
    prompt = {
        "id": "",
        "object": "",
        "created": 0,
        "model": "",
        "usage": None,
        "choices": [],
        prompt_key: [{"prompt_index": 0, "content_filter_results": {"hate": {"filtered": False}}}],
    }
    body = event(prompt)
    body += event(
        chunk({"role": "assistant", "content": "第一"}, id="chat-real", model="model-real", created=123)
    )
    body += event(azure_annotation())
    body += event(chunk({"content": "段正文"}, finish="stop"))
    body += event(azure_annotation(index=7))  # An annotation must not create another choice.
    body += event(azure_annotation())
    body += event("[DONE]") if done else ""
    result = decode_chat_completion_response(response(body))
    assert result["id"] == "chat-real" and result["model"] == "model-real" and result["created"] == 123
    assert result["choices"] == [
        {"index": 0, "message": {"role": "assistant", "content": "第一段正文"}, "finish_reason": "stop"}
    ]


@pytest.mark.parametrize(
    "tail",
    [
        azure_annotation(filtered=True),
        azure_annotation(finish="content_filter"),
        chunk({}, finish="content_filter"),
    ],
)
def test_content_filter_hit_discards_preceding_text_even_after_normal_stop(tail):
    body = event(chunk({"content": "禁止返回的部分正文"}, finish="stop")) + event(tail)
    result = decode_chat_completion_response(response(body))
    assert "error" in result and "choices" not in result
    assert "部分正文" not in str(result)


@pytest.mark.parametrize(
    "invalid",
    [
        azure_annotation(),
        {**azure_annotation(), "content": "must not ignore output"},
        {
            **azure_annotation(),
            "choices": [{**azure_annotation()["choices"][0], "delta": {"content": "text"}}],
        },
        {
            **azure_annotation(),
            "choices": [{**azure_annotation()["choices"][0], "message": {"content": "text"}}],
        },
        {
            **azure_annotation(),
            "choices": [
                {**azure_annotation()["choices"][0], "content_filter_offsets": {"check_offset": "10"}}
            ],
        },
        azure_annotation(filtered="true"),
    ],
)
def test_annotations_cannot_replace_completion_or_smuggle_unprocessed_content(invalid):
    with pytest.raises(CompletionStreamError):
        decode_chat_completion_response(response(event(invalid)))
