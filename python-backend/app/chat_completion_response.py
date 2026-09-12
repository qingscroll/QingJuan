"""Decode completed JSON or SSE chat responses without conflating choice streams."""

from __future__ import annotations

import json
import re
from typing import Any

import httpx

_INVALID_STREAM = "模型服务返回的流式响应不完整或格式不受支持，请重试"
_STREAM_ERROR = {"error": {"message": "模型服务返回流式错误，请重试"}}


class CompletionStreamError(ValueError):
    """A malformed or incomplete stream; never include upstream response text."""


def _invalid() -> CompletionStreamError:
    return CompletionStreamError(_INVALID_STREAM)


def _reject_json_constant(_value: str):
    raise _invalid()


def _has_filter_hit(value: Any) -> bool:
    if isinstance(value, dict):
        if "filtered" in value and type(value["filtered"]) is not bool:
            raise _invalid()
        return value.get("filtered") is True or any(_has_filter_hit(item) for item in value.values())
    return isinstance(value, list) and any(_has_filter_hit(item) for item in value)


def _annotation_choice(choice: Any) -> bool:
    if not isinstance(choice, dict) or set(choice) - {
        "index",
        "finish_reason",
        "content_filter_results",
        "content_filter_offsets",
    }:
        return False
    filters, offsets = choice.get("content_filter_results"), choice.get("content_filter_offsets")
    return (
        type(choice.get("index")) is int
        and choice["index"] >= 0
        and choice.get("finish_reason") is None
        and (isinstance(filters, dict) or isinstance(offsets, dict))
        and (filters is None or isinstance(filters, dict))
        and (
            offsets is None
            or (
                isinstance(offsets, dict)
                and not set(offsets) - {"check_offset", "start_offset", "end_offset"}
                and all(type(value) is int and value >= 0 for value in offsets.values())
            )
        )
    )


def _annotation_chunk(chunk: dict, incoming: list) -> bool:
    if chunk.get("object", "chat.completion.chunk") not in ("", "chat.completion.chunk"):
        return False
    if (
        set(chunk)
        - {
            "id",
            "object",
            "created",
            "model",
            "choices",
            "usage",
            "prompt_filter_results",
            "prompt_annotations",
        }
        or chunk.get("usage") is not None
    ):
        return False
    prompts = [chunk[key] for key in ("prompt_filter_results", "prompt_annotations") if key in chunk]
    for entries in prompts:
        if not isinstance(entries, list) or any(
            not isinstance(item, dict)
            or set(item) - {"prompt_index", "content_filter_results"}
            or type(item.get("prompt_index")) is not int
            or item["prompt_index"] < 0
            or not isinstance(item.get("content_filter_results"), dict)
            for item in entries
        ):
            return False
    return bool(prompts or incoming) and all(_annotation_choice(choice) for choice in incoming)


def _events(text: str):
    data: list[str] = []
    event = ""
    for line in [*re.split(r"\r\n|\r|\n", text), ""]:
        if not line:
            if data or event:
                yield event, "\n".join(data)
            data, event = [], ""
            continue
        if line.startswith(":"):
            continue
        field, _, value = line.partition(":")
        if value.startswith(" "):
            value = value[1:]
        if field == "data":
            data.append(value)
        elif field == "event":
            event = value
        elif field not in {"id", "retry"}:
            raise _invalid()


def _is_stream(text: str, content_type: str) -> bool:
    if content_type.split(";", 1)[0].strip().lower() == "text/event-stream":
        return True
    first_line = next((line for line in re.split(r"\r\n|\r|\n", text) if line), "")
    return first_line.startswith(("data:", "event:", ":")) or first_line in {"data", "event"}


