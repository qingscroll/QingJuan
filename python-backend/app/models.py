from __future__ import annotations

from datetime import UTC, datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, HttpUrl, SecretStr

from .multi_user import DEFAULT_ADMIN_USER_ID

BookKind = Literal["长小说", "轻小说", "漫画"]
Language = Literal["中文", "英文", "日文"]
TaskType = Literal["download", "translate"]
TaskStatus = Literal["queued", "running", "completed", "failed"]
TaskLogLevel = Literal["info", "warning", "error"]
LinkJobMode = Literal["preview", "import"]
DownloadMode = Literal["all", "on_demand"]
SourceOrigin = Literal["builtin", "manual", "file", "remote"]
SourceStatus = Literal["unknown", "online", "slow", "offline", "unsupported"]
SitePluginCategory = Literal["novel", "manga", "general"]
DevicePlatform = Literal["android", "windows", "linux", "macos", "ios", "other"]
MangaTextDirection = Literal["vertical", "horizontal"]
MangaRegionShape = Literal["ellipse", "roundrect", "rect"]
MangaRenderMode = Literal["ocr_pipeline", "image_edit_fallback"]
MangaWorkflowMode = Literal[
    "normal",
    "export_translation",
    "export_original",
    "translate_json_only",
    "import_translation_render",
    "colorize_only",
    "upscale_only",
    "inpaint_only",
    "replace_translation",
]
UserRole = Literal["admin", "user"]
UserStatus = Literal["active", "disabled"]


class ServiceMetaResponse(BaseModel):
    service: Literal["qingjuan-backend"] = "qingjuan-backend"
    appVersion: str
    apiVersion: str
    instanceId: str
    capabilities: dict[str, bool] = Field(default_factory=dict)


class UserRecord(BaseModel):
    id: str
    username: str
    email: str | None = None
    displayName: str
    role: UserRole = "user"
    status: UserStatus = "active"
    createdAt: str
    lastLoginAt: str | None = None


class AdminUserRecord(UserRecord):
    bookCount: int = 0
    isDefaultAdmin: bool = False
    githubLogin: str | None = None
    twoFactorEnabled: bool = False


class DeviceRecord(BaseModel):
    id: str
    name: str
    platform: DevicePlatform = "other"
    ipAddress: str
    firstSeenAt: str
    lastSeenAt: str
    banned: bool = False
    bannedAt: str | None = None


class DeviceView(DeviceRecord):
    online: bool = False


class DeviceBanPayload(BaseModel):
    banned: bool


class MangaOcrRegion(BaseModel):
    order: int = 0
    bbox: tuple[int, int, int, int] | None = None
    body_bbox: tuple[int, int, int, int] | None = None
    safe_box: tuple[int, int, int, int] | None = None
    source_text: str = ""
    source_direction: MangaTextDirection | None = None
    direction: MangaTextDirection | None = None
    background: str | None = None
    text_color: str | None = None
    shape: MangaRegionShape | None = None
    padding_ratio: float | None = None


class MangaOcrPagePayload(BaseModel):
    page_number: int = 0
    image_size: tuple[int, int] | None = None
    regions: list[MangaOcrRegion] = Field(default_factory=list)
    diagnostics: dict[str, Any] | None = None


class MangaTranslatedRegion(MangaOcrRegion):
    translation: str = ""


class MangaTranslatedPagePayload(BaseModel):
    page_number: int = 0
    image_size: tuple[int, int] | None = None
    target_language: str = ""
    render_mode: MangaRenderMode = "ocr_pipeline"
    source_image_file: str | None = None
    translated_image_file: str | None = None
    page_translation: str = ""
    regions: list[MangaTranslatedRegion] = Field(default_factory=list)
    diagnostics: dict[str, Any] | None = None


class MangaWorkflowResponse(BaseModel):
    mode: MangaWorkflowMode
    imageKey: str
    mimeType: Literal["image/png"] = "image/png"
    outputImageBase64: str | None = None
    inpaintedImageBase64: str | None = None
    project: dict[str, Any] = Field(default_factory=dict)
    projectDocument: dict[str, Any] = Field(default_factory=dict)
    original: dict[str, str] = Field(default_factory=dict)
    translated: dict[str, str] = Field(default_factory=dict)
    pageTranslation: str = ""
    diagnostics: dict[str, Any] = Field(default_factory=dict)


class MangaChapterTranslationPagePayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    pageNumber: int = Field(ge=1)
    outputImageBase64: str = Field(min_length=1)
    project: dict[str, Any]
    pageTranslation: str = ""


class MangaChapterTranslationPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")

    targetLanguage: str = Field(min_length=1)
    pages: list[MangaChapterTranslationPagePayload] = Field(min_length=1)


