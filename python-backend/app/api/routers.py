from fastapi import APIRouter

from .admin import router as admin_router
from .auth import router as auth_router
from .devices import router as devices_router
from .plugin_packages import router as plugin_packages_router
from .shaoniandream_account import public_router as shaoniandream_public_router
from .shaoniandream_account import router as shaoniandream_account_router
from .translation_model import router as translation_model_router

health_router = APIRouter(tags=["health"])
system_router = APIRouter(tags=["system"])
sources_router = APIRouter(tags=["sources"])
plugins_router = APIRouter(tags=["plugins"])
plugins_router.include_router(plugin_packages_router)
plugins_router.include_router(shaoniandream_account_router)
library_router = APIRouter(tags=["library"])
tasks_router = APIRouter(tags=["tasks"])
settings_router = APIRouter(tags=["settings"])

API_ROUTERS = (
    system_router,
    auth_router,
    devices_router,
    translation_model_router,
    plugins_router,
    sources_router,
    library_router,
    tasks_router,
    settings_router,
)

PUBLIC_ROUTERS = (health_router, admin_router, shaoniandream_public_router)