def decode_chat_completion_response(response: httpx.Response) -> Any:
    """Decode a fully received response, retaining ordinary ``response.json`` behavior."""
    try:
        return response.json()
    except ValueError as json_error:
        try:
            text = response.content.decode("utf-8-sig")
        except UnicodeDecodeError:
            prefix = response.content.removeprefix(b"\xef\xbb\xbf").lstrip(b"\r\n")
            if "text/event-stream" in response.headers.get("content-type", "").lower() or prefix.startswith(
                (b"data:", b"event:", b":")
            ):
                raise _invalid() from None
            raise json_error from None
        if not _is_stream(text, response.headers.get("content-type", "")):
            raise json_error from None

    choices: dict[int, dict[str, Any]] = {}
    metadata: dict[str, Any] = {}
    usage = None
    done = False
    for event, data in _events(text):
        if event.lower() == "error":
            return {"error": dict(_STREAM_ERROR["error"])}
        if data.strip() == "[DONE]":
            if done:
                raise _invalid()
            done = True
            continue
        try:
            chunk = json.loads(data, parse_constant=_reject_json_constant)
        except (ValueError, TypeError):
            raise _invalid() from None
        if not isinstance(chunk, dict):
            raise _invalid()
        if chunk.get("error") is not None:
            # Errors after content or [DONE] still fail, without exposing tokens,
            # gateway diagnostics, or partial output to the caller's error path.
            return {"error": dict(_STREAM_ERROR["error"])}
        incoming = chunk.get("choices")
        if not isinstance(incoming, list):
            raise _invalid()
        if _has_filter_hit(chunk) or any(
            isinstance(choice, dict) and choice.get("finish_reason") == "content_filter"
            for choice in incoming
        ):
            return {"error": dict(_STREAM_ERROR["error"])}
        if done:
            raise _invalid()
        # Azure sends prompt filters and choice annotations between tokens and
        # after stop. Pure annotations neither create choices nor replace IDs.
        if _annotation_chunk(chunk, incoming):
            continue
        if chunk.get("object", "chat.completion.chunk") != "chat.completion.chunk":
            raise _invalid()
        for key in ("id", "created", "model", "system_fingerprint", "service_tier"):
            if key in chunk and key not in metadata:
                metadata[key] = chunk[key]
        if chunk.get("usage") is not None:
            if not isinstance(chunk["usage"], dict):
                raise _invalid()
            usage = chunk["usage"]
        for choice in incoming:
            if _annotation_choice(choice):
                continue
            if not isinstance(choice, dict):
                raise _invalid()
            index = choice.get("index")
            delta = choice.get("delta")
            finish = choice.get("finish_reason")
            if (
                type(index) is not int
                or index < 0
                or not isinstance(delta, dict)
                or (finish is not None and (not isinstance(finish, str) or not finish))
                or finish in {"tool_calls", "function_call"}
            ):
                raise _invalid()
            if any(
                key not in {"role", "content", "reasoning_content"} and value is not None
                for key, value in delta.items()
            ):
                raise _invalid()
            state = choices.setdefault(
                index,
                {
                    "role": None,
                    "content": [],
                    "reasoning_content": [],
                    "has_reasoning": False,
                    "finish_reason": None,
                },
            )
            if state["finish_reason"] is not None:
                raise _invalid()
            role = delta.get("role")
            if role is not None:
                if not isinstance(role, str) or not role or state["role"] not in {None, role}:
                    raise _invalid()
                state["role"] = role
            for key in ("content", "reasoning_content"):
                value = delta.get(key)
                if value is not None:
                    if not isinstance(value, str):
                        raise _invalid()
                    state[key].append(value)
                    if key == "reasoning_content":
                        state["has_reasoning"] = True
            state["finish_reason"] = finish
    if not choices or any(state["finish_reason"] is None for state in choices.values()):
        raise _invalid()
    result: dict[str, Any] = {**metadata, "object": "chat.completion", "choices": []}
    for index, state in sorted(choices.items()):
        message = {"role": state["role"] or "assistant", "content": "".join(state["content"])}
        if state["has_reasoning"]:
            message["reasoning_content"] = "".join(state["reasoning_content"])
        result["choices"].append(
            {"index": index, "message": message, "finish_reason": state["finish_reason"]}
        )
    if usage is not None:
        result["usage"] = usage
    return result