class MangaChapterTranslationResponse(BaseModel):
    bookId: str
    chapterIndex: int
    translated: bool = True
    pageCount: int
    translatedImageFiles: list[str] = Field(default_factory=list)


class AddBookPayload(BaseModel):
    sourceUrl: HttpUrl
    bookKind: BookKind
    title: str | None = None
    language: Language
    needTranslation: bool = False
    sourceId: str | None = None
    synopsis: str | None = None
    cover: str | None = None
    downloadMode: DownloadMode = "all"


class ChapterPreview(BaseModel):
    title: str
    url: str
    pageCount: int = 0
    accessRestricted: bool = False


class PreviewResponse(BaseModel):
    title: str
    author: str | None = None
    synopsis: str = ""
    cover: str | None = None
    chapterCount: int
    chapters: list[ChapterPreview]
    bookKind: BookKind = "轻小说"


class BookRecord(BaseModel):
    ownerId: str = Field(default=DEFAULT_ADMIN_USER_ID, exclude=True)
    id: str
    title: str
    sourceUrl: str
    bookKind: BookKind
    language: Language
    status: Literal["待处理", "解析中", "已下载", "已完成"]
    chapterCount: int
    translated: bool
    localPath: str
    updatedAt: str = Field(default_factory=lambda: datetime.now(UTC).isoformat().replace("+00:00", "Z"))
    synopsis: str = ""
    cover: str | None = None
    lastReadChapterIndex: int = 0
    lastReadAt: str | None = None


