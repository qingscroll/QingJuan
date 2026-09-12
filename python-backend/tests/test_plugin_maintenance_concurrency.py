from __future__ import annotations

import asyncio
import threading

import pytest
import test_plugin_packages

from app.plugin_system import packages, runtime
from app.plugin_system.maintenance import inspect_installed_plugin, rollback_plugin
from app.plugin_system.usage import active_count, run_package_operation
from app.site_plugins import get_site_plugin

isolated_plugins = test_plugin_packages.isolated_plugins
make_package = test_plugin_packages.make_package


def test_rollback_rechecks_domain_conflicts_created_after_an_update():
    packages.install_package(make_package())
    packages.install_package(make_package("1.1.0", domains=["new.example.test"]), replace=True)
    packages.install_package(make_package(id="another-plugin"))
    report = inspect_installed_plugin("example-novel")
    assert report.rollbackAvailable  # Static validity does not reserve a domain.
    with pytest.raises(packages.PluginPackageError) as error:
        rollback_plugin("example-novel", expected_version=report.version, expected_sha256=report.sha256)
    assert error.value.status_code == 409
    assert get_site_plugin("example-novel").version == "1.1.0"


@pytest.mark.asyncio
async def test_cancelling_a_request_drains_the_running_package_transaction():
    entered = threading.Event()
    release = threading.Event()

    def operation():
        entered.set()
        assert release.wait(5)
        return packages.install_package(make_package())

    task = asyncio.create_task(run_package_operation(operation))
    assert await asyncio.to_thread(entered.wait, 5)
    task.cancel()
    await asyncio.sleep(0)
    task.cancel()
    await asyncio.sleep(0)
    assert not task.done()
    release.set()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert get_site_plugin("example-novel").version == "1.0.0"


@pytest.mark.asyncio
async def test_cancelled_parser_call_releases_its_maintenance_reservation():
    plugin = packages.install_package(
        make_package(
            capabilities=["preview"],
            code="""
import asyncio
entered = asyncio.Event()
async def preview(url, context):
    entered.set()
    await asyncio.Event().wait()
""",
        )
    )
    task = asyncio.create_task(runtime.preview_plugin(plugin, "https://novels.example.test/book"))
    await plugin.runtime.entered.wait()
    assert active_count(plugin.id) == 1
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    assert active_count(plugin.id) == 0
    packages.uninstall_package(plugin.id)
