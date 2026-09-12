from fastapi import APIRouter

from .admin import router as admin_router
from .annotations import router as annotations_router
from .auth import router as auth_router
from .backups import router as backups_router
from .book_updates import router as book_updates_router
from .devices import router as devices_router
from .discovery import router as discovery_router
from .library_metadata import router as library_metadata_router
from .link_imports import router as link_imports_router
from .plugin_packages import router as plugin_packages_router
from .preview_reading import router as preview_reading_router
from .reading_progress import router as reading_progress_router
from .resource_limits import admin_router as admin_resource_router
from .resource_limits import router as resource_router
from .shaoniandream_account import public_router as shaoniandream_public_router
from .shaoniandream_account import router as shaoniandream_account_router
from .storage import cleanup_router as storage_cleanup_router
from .storage import router as storage_router
from .task_control import router as task_control_router
from .translation_model import router as translation_model_router
from .translation_quality import router as translation_quality_router

health_router = APIRouter(tags=["health"])
system_router = APIRouter(tags=["system"])
sources_router = APIRouter(tags=["sources"])
plugins_router = APIRouter(tags=["plugins"])
plugins_router.include_router(plugin_packages_router)
plugins_router.include_router(shaoniandream_account_router)
library_router = APIRouter(tags=["library"])
library_router.include_router(preview_reading_router)
library_router.include_router(link_imports_router)
library_router.include_router(reading_progress_router)
library_router.include_router(library_metadata_router)
library_router.include_router(translation_quality_router)
library_router.include_router(book_updates_router)
library_router.include_router(annotations_router)
library_router.include_router(storage_router)
tasks_router = APIRouter(tags=["tasks"])
tasks_router.include_router(task_control_router)
settings_router = APIRouter(tags=["settings"])

API_ROUTERS = (
    system_router,
    auth_router,
    devices_router,
    discovery_router,
    translation_model_router,
    plugins_router,
    sources_router,
    library_router,
    tasks_router,
    settings_router,
    resource_router,
)

READER_PUBLIC_ROUTERS = (health_router, shaoniandream_public_router)
PUBLIC_ROUTERS = (*READER_PUBLIC_ROUTERS, admin_router, admin_resource_router)
MANAGEMENT_ROUTERS = (backups_router, storage_cleanup_router)
