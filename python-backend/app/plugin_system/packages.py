from __future__ import annotations

import hashlib
import inspect
import io
import json
import stat
import sys
import threading
import types
import uuid
import zipfile
from dataclasses import replace as replace_dataclass

from pydantic import ValidationError

from ..site_plugins import get_site_plugin, list_site_plugins
from ..site_plugins.base import SitePlugin
from ..site_plugins.registry import installed_site_plugins, replace_installed_site_plugins
from . import repository
from .manifest import (
    MAX_CODE_BYTES,
    MAX_MANIFEST_BYTES,
    MAX_PACKAGE_BYTES,
    PluginManifest,
    PluginPackageError,
)
from .usage import package_change

_LOCK = threading.RLock()


def _unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("JSON 字段重复")
        result[key] = value
    return result


def inspect_package(data: bytes) -> tuple[PluginManifest, str]:
    """Validate the archive and syntax without importing or executing its code."""
    if not data or len(data) > MAX_PACKAGE_BYTES:
        raise PluginPackageError("插件包不能为空且不能超过 2 MiB", 413)
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            entries = archive.infolist()
            if len(entries) != 2 or {item.filename for item in entries} != {"manifest.json", "plugin.py"}:
                raise PluginPackageError(
                    "ZIP 根目录必须且只能包含 manifest.json 和 plugin.py，请勿压缩外层文件夹"
                )
            for item in entries:
                mode = item.external_attr >> 16
                if (
                    item.flag_bits & 1
                    or stat.S_IFMT(mode) not in {0, stat.S_IFREG}
                    or item.compress_type not in {0, 8}
                ):
                    raise PluginPackageError("插件包不支持加密、符号链接或该压缩算法")
                limit = MAX_MANIFEST_BYTES if item.filename == "manifest.json" else MAX_CODE_BYTES
                if item.file_size > limit:
                    raise PluginPackageError("插件清单不能超过 32 KiB，入口代码不能超过 1 MiB", 413)
            raw = archive.read("manifest.json").decode("utf-8-sig")
            manifest = PluginManifest.model_validate(json.loads(raw, object_pairs_hook=_unique_json_object))
            code = archive.read("plugin.py").decode("utf-8-sig")
            compile(code, "plugin.py", "exec")
        return manifest, code
    except PluginPackageError:
        raise
    except ValidationError as error:
        fields = sorted({".".join(map(str, item["loc"])) or "manifest" for item in error.errors()})
        raise PluginPackageError(f"插件清单不符合 v1 规范，请检查：{'、'.join(fields)}") from None
    except SyntaxError as error:
        raise PluginPackageError(f"plugin.py 第 {error.lineno or 1} 行语法错误，请修正后重新打包") from None
    except (ValueError, OSError, UnicodeError, zipfile.BadZipFile, RuntimeError, NotImplementedError):
        raise PluginPackageError("插件包损坏或不是有效的 UTF-8 ZIP 插件包") from None


def _validate_conflicts(manifest: PluginManifest, *, updating: bool, allow_rollback: bool = False) -> None:
    existing = get_site_plugin(manifest.id)
    if existing is not None:
        if existing.origin == "builtin":
            raise PluginPackageError("不能覆盖内置插件，请使用独立的插件 ID", 409)
        if not updating:
            raise PluginPackageError("该插件已安装，请选择更新已有插件", 409)
        # An identical version may repair a package that cannot load after an environment change.
        if (
            not allow_rollback
            and tuple(map(int, manifest.version.split("."))) <= tuple(map(int, existing.version.split(".")))
            and not (existing.load_error and manifest.version == existing.version)
        ):
            raise PluginPackageError("更新包必须使用更高的版本号", 409)
    for plugin in list_site_plugins():
        if plugin.id == manifest.id:
            continue
        if any(
            left == right or left.endswith(f".{right}") or right.endswith(f".{left}")
            for left in manifest.domains
            for right in plugin.domains
        ):
            raise PluginPackageError(f"域名与插件“{plugin.name}”重叠，请调整 domains", 409)


def _load_runtime(manifest: PluginManifest, code: str) -> SitePlugin:
    name = f"_qingjuan_plugin_{manifest.id.replace('-', '_')}_{uuid.uuid4().hex}"
    module = types.ModuleType(name)
    module.__file__ = f"{manifest.id}/plugin.py"
    sys.modules[name] = module
    try:
        exec(compile(code, module.__file__, "exec"), module.__dict__)
        for capability in ("preview", "chapter", "search"):
            if capability not in manifest.capabilities:
                continue
            handler = getattr(module, capability, None)
            if not inspect.iscoroutinefunction(handler):
                raise PluginPackageError(f"plugin.py 必须提供 async def {capability} 函数")
            args = ("keyword", 8, object()) if capability == "search" else ("url", object())
            try:
                inspect.signature(handler).bind(*args)
            except TypeError:
                raise PluginPackageError(f"{capability} 函数参数不符合插件 API v1") from None
        return manifest.to_plugin(runtime=module)
    except BaseException as error:
        sys.modules.pop(name, None)
        if isinstance(error, PluginPackageError):
            raise
        if isinstance(error, (KeyboardInterrupt, GeneratorExit)):
            raise
        raise PluginPackageError("插件加载失败，请检查入口代码和依赖；原插件保持不变") from None


def _release_module(plugin: SitePlugin) -> None:
    if plugin.runtime is not None:
        sys.modules.pop(plugin.runtime.__name__, None)


