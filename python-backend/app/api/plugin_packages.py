from __future__ import annotations

import asyncio
import hashlib
from typing import Annotated

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, Response, UploadFile

from .. import db
from ..admin_auth import require_admin_write_access
from ..models import (
    BookSourceSearchPayload,
    BookSourceSearchResult,
    SitePluginPackageInspection,
    SitePluginView,
)
from ..plugin_system.manifest import MAX_PACKAGE_BYTES, PluginPackageError
from ..plugin_system.packages import inspect_package, install_package, uninstall_package
from ..plugin_system.runtime import search_plugin
from ..plugin_system.views import plugin_view
from ..site_plugins import get_site_plugin, list_site_plugins
from ..user_auth import require_user_access

router = APIRouter(tags=["plugins"])
SEARCH_TIMEOUT_SECONDS = 35


async def _read_package(file: UploadFile) -> bytes:
    try:
        data = await file.read(MAX_PACKAGE_BYTES + 1)
    finally:
        await file.close()
    if len(data) > MAX_PACKAGE_BYTES:
        raise HTTPException(status_code=413, detail="插件包不能超过 2 MiB")
    return data


@router.post(
    "/plugins/inspect",
    response_model=SitePluginPackageInspection,
    dependencies=[Depends(require_admin_write_access)],
)
async def inspect_plugin_package(file: Annotated[UploadFile, File()]) -> SitePluginPackageInspection:
    data = await _read_package(file)
    try:
        manifest, _ = await asyncio.to_thread(inspect_package, data)
    except PluginPackageError as error:
        raise HTTPException(status_code=error.status_code, detail=str(error)) from None
    existing = get_site_plugin(manifest.id)
    return SitePluginPackageInspection(
        plugin=plugin_view(manifest.to_plugin(), manifest.defaultEnabled),
        installedVersion=existing.version if existing else None,
        sha256=hashlib.sha256(data).hexdigest(),
    )


@router.post(
    "/plugins/import",
    response_model=SitePluginView,
    status_code=201,
    dependencies=[Depends(require_admin_write_access)],
)
async def import_plugin_package(
    file: Annotated[UploadFile, File()],
    replace: Annotated[bool, Form()] = False,
) -> SitePluginView:
    data = await _read_package(file)
    try:
        plugin = await asyncio.to_thread(install_package, data, replace=replace)
    except PluginPackageError as error:
        raise HTTPException(status_code=error.status_code, detail=str(error)) from None
    return plugin_view(plugin, db.is_site_plugin_enabled(plugin.id))


@router.delete("/plugins/{plugin_id}", status_code=204, dependencies=[Depends(require_admin_write_access)])
async def delete_plugin_package(plugin_id: str) -> Response:
    try:
        await asyncio.to_thread(uninstall_package, plugin_id)
    except PluginPackageError as error:
        raise HTTPException(status_code=error.status_code, detail=str(error)) from None
    return Response(status_code=204)


@router.post("/plugins/search", response_model=list[BookSourceSearchResult])
async def search_installed_plugins(
    payload: BookSourceSearchPayload, request: Request
) -> list[BookSourceSearchResult]:
    require_user_access(request)
    keyword = payload.keyword.strip()
    if not keyword:
        raise HTTPException(status_code=422, detail="搜索关键词不能为空")
    plugins = [
        plugin
        for plugin in list_site_plugins()
        if plugin.origin == "installed"
        and plugin.search_handler
        and db.is_site_plugin_enabled(plugin.id)
        and (not payload.sourceIds or plugin.id in payload.sourceIds)
    ]
    if not plugins:
        raise HTTPException(status_code=400, detail="请先导入并启用支持搜索的插件")
    semaphore = asyncio.Semaphore(4)

    async def search_one(plugin):
        async with semaphore:
            results = await search_plugin(plugin, keyword, min(payload.limit, 20))
        return [
            BookSourceSearchResult(
                **result.model_dump(exclude={"providerName"}),
                sourceId="",
                sourceName=plugin.name,
                sourceLanguage=plugin.language,
            )
            for result in results
        ]

    tasks = [asyncio.create_task(search_one(plugin)) for plugin in plugins]
    try:
        done, _ = await asyncio.wait(tasks, timeout=SEARCH_TIMEOUT_SECONDS)
        outcomes = await asyncio.gather(*(task for task in tasks if task in done), return_exceptions=True)
    finally:
        for task in tasks:
            if not task.done():
                task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
    successful = [result for result in outcomes if isinstance(result, list)]
    if not successful:
        raise HTTPException(status_code=502, detail="插件搜索失败，请检查站点状态或更新插件后重试")
    seen = set()
    results = []
    for outcome in successful:
        for result in outcome:
            if result.sourceUrl not in seen:
                results.append(result)
                seen.add(result.sourceUrl)
    return results[: payload.limit]
