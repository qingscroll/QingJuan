"""Conservative publication metadata, separate from download/translation status.

Only explicit publication labels and named boolean fields are accepted. Numeric
site codes are deliberately unknown unless their meanings have been verified.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Literal

from bs4 import BeautifulSoup

SourceStatus = Literal["ongoing", "completed", "unknown"]
_ONGOING = frozenset({"ongoing", "running", "serializing", "连载", "连载中", "連載", "連載中"})
_COMPLETED = frozenset(
    {"completed", "finished", "complete", "完结", "已完结", "完本", "已完本", "完結", "完結済", "完結済み"}
)


@dataclass(frozen=True)
class PublicationStatus:
    status: SourceStatus = "unknown"
    evidence: str | None = None

    def preview_fields(self) -> dict[str, Any]:
        return {"sourceStatus": self.status, "sourceStatusEvidence": self.evidence}


def explicit_status(value: Any) -> SourceStatus:
    if not isinstance(value, str):
        return "unknown"
    label = value.strip().lower()
    if label in _ONGOING:
        return "ongoing"
    if label in _COMPLETED:
        return "completed"
    return "unknown"


def publication_status(source: str, metadata: Any) -> PublicationStatus:
    if not isinstance(metadata, dict):
        return PublicationStatus()
    # Work.serialStatus RUNNING/COMPLETED is also used by our existing Kakuyomu
    # discovery query. SUSPENDED/DRAFT are intentionally not classified.
    fields = {
        "kakuyomu": ("serialStatus",),
        "fanqie": ("creationStatus", "creation_status"),
        "qidian": ("bookStatus", "state"),
        "quark": ("statusText", "bookStatus", "state"),
        "copymanga": ("status",),
        "json-book": ("sourceStatus", "publicationStatus"),
    }.get(source, ())
    observed: list[PublicationStatus] = []
    for field in fields:
        value = metadata.get(field)
        # CopyManga exposes the human-readable display beside its numeric code.
        if source == "copymanga" and isinstance(value, dict):
            value = value.get("display")
        status = explicit_status(value)
        # Verified from the official Fanqie web bundle: DONE=0 / DOING=1,
        # alongside the rendered status badge; see 10-serial-updates.md.
        if source == "fanqie" and field == "creationStatus" and type(value) in {str, int}:
            status = {"0": "completed", "1": "ongoing"}.get(str(value), status)
        # content.shuqireader.com/xapi/book/info state corroborated against
        # official book pages: 8869540 (1/连载), 7106468 (2/完结).
        if source == "quark" and field == "state" and type(value) in {str, int}:
            status = {"1": "ongoing", "2": "completed"}.get(str(value), status)
        if status != "unknown":
            observed.append(PublicationStatus(status, f"{source}.{field}"))
    if source == "bika" and type(metadata.get("isFinished")) is bool:
        observed.append(
            PublicationStatus("completed" if metadata["isFinished"] else "ongoing", "bika.isFinished")
        )
    if source == "qidian" and type(metadata.get("finish")) is bool:
        observed.append(PublicationStatus("completed" if metadata["finish"] else "ongoing", "qidian.finish"))
    if source == "sfacg" and type(metadata.get("isFinish")) is bool:
        observed.append(
            PublicationStatus("completed" if metadata["isFinish"] else "ongoing", "sfacg.isFinish")
        )
    if len({item.status for item in observed}) != 1:
        return PublicationStatus()
    return observed[0]


def html_publication_status(html: str, *, source: str = "web") -> PublicationStatus:
    soup = BeautifulSoup(html, "html.parser")
    observed: list[PublicationStatus] = []
    for node in soup.select(
        "meta[property='og:novel:status'],meta[name='og:novel:status'],"
        "meta[property='og:novel:book_status'],meta[name='book:status']"
    ):
        status = explicit_status(node.get("content"))
        if status != "unknown":
            observed.append(PublicationStatus(status, f"{source}.publication-meta"))
    if source == "fanqie":
        # Only the book-info status badge, never synopsis/chapter title text.
        for node in soup.select(".info-label span"):
            status = explicit_status(node.get_text(strip=True))
            if status != "unknown":
                observed.append(PublicationStatus(status, "fanqie.info-label"))
    if len({item.status for item in observed}) != 1:
        return PublicationStatus()
    return observed[0]


def fanqie_publication_status(html: str) -> PublicationStatus:
    from .fanqie_parser import _initial_state_from_html

    metadata = publication_status("fanqie", _initial_state_from_html(html).get("page"))
    badge = html_publication_status(html, source="fanqie")
    if metadata.status != "unknown" and badge.status != "unknown" and metadata.status != badge.status:
        return PublicationStatus()
    return metadata if metadata.status != "unknown" else badge


def manifest_publication_fields(preview: Any) -> dict[str, Any]:
    return {
        "source_status": preview.sourceStatus,
        "source_status_evidence": preview.sourceStatusEvidence,
        "source_status_checked_at": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
    }
