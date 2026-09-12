"""文本 / 数值清洗工具。"""

from __future__ import annotations

import html as _html
import re
from typing import Any
from urllib.parse import urljoin

_WS_RE = re.compile(r"[\s\u3000\xa0]+")
_TAG_RE = re.compile(r"<[^>]+>")
_NUM_RE = re.compile(r"(-?\d+(?:\.\d+)?)")


def clean(value: Any) -> str:
    """去标签、反转义、压缩空白。"""
    if value is None:
        return ""
    text = str(value)
    if "<" in text and ">" in text:
        text = _TAG_RE.sub(" ", text)
    text = _html.unescape(text)
    text = text.replace("\u200b", "").replace("\ufeff", "")
    return _WS_RE.sub(" ", text).strip()


def first_num(value: Any, default: int | None = None) -> int | None:
    """从「399.02万字」「2.95万月票」这类文案里取第一个数字（整数）。"""
    text = clean(value)
    if not text:
        return default
    m = _NUM_RE.search(text)
    if not m:
        return default
    try:
        return int(float(m.group(1)))
    except ValueError:
        return default


def pick(data: dict, *keys: str, default: Any = "") -> Any:
    """按顺序取第一个非空字段。"""
    for key in keys:
        if not isinstance(data, dict):
            break
        value = data.get(key)
        if value not in (None, "", [], {}):
            return value
    return default


def abs_url(base: str, url: str) -> str:
    """相对地址补全；处理协议相对地址 //x.y/z。"""
    url = (url or "").strip()
    if not url:
        return ""
    if url.startswith("//"):
        return "https:" + url
    if url.startswith("http://") or url.startswith("https://"):
        return url
    if not base:
        return url
    return urljoin(base if base.endswith("/") else base + "/", url.lstrip("./"))


def trim(value: Any, limit: int = 400) -> str:
    text = clean(value)
    return text if len(text) <= limit else text[:limit] + "…"


def extract_json_after(text: str, marker: str, opener: str = "{") -> Any | None:
    """从 HTML 中取出 `marker` 之后的第一个**括号配平**的 JSON 对象/数组。

    用于解析 `window.__INITIAL_STATE__ = {...}`、`window.__DATA__ = [...]` 之类的内嵌状态，
    比正则贪婪匹配更可靠（字符串内的花括号会被正确忽略）。
    """
    import json

    start = text.find(marker)
    if start < 0:
        return None
    pos = text.find(opener, start + len(marker))
    if pos < 0:
        return None
    closer = "}" if opener == "{" else "]"
    depth = 0
    in_str = False
    escaped = False
    for idx in range(pos, len(text)):
        ch = text[idx]
        if in_str:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == opener:
            depth += 1
        elif ch == closer:
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[pos : idx + 1])
                except ValueError:
                    return None
    return None


def extract_next_data(text: str) -> Any | None:
    """取 Next.js 的 `__NEXT_DATA__` JSON。"""
    import json
    import re

    m = re.search(r'<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)</script>', text, re.S)
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except ValueError:
        return None


def extract_script_json(text: str, script_id: str) -> Any | None:
    """取指定 id 的 `<script>` 内的 JSON（如 vite-plugin-ssr 的 pageContext）。"""
    import json
    import re

    m = re.search(rf'<script[^>]*id="{re.escape(script_id)}"[^>]*>(.*?)</script>', text, re.S)
    if not m:
        return None
    raw = m.group(1).strip()
    try:
        return json.loads(raw)
    except ValueError:
        return None
