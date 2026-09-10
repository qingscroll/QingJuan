from ..models import SitePluginView
from ..site_plugins.base import SitePlugin


def plugin_view(plugin: SitePlugin, enabled: bool, *, account_logged_in: bool = False) -> SitePluginView:
    return SitePluginView(
        id=plugin.id,
        name=plugin.name,
        description=plugin.description,
        category=plugin.category,
        domains=list(plugin.domains),
        bookKinds=list(plugin.book_kinds),
        tags=list(plugin.tags),
        capabilities=list(plugin.capabilities),
        version=plugin.version,
        enabled=enabled,
        defaultEnabled=plugin.default_enabled,
        accountLoggedIn=account_logged_in,
        origin=plugin.origin,
        author=plugin.author,
        apiVersion=plugin.api_version,
        loadError=plugin.load_error,
    )
