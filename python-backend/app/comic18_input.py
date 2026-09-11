"""Normalize the ID entry point without depending on a running JM API service."""

import re
from urllib.parse import urlparse


def normalize_album_id(value: object) -> str:
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise ValueError("禁漫本子号必须为正整数")
    text = str(value).strip()
    if not re.fullmatch(r"[0-9]+", text) or not text.strip("0"):
        raise ValueError("禁漫本子号必须为正整数")
    return text.lstrip("0")


def canonical_album_url(album_id: str) -> str:
    return f"https://18comic.vip/album/{album_id}/"


def source_matches_album(source: object, album_id: str) -> bool:
    text = str(source).strip()
    if re.fullmatch(r"[0-9]+", text):
        return normalize_album_id(text) == album_id
    parsed = urlparse(text)
    host = (parsed.hostname or "").lower().rstrip(".")
    match = re.fullmatch(r"/album/([0-9]+)(?:/[^/?#]*)?/?", parsed.path)
    return bool(
        parsed.scheme in {"http", "https"}
        and (host == "18comic.vip" or host.endswith(".18comic.vip"))
        and match
        and normalize_album_id(match.group(1)) == album_id
    )
