from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class StorageError(ValueError):
    def __init__(self, message: str, status_code: int = 409):
        super().__init__(message)
        self.status_code = status_code


class StorageCategory(BaseModel):
    id: str
    label: str
    bytes: int
    fileCount: int
    cleanable: bool
    description: str


class BookStorageReport(BaseModel):
    bookId: str
    totalBytes: int
    protectedBytes: int
    reclaimableBytes: int
    fileCount: int
    categories: list[StorageCategory]
    warnings: list[str]


class StorageArtifact(BaseModel):
    id: str
    format: str
    sizeBytes: int
    createdAt: str


class StorageCleanupPreview(BaseModel):
    bookId: str
    cleanupId: str
    confirmationToken: str
    totalBytes: int
    fileCount: int
    artifacts: list[StorageArtifact]
    warnings: list[str]


class StorageCleanupResult(BaseModel):
    bookId: str
    deletedBytes: int
    deletedFiles: int
    warnings: list[str]
    storage: BookStorageReport


class StoragePreviewPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")
    categories: list[Literal["exports"]] = Field(min_length=1, max_length=1)


class StorageCleanupPayload(BaseModel):
    model_config = ConfigDict(extra="forbid")
    cleanupId: str = Field(pattern=r"^[0-9a-f]{32}$")
    confirmationToken: str = Field(pattern=r"^[0-9a-f]{64}$")
