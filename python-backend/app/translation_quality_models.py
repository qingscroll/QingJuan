from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

MAX_TEXT_CHARS = 200_000
MAX_TEXT_BYTES = 1_048_576
Hash = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]


class TranslationQualityError(ValueError):
    def __init__(self, message: str, status_code: int = 422):
        super().__init__(message)
        self.status_code = status_code


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class GlossaryEntry(StrictModel):
    source: str = Field(min_length=1, max_length=100)
    target: str = Field(min_length=1, max_length=100)
    kind: Literal["term", "name"] = "term"
    note: str = Field(default="", max_length=200)

    @model_validator(mode="after")
    def normalize(self):
        self.source, self.target, self.note = self.source.strip(), self.target.strip(), self.note.strip()
        if not self.source or not self.target:
            raise ValueError("术语原文与译名不能为空")
        if any(ord(char) < 32 for char in self.source + self.target + self.note):
            raise ValueError("术语不能包含控制字符或换行")
        return self


class GlossaryPatch(StrictModel):
    expectedRevision: int = Field(ge=0)
    entries: list[GlossaryEntry] = Field(max_length=100)

    @model_validator(mode="after")
    def unique_sources(self):
        if len({item.source.casefold() for item in self.entries}) != len(self.entries):
            raise ValueError("术语原文不能重复")
        return self


class BookGlossary(StrictModel):
    bookId: str
    revision: int
    entries: list[GlossaryEntry]
    updatedAt: str | None = None


class TranslationCAS(StrictModel):
    expectedRevision: int = Field(ge=0)
    sourceHash: Hash
    translationHash: Hash


class TranslationEdit(TranslationCAS):
    text: str = Field(min_length=1, max_length=MAX_TEXT_CHARS)

    @model_validator(mode="after")
    def valid_text(self):
        self.text = self.text.replace("\r\n", "\n").replace("\r", "\n")
        if not self.text.strip() or "\x00" in self.text or len(self.text.encode("utf-8")) > MAX_TEXT_BYTES:
            raise ValueError("译文不能为空或包含无效字符，且不能超过 1 MiB")
        return self


class TranslationRestore(TranslationCAS):
    historyId: str = Field(pattern=r"^[0-9a-f]{32}$")


class RetranslateSelection(TranslationCAS):
    operationId: str = Field(pattern=r"^[A-Za-z0-9._:-]{8,64}$")
    sourceStart: int = Field(ge=0)
    sourceEnd: int = Field(gt=0)


class TranslationHistoryItem(StrictModel):
    id: str
    revision: int
    kind: Literal["initial", "edit", "restore", "translate", "external"]
    createdAt: str
    sourceHash: str
    translationHash: str


class TranslationRevision(TranslationHistoryItem):
    text: str


class ChapterTranslation(StrictModel):
    bookId: str
    chapterIndex: int
    title: str
    sourceText: str
    translatedText: str
    sourceHash: str
    translationHash: str
    revision: int
    history: list[TranslationHistoryItem]


class TranslationUsage(StrictModel):
    id: str
    chapterIndex: int
    operation: Literal["translate", "retranslate"]
    model: str
    inputTokens: int | None = None
    outputTokens: int | None = None
    totalTokens: int | None = None
    durationMs: int
    status: Literal["completed", "failed", "cancelled"]
    createdAt: str


class TranslationSuggestion(StrictModel):
    operationId: str
    sourceStart: int
    sourceEnd: int
    text: str
    usage: TranslationUsage | None = None
