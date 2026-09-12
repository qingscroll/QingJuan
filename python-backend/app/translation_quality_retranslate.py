"""Single-attempt, owner-limited translation suggestions; applying is a separate CAS edit."""

from __future__ import annotations

import asyncio
import hashlib
from datetime import UTC, datetime, timedelta

from . import db
from . import translation_quality_repository as repository
from .resource_limits import ResourceLimitError
from .translation_quality_models import RetranslateSelection, TranslationQualityError, TranslationSuggestion
from .translation_quality_service import get_chapter, verify_cas
from .translation_quality_usage import glossary_instruction, translation_context

MAX_SELECTION_CHARS = 4000
MAX_RESPONSE_CHARS = 32_000
REQUEST_TIMEOUT = 60


def _reserve(book, index, payload: RetranslateSelection):
    fingerprint = hashlib.sha256(payload.model_dump_json().encode()).hexdigest()
    with db.get_connection() as conn:
        conn.execute("BEGIN IMMEDIATE")
        repository.assert_owned(conn, book)
        row = conn.execute(
            """SELECT book_id,chapter_index,payload_hash,status,result_json
            FROM translation_quality_requests WHERE owner_id=? AND operation_id=?""",
            (book.ownerId, payload.operationId),
        ).fetchone()
        if row:
            if (row[0], row[1], row[2]) != (book.id, index, fingerprint):
                raise TranslationQualityError("此重译操作标识已用于其他内容，请重新选择文本", 409)
            if row[3] == "completed":
                return TranslationSuggestion.model_validate_json(row[4])
            raise TranslationQualityError("该重译请求已提交或已结束，请重新自查结果后发起新的操作", 409)
        repository.assert_idle(conn, book)
        running = conn.execute(
            "SELECT owner_id FROM translation_quality_requests WHERE status='running'"
        ).fetchall()
        if len(running) >= 2 or any(row[0] == book.ownerId for row in running):
            raise TranslationQualityError("选段重译正在处理中，请等待当前请求结束", 409)
        since = (datetime.now(UTC) - timedelta(hours=1)).isoformat().replace("+00:00", "Z")
        if (
            conn.execute(
                "SELECT count(*) FROM translation_quality_requests WHERE owner_id=? AND created_at>=?",
                (book.ownerId, since),
            ).fetchone()[0]
            >= 20
        ):
            raise TranslationQualityError("本小时选段重译次数已达上限（20 次），请稍后再试", 429)
        conn.execute(
            "INSERT INTO translation_quality_requests VALUES(?,?,?,?,?,?,?,?)",
            (
                book.id,
                book.ownerId,
                index,
                payload.operationId,
                fingerprint,
                "running",
                None,
                repository.now(),
            ),
        )
    return None


def _finish(book, operation_id, result=None):
    with db.get_connection() as conn:
        conn.execute(
            """UPDATE translation_quality_requests SET status=?,result_json=?
            WHERE owner_id=? AND operation_id=?""",
            (
                "completed" if result else "failed",
                result.model_dump_json() if result else None,
                book.ownerId,
                operation_id,
            ),
        )


async def retranslate(book, index: int, payload: RetranslateSelection) -> TranslationSuggestion:
    snapshot = get_chapter(book, index)
    verify_cas(snapshot, payload)
    if not (0 <= payload.sourceStart < payload.sourceEnd <= len(snapshot.sourceText)):
        raise TranslationQualityError("请选择有效的原文范围")
    selected = snapshot.sourceText[payload.sourceStart : payload.sourceEnd]
    if not selected.strip() or len(selected) > MAX_SELECTION_CHARS:
        raise TranslationQualityError("每次选段重译需选择 1–4000 个原文字符")
    existing = _reserve(book, index, payload)
    if existing is not None:
        return existing
    try:
        from . import scraper

        settings = db.load_settings()
        base_url, api_key, model = scraper._resolve_openai_compatible_model_config(
            settings, feature_name="选段重译"
        )
        with translation_context(book, index, "retranslate") as context:
            request_payload = scraper._translation_completion_request_payload(
                {
                    "model": model,
                    "temperature": 0.2,
                    "max_tokens": 8000,
                    "messages": [
                        {"role": "system", "content": settings.systemPrompt},
                        {
                            "role": "user",
                            "content": f"将选中原文翻译为{scraper._resolve_translation_target_language(book.language)}，只输出选段译文。"
                            + glossary_instruction(selected)
                            + "\n原文：\n"
                            + selected,
                        },
                    ],
                },
                expects_json=False,
            )
            async with (
                asyncio.timeout(REQUEST_TIMEOUT),
                scraper._create_model_http_client(timeout=REQUEST_TIMEOUT) as client,
            ):
                response = await scraper._post_translation_json(
                    client,
                    f"{base_url}/chat/completions",
                    headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                    payload=request_payload,
                    max_retries=1,
                )
            choice = scraper._chat_completion_choice(response, "翻译模型")
            if choice.get("finish_reason") == "length":
                raise TranslationQualityError("模型输出达到上限，未采用不完整译文；请缩小选段后重试", 502)
            message = choice.get("message")
            text = scraper._normalize_translation_result(
                message.get("content") if isinstance(message, dict) else None
            )
            if len(text) > MAX_RESPONSE_CHARS or "\x00" in text:
                raise TranslationQualityError("模型输出超出选段上限，请缩小选段后重试", 502)
            # Changes made while the provider was running cannot authorize an old result.
            verify_cas(get_chapter(book, index), payload)
            result = TranslationSuggestion(
                operationId=payload.operationId,
                sourceStart=payload.sourceStart,
                sourceEnd=payload.sourceEnd,
                text=text,
                usage=context.usage,
            )
            _finish(book, payload.operationId, result)
            return result
    except ResourceLimitError as error:
        _finish(book, payload.operationId)
        raise TranslationQualityError(str(error), error.status_code) from None
    except TranslationQualityError:
        _finish(book, payload.operationId)
        raise
    except asyncio.CancelledError:
        _finish(book, payload.operationId)
        raise
    except Exception:
        _finish(book, payload.operationId)
        raise TranslationQualityError(
            "选段重译未完成，请检查翻译模型配置或稍后重试；原译文保持不变", 502
        ) from None
