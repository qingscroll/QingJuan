from __future__ import annotations

import ipaddress
import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from ..site_plugins.base import SitePlugin

API_VERSION = 1
MAX_PACKAGE_BYTES = 2 * 1024 * 1024
MAX_MANIFEST_BYTES = 32 * 1024
MAX_CODE_BYTES = 1024 * 1024


class PluginPackageError(ValueError):
    def __init__(self, message: str, status_code: int = 422):
        super().__init__(message)
        self.status_code = status_code


class PluginManifest(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)

    schemaVersion: Literal[1]
    apiVersion: Literal[1]
    id: str = Field(min_length=3, max_length=64, pattern=r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
    name: str = Field(min_length=1, max_length=80)
    version: str = Field(pattern=r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$", max_length=32)
    author: str = Field(min_length=1, max_length=100)
    description: str = Field(min_length=1, max_length=1000)
    category: Literal["novel", "manga"]
    domains: list[str] = Field(min_length=1, max_length=20)
    networkDomains: list[str] = Field(default_factory=list, max_length=40)
    bookKinds: list[Literal["长小说", "轻小说", "漫画"]] = Field(min_length=1, max_length=3)
    language: Literal["中文", "日文", "英文"] = "中文"
    tags: list[str] = Field(default_factory=list, max_length=12)
    capabilities: list[Literal["preview", "chapter", "search", "on_demand"]] = Field(
        min_length=1, max_length=4
    )
    entrypoint: Literal["plugin.py"]
    defaultEnabled: bool = True

    @field_validator("schemaVersion", "apiVersion", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("协议版本必须为整数")
        return value

    @field_validator("name", "author", "description")
    @classmethod
    def nonblank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("字段不能为空")
        return value.strip()

    @field_validator("domains", "networkDomains")
    @classmethod
    def valid_domains(cls, values: list[str]) -> list[str]:
        result = []
        for value in values:
            domain = value.lower()
            if len(domain) > 253 or not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", domain):
                raise ValueError("域名必须是纯 ASCII 主机名，不含协议、端口、路径或通配符")
            if "." not in domain or any(
                not label or len(label) > 63 or label.startswith("-") or label.endswith("-")
                for label in domain.split(".")
            ):
                raise ValueError("域名格式无效")
            try:
                ipaddress.ip_address(domain)
            except ValueError:
                pass
            else:
                raise ValueError("域名不能使用 IP 地址")
            if domain in result:
                raise ValueError("域名重复")
            result.append(domain)
        return result

    @field_validator("tags")
    @classmethod
    def valid_tags(cls, values: list[str]) -> list[str]:
        if any(not value.strip() or len(value) > 40 for value in values):
            raise ValueError("标签必须为 1–40 个字符")
        return values

    @model_validator(mode="after")
    def consistent_capabilities(self) -> PluginManifest:
        if "preview" not in self.capabilities or len(set(self.capabilities)) != len(self.capabilities):
            raise ValueError("必须声明 preview 且能力不能重复")
        if "on_demand" in self.capabilities and "chapter" not in self.capabilities:
            raise ValueError("on_demand 需要 chapter")
        if (self.category == "manga" and self.bookKinds != ["漫画"]) or (
            self.category == "novel" and "漫画" in self.bookKinds
        ):
            raise ValueError("漫画分类必须且只能声明漫画，小说分类不能声明漫画")
        if len(set(self.bookKinds)) != len(self.bookKinds):
            raise ValueError("作品类型不能重复")
        return self

    def to_plugin(self, **extra) -> SitePlugin:
        return SitePlugin(
            id=self.id,
            name=self.name,
            description=self.description,
            category=self.category,
            domains=tuple(self.domains),
            book_kinds=tuple(self.bookKinds),
            tags=tuple(self.tags),
            version=self.version,
            default_enabled=self.defaultEnabled,
            preview_handler="installed",
            chapter_handler="installed" if "chapter" in self.capabilities else None,
            search_handler="installed" if "search" in self.capabilities else None,
            supports_on_demand="on_demand" in self.capabilities,
            origin="installed",
            author=self.author,
            api_version=self.apiVersion,
            network_domains=tuple(dict.fromkeys(self.domains + self.networkDomains)),
            language=self.language,
            **extra,
        )