def _install_validated(data: bytes, manifest: PluginManifest, code: str) -> SitePlugin:
    candidate = _load_runtime(manifest, code)
    previous = installed_site_plugins()
    updated = tuple(p for p in previous if p.id != candidate.id) + (candidate,)
    try:
        repository.save_package(
            manifest.id,
            manifest.model_dump_json(),
            data,
            hashlib.sha256(data).hexdigest(),
            manifest.defaultEnabled,
            publish=lambda: replace_installed_site_plugins(updated),
        )
    except BaseException as error:
        if installed_site_plugins() is not previous:
            replace_installed_site_plugins(previous)
        _release_module(candidate)
        if isinstance(error, (KeyboardInterrupt, GeneratorExit)):
            raise
        raise PluginPackageError("插件保存失败，请检查后端存储空间后重试；原插件保持不变", 503) from None
    for plugin in previous:
        if plugin.id == candidate.id:
            _release_module(plugin)
    return candidate


def install_package(data: bytes, *, replace: bool = False) -> SitePlugin:
    manifest, code = inspect_package(data)
    with _LOCK:
        _validate_conflicts(manifest, updating=replace)
        previous = get_site_plugin(manifest.id)
        domains = tuple(set(manifest.domains) | set(previous.domains if previous else ()))
        with package_change(manifest.id, domains):
            return _install_validated(data, manifest, code)


def rollback_package(plugin_id: str, *, expected_version: str, expected_sha256: str) -> SitePlugin:
    with _LOCK:
        current = repository.read_package(plugin_id)
        previous = repository.read_package(plugin_id, previous=True)
        plugin = get_site_plugin(plugin_id)
        if current is None or plugin is None or plugin.origin != "installed":
            raise PluginPackageError("只能回退已安装的外部插件", 404)
        if previous is None:
            raise PluginPackageError("没有保留的上一版本，请先导入更新版本", 409)
        if (
            plugin.version != expected_version
            or hashlib.sha256(current.package).hexdigest() != expected_sha256
        ):
            raise PluginPackageError("插件版本已改变，请刷新并重新确认回退", 409)
        if hashlib.sha256(previous.package).hexdigest() != previous.sha256:
            raise PluginPackageError("上一版本备份损坏，当前插件保持不变")
        manifest, code = inspect_package(previous.package)
        if manifest.id != plugin_id or manifest != PluginManifest.model_validate_json(previous.manifest_json):
            raise PluginPackageError("上一版本清单与插件包不一致，当前插件保持不变")
        _validate_conflicts(manifest, updating=True, allow_rollback=True)
        with package_change(plugin_id, tuple(set(plugin.domains) | set(manifest.domains))):
            return _install_validated(previous.package, manifest, code)


def uninstall_package(plugin_id: str) -> None:
    with _LOCK:
        plugin = get_site_plugin(plugin_id)
        if plugin is None:
            raise PluginPackageError("插件不存在", 404)
        if plugin.origin != "installed":
            raise PluginPackageError("内置插件只能停用，不能卸载", 409)
        with package_change(plugin_id, plugin.domains):
            previous = installed_site_plugins()
            try:
                repository.delete_package(
                    plugin_id,
                    publish=lambda: replace_installed_site_plugins(
                        tuple(p for p in previous if p.id != plugin_id)
                    ),
                )
            except Exception:
                if installed_site_plugins() is not previous:
                    replace_installed_site_plugins(previous)
                raise PluginPackageError("插件卸载失败，请检查后端存储后重试", 503) from None
            _release_module(plugin)


def clear_loaded_plugins() -> None:
    with _LOCK:
        for plugin in installed_site_plugins():
            _release_module(plugin)
        replace_installed_site_plugins(())


def load_installed_plugins() -> None:
    """Recover installed packages; one broken package must not prevent server startup."""
    with _LOCK:
        clear_loaded_plugins()
        for plugin_id, raw_manifest, data, digest in repository.read_packages():
            try:
                manifest = PluginManifest.model_validate_json(raw_manifest)
                if manifest.id != plugin_id:
                    raise ValueError("插件记录不一致")
            except (ValueError, ValidationError):
                # Preserve an uninstallable entry even if the saved manifest was damaged.
                failed = SitePlugin(
                    id=plugin_id,
                    name=plugin_id,
                    description="插件记录损坏，请卸载后重新导入",
                    category="general",
                    domains=(),
                    book_kinds=(),
                    tags=(),
                    preview_handler="installed",
                    chapter_handler=None,
                    default_enabled=False,
                    origin="installed",
                    load_error="插件清单损坏，请卸载后重新导入",
                )
                replace_installed_site_plugins((*installed_site_plugins(), failed))
                continue
            plugin = manifest.to_plugin()
            try:
                if hashlib.sha256(data).hexdigest() != digest:
                    raise PluginPackageError("插件包完整性校验失败，请重新导入")
                checked, code = inspect_package(data)
                if checked != manifest:
                    raise PluginPackageError("插件清单与安装记录不一致，请重新导入")
                _validate_conflicts(manifest, updating=False)
                plugin = _load_runtime(manifest, code)
            except PluginPackageError as error:
                plugin = replace_dataclass(plugin, load_error=str(error))
            replace_installed_site_plugins((*installed_site_plugins(), plugin))
        from .. import db

        db.invalidate_site_plugin_states()
