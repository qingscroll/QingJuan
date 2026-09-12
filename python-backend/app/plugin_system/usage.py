"""Reserve active plugin calls and reject code replacement until users are idle."""

from __future__ import annotations

import asyncio
import json
import threading
from contextlib import contextmanager

from ..site_plugins import get_site_plugin
from ..site_plugins.base import SitePlugin, host_matches
from .manifest import PluginPackageError

_LOCK = threading.RLock()
_ACTIVE: dict[tuple[str, str], int] = {}
_CHANGING: set[tuple[str, str]] = set()


async def run_package_operation(function, *args, **kwargs):
    """A caller cancelling cannot stop a Python import or SQLite transaction thread."""
    task = asyncio.create_task(asyncio.to_thread(function, *args, **kwargs))
    try:
        return await asyncio.shield(task)
    except asyncio.CancelledError:
        while not task.done():
            try:
                await asyncio.shield(task)
            except asyncio.CancelledError:
                continue
            except Exception:
                break
        if task.done() and not task.cancelled():
            task.exception()
        raise


def _key(plugin_id: str) -> tuple[str, str]:
    from .. import db

    return str(db.DB_PATH), plugin_id


@contextmanager
def active_call(plugin: SitePlugin):
    key = _key(plugin.id)
    with _LOCK:
        if key in _CHANGING:
            raise ValueError("插件正在维护，请稍后重新发起操作")
        current = get_site_plugin(plugin.id)
        if current is None or current.runtime is not plugin.runtime:
            raise ValueError("插件版本已改变，请重新发起操作")
        _ACTIVE[key] = _ACTIVE.get(key, 0) + 1
    try:
        yield
    finally:
        with _LOCK:
            remaining = _ACTIVE[key] - 1
            if remaining:
                _ACTIVE[key] = remaining
            else:
                del _ACTIVE[key]


def active_count(plugin_id: str) -> int:
    with _LOCK:
        return _ACTIVE.get(_key(plugin_id), 0)


def _has_running_work(domains: tuple[str, ...]) -> bool:
    from .. import db

    with db.get_connection() as conn:
        for (url,) in conn.execute("""SELECT b.source_url FROM tasks t JOIN books b ON b.id=t.book_id
            WHERE t.status IN ('running', 'pause_requested', 'cancel_requested')"""):
            if host_matches(url, domains):
                return True
        for (raw,) in conn.execute("SELECT payload FROM link_jobs WHERE status='running'"):
            try:
                url = json.loads(raw).get("sourceUrl", "")
                if isinstance(url, str) and host_matches(url, domains):
                    return True
            except (ValueError, AttributeError):
                # Corrupt running-job state needs repair before changing its parser.
                return True
    return False


@contextmanager
def package_change(plugin_id: str, domains: tuple[str, ...]):
    key = _key(plugin_id)
    with _LOCK:
        if _ACTIVE.get(key, 0) or key in _CHANGING:
            raise PluginPackageError("该插件仍有调用正在执行，请等待完成后重试", 409)
        _CHANGING.add(key)
    try:
        if _has_running_work(domains):
            raise PluginPackageError("该插件仍有任务正在执行，请暂停任务或等待导入完成后重试", 409)
        yield
    finally:
        with _LOCK:
            _CHANGING.discard(key)
