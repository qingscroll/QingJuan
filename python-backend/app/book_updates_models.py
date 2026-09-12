from pydantic import BaseModel, ConfigDict, Field

from .source_status import SourceStatus


class BookUpdateSettings(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    expectedRevision: int = Field(ge=0)
    # Accepted for old clients; publication status now controls scheduling.
    enabled: bool | None = None
    intervalHours: int = Field(default=6, ge=1, le=168)
    autoDownload: bool = False


class BookUpdateAck(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    throughChapterIndex: int = Field(ge=0)


class BookUpdateState(BaseModel):
    bookId: str
    automatic: bool = True
    supported: bool = False
    unsupportedReason: str | None = None
    sourceStatus: SourceStatus = "unknown"
    sourceStatusCheckedAt: str | None = None
    enabled: bool = False
    intervalHours: int = 6
    autoDownload: bool = False
    revision: int = 0
    checking: bool = False
    lastCheckedAt: str | None = None
    nextCheckAt: str | None = None
    lastError: str | None = None
    newChapterCount: int = 0
    latestChapterIndex: int = 0
    acknowledgedChapterIndex: int = 0
