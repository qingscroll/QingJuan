from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class AnnotationPosition(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    chapterIndex: int = Field(ge=1, le=2**31 - 1)
    scrollRatio: float = Field(default=0, ge=0, le=1)
    anchorType: Literal["top", "paragraph", "image"] = "top"
    anchorIndex: int = Field(default=0, ge=0, le=2**31 - 1)
    anchorOffsetRatio: float = Field(default=0, ge=0, le=1)
    pageIndex: int | None = Field(default=None, ge=0, le=2**31 - 1)
    pageCount: int | None = Field(default=None, ge=1, le=2**31 - 1)
    layoutKey: str | None = Field(default=None, max_length=256)
    contentMode: Literal["original", "translated"] | None = None
    characterOffset: int | None = Field(default=None, ge=0, le=2**63 - 1)

    @model_validator(mode="after")
    def page_bounds(self):
        if self.pageIndex is not None and self.pageCount is not None and self.pageIndex >= self.pageCount:
            raise ValueError("页码超出章节页数")
        return self


class AnnotationCreate(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    clientKey: str = Field(min_length=1, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")
    kind: Literal["bookmark", "note"]
    label: str = Field(default="", max_length=120)
    quote: str = Field(default="", max_length=4000)
    note: str = Field(default="", max_length=20000)
    position: AnnotationPosition

    @field_validator("label", "quote", "note")
    @classmethod
    def text(cls, value):
        if "\0" in value:
            raise ValueError("笔记不能包含空字符")
        return value.strip()


class AnnotationPatch(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    expectedRevision: int = Field(ge=0)
    label: str = Field(default="", max_length=120)
    quote: str = Field(default="", max_length=4000)
    note: str = Field(default="", max_length=20000)
    position: AnnotationPosition | None = None

    @field_validator("label", "quote", "note")
    @classmethod
    def text(cls, value):
        return AnnotationCreate.text(value)

    @model_validator(mode="after")
    def nonempty(self):
        if self.model_fields_set == {"expectedRevision"}:
            raise ValueError("至少修改一项笔记内容")
        if "position" in self.model_fields_set and self.position is None:
            raise ValueError("阅读位置不能为空")
        return self


class ReadingAnnotation(BaseModel):
    id: str
    bookId: str
    kind: Literal["bookmark", "note"]
    label: str
    quote: str
    note: str
    position: AnnotationPosition
    revision: int
    createdAt: str
    updatedAt: str
    contentHash: str | None = None
    contentChanged: bool = False


class CachedTextQuery(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
    query: str = Field(min_length=1, max_length=120)
    mode: Literal["original", "translated"] = "original"
    chapterIndex: int | None = Field(default=None, ge=1)
    cursor: str | None = Field(default=None, max_length=1024)
    limit: int = Field(default=50, ge=1, le=100)

    @field_validator("query")
    @classmethod
    def keyword(cls, value):
        value = value.strip()
        if not value or "\0" in value:
            raise ValueError("请输入有效的搜索关键词")
        return value


class CachedTextHit(BaseModel):
    chapterTitle: str
    snippet: str
    position: AnnotationPosition
    contentHash: str


class CachedTextResults(BaseModel):
    results: list[CachedTextHit]
    nextCursor: str | None = None
    scannedChapters: int = 0
    uncachedChapters: int = 0
    skippedChapters: int = 0
    truncated: bool = False
    offsetEncoding: Literal["utf-16"] = "utf-16"