class PublicBookRecord(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    title: str
    sourceUrl: str
    bookKind: BookKind
    language: Language
    status: Literal["待处理", "解析中", "已下载", "已完成"]
    chapterCount: int
    translated: bool
    updatedAt: str
    synopsis: str = ""
    cover: str | None = None
    lastReadChapterIndex: int = 0
    lastReadAt: str | None = None


class LinkJobStartPayload(BaseModel):
    mode: LinkJobMode
    payload: AddBookPayload


class LinkJobLogRecord(BaseModel):
    sequence: int
    level: TaskLogLevel = "info"
    message: str
    createdAt: str


class LinkJobRecord(BaseModel):
    id: str
    mode: LinkJobMode
    status: TaskStatus
    progress: float = 0
    message: str = ""
    logs: list[LinkJobLogRecord] = Field(default_factory=list)
    preview: PreviewResponse | None = None
    book: BookRecord | None = None
    error: str | None = None
    createdAt: str
    updatedAt: str


class PublicLinkJobRecord(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    mode: LinkJobMode
    status: TaskStatus
    progress: float = 0
    message: str = ""
    logs: list[LinkJobLogRecord] = Field(default_factory=list)
    preview: PreviewResponse | None = None
    book: PublicBookRecord | None = None
    error: str | None = None
    createdAt: str
    updatedAt: str


class ChapterRecord(BaseModel):
    id: str
    index: int
    title: str
    fileName: str
    wordCount: int
    downloaded: bool = True
    translated: bool = False
    sourceUrl: str | None = None
    illustration: bool = False
    imageCount: int = 0
    imageUrls: list[str] = []
    imageFiles: list[str] = []
    translatedImageFiles: list[str] = []
    pageCount: int = 0


class PublicChapterRecord(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    index: int
    title: str
    wordCount: int
    downloaded: bool = True
    translated: bool = False
    illustration: bool = False
    imageCount: int = 0
    pageCount: int = 0


class ReadingProgressRecord(BaseModel):
    ownerId: str = Field(default=DEFAULT_ADMIN_USER_ID, exclude=True)
    bookId: str
    lastChapterIndex: int = 0
    lastScrollRatio: float = 0
    lastAnchorType: Literal["top", "paragraph", "image"] = "top"
    lastAnchorIndex: int = 0
    lastAnchorOffsetRatio: float = 0
    lastReadAt: str | None = None


class ReadingProgressPayload(BaseModel):
    chapterIndex: int
    scrollRatio: float = 0
    anchorType: Literal["top", "paragraph", "image"] = "top"
    anchorIndex: int = 0
    anchorOffsetRatio: float = 0


class ChapterActionPayload(BaseModel):
    chapterIndexes: list[int] = Field(min_length=1)


class BookExportPayload(BaseModel):
    format: Literal["txt", "text", "docx", "epub", "pdf", "images"]
    chapterIndexes: list[int] = Field(default_factory=list)


class BookExportResponse(BaseModel):
    bookId: str
    format: Literal["txt", "text", "docx", "epub", "pdf", "images"]
    artifactId: str
    fileName: str
    downloadUrl: str
    contentType: str
    sizeBytes: int
    expiresAt: str
    chapterCount: int
    fileCount: int


class ChapterExportPayload(BaseModel):
    format: Literal["txt", "text", "docx", "epub", "pdf", "images"]


class ChapterExportResponse(BaseModel):
    bookId: str
    chapterIndex: int
    format: Literal["txt", "text", "docx", "epub", "pdf", "images"]
    artifactId: str
    fileName: str
    downloadUrl: str
    contentType: str
    sizeBytes: int
    expiresAt: str
    fileCount: int


class TaskRecord(BaseModel):
    ownerId: str = Field(default=DEFAULT_ADMIN_USER_ID, exclude=True)
    id: str
    bookId: str
    taskType: TaskType
    chapterIndexes: list[int]
    status: TaskStatus
    totalCount: int
    completedCount: int = 0
    progress: float = 0
    message: str = ""
    error: str | None = None
    attempts: int = 0
    createdAt: str
    updatedAt: str


class TaskLogRecord(BaseModel):
    sequence: int
    taskId: str
    level: TaskLogLevel = "info"
    message: str
    createdAt: str


class BookDetailResponse(BaseModel):
    book: PublicBookRecord
    title: str
    author: str | None = None
    synopsis: str = ""
    addedAt: str
    totalWords: int
    downloadedChapterCount: int
    translatedChapterCount: int
    progress: ReadingProgressRecord
    chapters: list[PublicChapterRecord]


class ChapterContentResponse(BaseModel):
    bookId: str
    chapter: PublicChapterRecord
    content: str
    paragraphs: list[str]
    mode: Literal["original", "translated"] = "original"
    translatedAvailable: bool = False
    imageSources: list[str] = []
    pageTranslations: list[str] = []


class OpenAICompatibleConfig(BaseModel):
    enabled: bool = False
    baseUrl: str = "https://api.openai.com/v1"
    apiKey: str = ""
    model: str = "gpt-5.4"
    supportsVision: bool = False
    apiKeyAction: Literal["keep", "replace", "clear"] = Field(default="keep", exclude=True)


class MangaOcrConfig(BaseModel):
    enabled: bool = False
    baseUrl: str = ""
    apiKey: str = ""
    apiKeyAction: Literal["keep", "replace", "clear"] = Field(default="keep", exclude=True)


class ComicSourceConfig(BaseModel):
    email: str = ""
    password: str = ""
    passwordAction: Literal["keep", "replace", "clear"] = Field(default="keep", exclude=True)


class TranslationSettings(BaseModel):
    systemPrompt: str = """你是一位专业的文学翻译家，精通中英文互译，擅长小说、散文等文学作品的翻译。
## 翻译原则
1. **忠实原文**：准确传达原文的意思，不随意增删内容
2. **流畅自然**：译文符合目标语言的表达习惯，读起来流畅，不生硬
3. **保留风格**：保持原著的文学风格、叙事节奏和作者语气（幽默、严肃、诗意等）
4. **文化转化**：对文化特有词汇、俚语、典故进行适当的本地化处理，必要时加注说明
## 翻译要求
- 人名、地名首次出现时保留原文并附译名
- 对话翻译要符合人物性格，体现说话人的身份和语气
- 保留原文段落结构，不随意合并或拆分段落
- 专有名词（魔法、功夫、宗教等体系术语）保持统一，不前后矛盾
## 输出格式
直接输出译文，无需解释翻译过程。
如遇歧义或难以处理的表达，在译文后用【译注】标注说明。
## 翻译方向
    [中译英 / 英译中]"""
    autoTranslateNextChapters: int = 0
    downloadConcurrency: int = Field(default=3, ge=1, le=8)
    translationModel: OpenAICompatibleConfig = Field(default_factory=OpenAICompatibleConfig)
    mangaOcr: MangaOcrConfig = Field(default_factory=MangaOcrConfig)
    bika: ComicSourceConfig = Field(default_factory=ComicSourceConfig)


class OpenAICompatibleSettingsView(BaseModel):
    enabled: bool
    baseUrl: str
    model: str
    supportsVision: bool
    apiKeyConfigured: bool


class MangaOcrSettingsView(BaseModel):
    enabled: bool
    baseUrl: str
    apiKeyConfigured: bool


class ComicSourceSettingsView(BaseModel):
    emailConfigured: bool
    passwordConfigured: bool


class TranslationSettingsView(BaseModel):
    systemPrompt: str
    autoTranslateNextChapters: int
    downloadConcurrency: int
    translationModel: OpenAICompatibleSettingsView
    mangaOcr: MangaOcrSettingsView
    bika: ComicSourceSettingsView


class BookSourceRecord(BaseModel):
    id: str
    name: str
    baseUrl: str
    description: str = ""
    bookKind: BookKind | None = None
    language: Language | None = None
    enabled: bool = True
    supported: bool = True
    sampleUrl: str | None = None
    tags: list[str] = Field(default_factory=list)
    origin: SourceOrigin = "manual"
    importUrl: str | None = None
    status: SourceStatus = "unknown"
    statusMessage: str = ""
    lastCheckedAt: str | None = None
    rulePayload: dict[str, Any] | None = None
    createdAt: str = Field(default_factory=lambda: datetime.now(UTC).isoformat().replace("+00:00", "Z"))
    updatedAt: str = Field(default_factory=lambda: datetime.now(UTC).isoformat().replace("+00:00", "Z"))


class PublicBookSourceRecord(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    name: str
    baseUrl: str
    description: str = ""
    bookKind: BookKind | None = None
    language: Language | None = None
    enabled: bool = True
    supported: bool = True
    sampleUrl: str | None = None
    tags: list[str] = Field(default_factory=list)
    origin: SourceOrigin = "manual"
    status: SourceStatus = "unknown"
    statusMessage: str = ""
    lastCheckedAt: str | None = None
    createdAt: str


class BookSourceEnabledPayload(BaseModel):
    enabled: bool


class SitePluginView(BaseModel):
    id: str
    name: str
    description: str
    category: SitePluginCategory
    domains: list[str] = Field(default_factory=list)
    bookKinds: list[BookKind] = Field(default_factory=list)
    tags: list[str] = Field(default_factory=list)
    capabilities: list[str] = Field(default_factory=list)
    version: str
    enabled: bool
    defaultEnabled: bool
    accountLoggedIn: bool = False


class SitePluginUpdatePayload(BaseModel):
    enabled: bool


class SitePluginAccountView(BaseModel):
    loggedIn: bool
    expiresAt: str | None = None


class SitePluginCookieLoginPayload(BaseModel):
    cookies: SecretStr


class SitePluginLoginQrCode(BaseModel):
    flowId: str
    qrImageBase64: str
    expiresAt: str


class SitePluginLoginPoll(BaseModel):
    status: Literal["waiting", "scanned", "success", "cancelled", "expired", "error"]
    message: str
    loggedIn: bool = False


class SitePluginBookshelfImportItem(BaseModel):
    sourceId: str
    title: str
    status: Literal["imported", "skipped", "unsupported", "failed"]
    message: str = ""
    bookId: str | None = None


class SitePluginBookshelfImportJob(BaseModel):
    id: str
    pluginId: str
    status: Literal["queued", "running", "completed", "failed"]
    progress: float = 0
    message: str = ""
    discoveredCount: int = 0
    processedCount: int = 0
    importedCount: int = 0
    skippedCount: int = 0
    unsupportedCount: int = 0
    failedCount: int = 0
    items: list[SitePluginBookshelfImportItem] = Field(default_factory=list)
    error: str | None = None
    createdAt: str = Field(default_factory=lambda: datetime.now(UTC).isoformat().replace("+00:00", "Z"))
    updatedAt: str = Field(default_factory=lambda: datetime.now(UTC).isoformat().replace("+00:00", "Z"))


class TaskPageTextRecord(BaseModel):
    order: int = 0
    sourceText: str = ""
    translation: str = ""


class TaskPageResultRecord(BaseModel):
    sequence: int
    taskId: str
    chapterIndex: int
    chapterTitle: str
    pageNumber: int
    totalPages: int
    texts: list[TaskPageTextRecord] = Field(default_factory=list)
    updatedAt: str


class BuiltinSiteSearchPayload(BaseModel):
    sourceId: str
    keyword: str = Field(min_length=1, max_length=100)
    limit: int = Field(default=8, ge=1, le=20)


class BuiltinSiteSearchResult(BaseModel):
    title: str
    author: str | None = None
    synopsis: str = ""
    cover: str | None = None
    sourceUrl: str
    bookKind: BookKind | None = None
    providerName: str | None = None


class BookSourceSearchPayload(BaseModel):
    keyword: str = Field(min_length=1, max_length=100)
    sourceIds: list[str] = Field(default_factory=list)
    limit: int = Field(default=20, ge=1, le=60)


class BookSourceSearchResult(BaseModel):
    title: str
    author: str | None = None
    synopsis: str = ""
    cover: str | None = None
    sourceUrl: str
    bookKind: BookKind | None = None
    sourceId: str
    sourceName: str
    sourceLanguage: Language | None = None


class BookSourceTextImportPayload(BaseModel):
    content: str


class BookSourceUrlImportPayload(BaseModel):
    url: HttpUrl


class BookSourceCheckPayload(BaseModel):
    sourceIds: list[str] = Field(default_factory=list)


class BookSourceImportResult(BaseModel):
    imported: list[PublicBookSourceRecord] = Field(default_factory=list)
    updated: list[PublicBookSourceRecord] = Field(default_factory=list)
    duplicates: list[str] = Field(default_factory=list)
    ignored: list[str] = Field(default_factory=list)
