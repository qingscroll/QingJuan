"""Installed-package diagnostics without execution or external site requests."""

from __future__ import annotations

import hashlib
import inspect
import platform
from datetime import UTC, datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict

from .. import db
from ..site_plugins import get_site_plugin
from ..site_plugins.base import SitePlugin
from . import repository
from .manifest import API_VERSION, PluginManifest, PluginPackageError
from .packages import _LOCK, inspect_package, rollback_package
from .usage import active_count


class PluginCheck(BaseModel):
    code: str
    label: str
    status: Literal["passed", "failed", "warning"]
    message: str


class PluginMaintenanceReport(BaseModel):
    model_config = ConfigDict(extra="forbid")
    pluginId: str
    version: str
    sha256: str
    apiVersion: int
    supportedApiVersion: int = API_VERSION
    pythonVersion: str
    enabled: bool
    compatible: bool
    activeCalls: int
    rollbackVersion: str | None = None
    rollbackSha256: str | None = None
    rollbackAvailable: bool = False
    checkedAt: str
    checks: list[PluginCheck]


def _validate_stored(record: repository.StoredPackage) -> PluginManifest:
    if hashlib.sha256(record.package).hexdigest() != record.sha256:
        raise PluginPackageError("包完整性检查失败")
    manifest, _ = inspect_package(record.package)
    saved = PluginManifest.model_validate_json(record.manifest_json)
    if manifest.id != record.plugin_id or manifest != saved:
        raise PluginPackageError("保存的清单与包内容不一致")
    return manifest


def _runtime_compatible(plugin: SitePlugin) -> bool:
    if plugin.load_error or plugin.runtime is None:
        return False
    for capability in ("preview", "chapter", "search"):
        if capability not in plugin.capabilities:
            continue
        handler = vars(plugin.runtime).get(capability)
        if not inspect.iscoroutinefunction(handler):
            return False
        try:
            arguments = ("keyword", 1, None) if capability == "search" else ("url", None)
            inspect.signature(handler).bind(*arguments)
        except (ValueError, TypeError):
            return False
    return True


def inspect_installed_plugin(plugin_id: str) -> PluginMaintenanceReport:
    with _LOCK:
        plugin = get_site_plugin(plugin_id)
        current = repository.read_package(plugin_id)
        if plugin is None or plugin.origin != "installed" or current is None:
            raise PluginPackageError("只能检查已安装的外部插件", 404)
        checks = []
        static_ok = True
        try:
            manifest = _validate_stored(current)
            if manifest.version != plugin.version or manifest.apiVersion != plugin.api_version:
                raise PluginPackageError("当前加载版本与保存记录不一致")
        except ValueError:
            static_ok = False
        checks.append(
            PluginCheck(
                code="package",
                label="安装包与协议",
                status="passed" if static_ok else "failed",
                message="SHA-256、清单、包结构和 Python 语法通过检查"
                if static_ok
                else "安装包损坏、清单不一致或协议不兼容，请重新导入可信插件包",
            )
        )
        runtime_ok = _runtime_compatible(plugin)
        checks.append(
            PluginCheck(
                code="runtime",
                label="已加载运行接口",
                status="passed" if runtime_ok else "failed",
                message="清单声明的异步处理器及参数签名有效"
                if runtime_ok
                else "插件未正常加载或处理器签名不兼容，请更新修复或回退上一版本",
            )
        )
        previous = repository.read_package(plugin_id, previous=True)
        rollback_version = rollback_digest = None
        if previous is not None:
            try:
                previous_manifest = _validate_stored(previous)
                rollback_version, rollback_digest = previous_manifest.version, previous.sha256
            except ValueError:
                checks.append(
                    PluginCheck(
                        code="previous",
                        label="上一版本",
                        status="warning",
                        message="上一版本保存记录损坏，暂时无法回退；当前插件不受影响",
                    )
                )
        checks.append(
            PluginCheck(
                code="scope",
                label="自检范围",
                status="warning",
                message="自检不访问第三方站点，不重新执行插件顶层代码；站点解析效果仍需通过实际导入验证",
            )
        )
        return PluginMaintenanceReport(
            pluginId=plugin.id,
            version=plugin.version,
            sha256=hashlib.sha256(current.package).hexdigest(),
            apiVersion=plugin.api_version,
            pythonVersion=platform.python_version(),
            enabled=db.is_site_plugin_enabled(plugin.id),
            compatible=static_ok and runtime_ok,
            activeCalls=active_count(plugin.id),
            rollbackVersion=rollback_version,
            rollbackSha256=rollback_digest,
            rollbackAvailable=rollback_version is not None,
            checkedAt=datetime.now(UTC).isoformat().replace("+00:00", "Z"),
            checks=checks,
        )


def rollback_plugin(plugin_id: str, *, expected_version: str, expected_sha256: str) -> SitePlugin:
    try:
        return rollback_package(plugin_id, expected_version=expected_version, expected_sha256=expected_sha256)
    except PluginPackageError:
        raise
    except (ValueError, OSError, RuntimeError):
        raise PluginPackageError("插件回退失败，当前版本保持不变，请检查安装记录后重试", 503) from None
