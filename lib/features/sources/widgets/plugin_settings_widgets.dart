import 'package:fluent_ui/fluent_ui.dart';

import '../../../core/models/site_plugin.dart';
import '../../../core/models/source.dart';
import '../../../shared/app_surface.dart';
import '../../../shared/responsive.dart';
import '../../../shared/smooth_scroll.dart';

enum SitePluginStatusFilter { all, enabled, disabled }

extension SitePluginStatusFilterLabel on SitePluginStatusFilter {
  String get label => switch (this) {
        SitePluginStatusFilter.all => '全部状态',
        SitePluginStatusFilter.enabled => '已启用',
        SitePluginStatusFilter.disabled => '已停用',
      };

  bool matches(SitePlugin plugin) => switch (this) {
        SitePluginStatusFilter.all => true,
        SitePluginStatusFilter.enabled => plugin.enabled,
        SitePluginStatusFilter.disabled => !plugin.enabled,
      };
}

const sitePluginCategoryOrder = <String>['novel', 'manga', 'general'];

String sitePluginCategoryLabel(String category) => switch (category) {
      'novel' => '小说解析器',
      'manga' => '漫画解析器',
      'general' => '通用回退',
      _ => '其他解析器',
    };

String sitePluginCapabilityLabel(String capability) => switch (capability) {
      'preview' => '作品解析',
      'chapter' => '章节下载',
      'search' => '站内搜索',
      'on_demand' => '边看边下',
      'account_login' => '账号登录',
      'cookie_login' => 'Cookie 登录',
      'bookshelf_import' => '书架导入',
      _ => capability,
    };

Map<String, List<SitePlugin>> groupSitePlugins(
  Iterable<SitePlugin> plugins,
) {
  final byCategory = <String, List<SitePlugin>>{};
  for (final plugin in plugins) {
    byCategory.putIfAbsent(plugin.category, () => <SitePlugin>[]).add(plugin);
  }
  final result = <String, List<SitePlugin>>{};
  for (final category in sitePluginCategoryOrder) {
    final values = byCategory.remove(category);
    if (values != null && values.isNotEmpty) result[category] = values;
  }
  final remaining = byCategory.keys.toList()..sort();
  for (final category in remaining) {
    result[category] = byCategory[category]!;
  }
  return result;
}

class PluginOverview extends StatelessWidget {
  const PluginOverview({
    required this.plugins,
    super.key,
  });

  final List<SitePlugin> plugins;

  @override
  Widget build(BuildContext context) {
    final enabledPlugins = plugins.where((plugin) => plugin.enabled).length;
    final disabledPlugins = plugins.length - enabledPlugins;
    final theme = FluentTheme.of(context);
    final mobile = usesMobileUi(context);
    final metrics = Row(
      children: <Widget>[
        Expanded(
          child: AppMetric(
            label: '内置模块',
            value: '${plugins.length}',
          ),
        ),
        Expanded(
          child: AppMetric(
            label: '已启用',
            value: '$enabledPlugins',
            accented: true,
          ),
        ),
        Expanded(
          child: AppMetric(
            label: '已停用',
            value: '$disabledPlugins',
          ),
        ),
      ],
    );
    final summary = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const AccentIcon(FluentIcons.plug_connected),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '站点解析插件',
                style: theme.typography.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                enabledPlugins == 0
                    ? '当前后端没有启用的解析器。'
                    : '开关状态保存在当前后端；停用不会删除模块或已缓存章节。',
                style: theme.typography.caption?.copyWith(
                  color: theme.resources.textFillColorSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return AppSurface(
      padding: EdgeInsets.all(mobile ? 16 : 14),
      tone: AppSurfaceTone.muted,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (mobile || constraints.maxWidth < 620) {
            return Column(
              children: <Widget>[
                summary,
                const SizedBox(height: 16),
                metrics,
              ],
            );
          }
          return Row(
            children: <Widget>[
              Expanded(flex: 5, child: summary),
              const SizedBox(width: 24),
              Expanded(flex: 4, child: metrics),
            ],
          );
        },
      ),
    );
  }
}

class PluginFilterBar extends StatelessWidget {
  const PluginFilterBar({
    required this.searchController,
    required this.filter,
    required this.resultCount,
    required this.onQueryChanged,
    required this.onFilterChanged,
    super.key,
  });

  final TextEditingController searchController;
  final SitePluginStatusFilter filter;
  final int resultCount;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<SitePluginStatusFilter> onFilterChanged;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final search = TextBox(
      key: const ValueKey('plugin-search-box'),
      controller: searchController,
      magnifierConfiguration: textInputMagnifierConfiguration(context),
      placeholder: '搜索名称、域名、标签或能力',
      prefix: const Padding(
        padding: EdgeInsets.only(left: 10),
        child: Icon(FluentIcons.search),
      ),
      onChanged: onQueryChanged,
    );
    final status = SizedBox(
      width: 148,
      child: ComboBox<SitePluginStatusFilter>(
        key: const ValueKey('plugin-status-filter'),
        value: filter,
        isExpanded: true,
        items: SitePluginStatusFilter.values
            .map(
              (value) => ComboBoxItem<SitePluginStatusFilter>(
                value: value,
                child: Text(value.label),
              ),
            )
            .toList(growable: false),
        onChanged: (value) {
          if (value != null) onFilterChanged(value);
        },
      ),
    );
    final count = Text(
      '$resultCount 个结果',
      key: const ValueKey('plugin-result-count'),
      style: theme.typography.caption?.copyWith(
        color: theme.resources.textFillColorSecondary,
      ),
    );
    if (usesMobileUi(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          search,
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              status,
              const Spacer(),
              count,
            ],
          ),
        ],
      );
    }
    return Row(
      children: <Widget>[
        Expanded(child: search),
        const SizedBox(width: 10),
        status,
        const SizedBox(width: 12),
        count,
      ],
    );
  }
}

class _PluginScrollRegion extends StatefulWidget {
  const _PluginScrollRegion({
    required this.scrollbarKey,
    required this.builder,
    super.key,
  });

  final Key scrollbarKey;
  final Widget Function(ScrollController controller) builder;

  @override
  State<_PluginScrollRegion> createState() => _PluginScrollRegionState();
}

class _PluginScrollRegionState extends State<_PluginScrollRegion> {
  final ScrollController _controller = QjScrollController(
    debugLabel: 'plugin-scroll-region',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: Scrollbar(
          key: widget.scrollbarKey,
          controller: _controller,
          thumbVisibility: false,
          interactive: true,
          style: const ScrollbarThemeData(
            thickness: 2,
            hoveringThickness: 6,
            crossAxisMargin: 2,
            hoveringCrossAxisMargin: 2,
            padding: EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            hoveringPadding: EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          ),
          child: widget.builder(_controller),
        ),
      );
}

class PluginCatalog extends StatelessWidget {
  const PluginCatalog({
    required this.plugins,
    required this.selectedId,
    required this.onSelected,
    super.key,
  });

  final List<SitePlugin> plugins;
  final String? selectedId;
  final ValueChanged<SitePlugin> onSelected;

  @override
  Widget build(BuildContext context) {
    final groups = groupSitePlugins(plugins);
    return AppSurface(
      key: const ValueKey('plugin-catalog-pane'),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      child: _PluginScrollRegion(
        scrollbarKey: const ValueKey('plugin-catalog-scrollbar'),
        builder: (controller) => ListView(
          key: const ValueKey('plugin-catalog'),
          controller: controller,
          primary: false,
          padding: const EdgeInsetsDirectional.only(end: 12),
          children: <Widget>[
            for (final entry in groups.entries) ...<Widget>[
              _PluginGroupHeader(
                label: sitePluginCategoryLabel(entry.key),
                count: entry.value.length,
              ),
              for (final plugin in entry.value)
                _PluginNavigationTile(
                  plugin: plugin,
                  selected: plugin.id == selectedId,
                  onPressed: () => onSelected(plugin),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PluginGroupHeader extends StatelessWidget {
  const _PluginGroupHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 8, 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: theme.typography.caption?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text('$count', style: theme.typography.caption),
        ],
      ),
    );
  }
}

class _PluginNavigationTile extends StatelessWidget {
  const _PluginNavigationTile({
    required this.plugin,
    required this.selected,
    required this.onPressed,
  });

  final SitePlugin plugin;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final statusColor = plugin.enabled
        ? theme.accentColor.defaultBrushFor(theme.brightness)
        : theme.resources.textFillColorSecondary;
    return AppSurface(
      key: ValueKey<String>('plugin-nav-${plugin.id}'),
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      borderRadius: 5,
      selected: selected,
      onPressed: onPressed,
      child: Row(
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  plugin.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.body?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : null,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  plugin.domains.isEmpty ? '通用网页回退' : plugin.domains.first,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.caption?.copyWith(
                    color: theme.resources.textFillColorSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            plugin.enabled ? '启用' : '停用',
            style: theme.typography.caption?.copyWith(color: statusColor),
          ),
        ],
      ),
    );
  }
}

class SitePluginTile extends StatelessWidget {
  const SitePluginTile({
    required this.plugin,
    required this.saving,
    required this.onChanged,
    this.onDetails,
    super.key,
  });

  final SitePlugin plugin;
  final bool saving;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onDetails;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final details =
        plugin.domains.isEmpty ? '适用于未匹配专用模块的网页' : plugin.domains.join(' · ');
    return AppSurface(
      key: ValueKey<String>('site-plugin-${plugin.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      tone: AppSurfaceTone.elevated,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AccentIcon(
            FluentIcons.plug_connected,
            enabled: plugin.enabled,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        plugin.name,
                        style: theme.typography.bodyLarge
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    StatusPill(sitePluginCategoryLabel(plugin.category)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  plugin.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.caption,
                ),
                const SizedBox(height: 5),
                Text(
                  details,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.caption?.copyWith(
                    color: theme.resources.textFillColorSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final capability in plugin.capabilities)
                      StatusPill(sitePluginCapabilityLabel(capability)),
                    for (final tag in plugin.tags.take(2)) StatusPill(tag),
                    StatusPill('v${plugin.version}'),
                  ],
                ),
                if (onDetails != null) ...<Widget>[
                  const SizedBox(height: 4),
                  HyperlinkButton(
                    key: ValueKey<String>('site-plugin-details-${plugin.id}'),
                    onPressed: onDetails,
                    child: const Text('查看详情'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 14),
          Semantics(
            label: '${plugin.name}站点插件',
            toggled: plugin.enabled,
            child: SizedBox(
              width: 42,
              height: 28,
              child: saving
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: ProgressRing(strokeWidth: 2.4),
                      ),
                    )
                  : ToggleSwitch(
                      key: ValueKey<String>('site-plugin-toggle-${plugin.id}'),
                      checked: plugin.enabled,
                      onChanged: onChanged,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class PluginDetailsPane extends StatelessWidget {
  const PluginDetailsPane({
    required this.plugin,
    required this.saving,
    required this.onChanged,
    this.dialogMode = false,
    this.actions,
    super.key,
  });

  final SitePlugin plugin;
  final bool saving;
  final ValueChanged<bool> onChanged;
  final bool dialogMode;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final domains =
        plugin.domains.isEmpty ? const <String>['未匹配专用模块时使用'] : plugin.domains;
    return AppSurface(
      key: ValueKey<String>('plugin-details-pane-${plugin.id}'),
      padding: const EdgeInsets.all(18),
      child: _PluginScrollRegion(
        key: ValueKey<String>('plugin-details-scroll-region-${plugin.id}'),
        scrollbarKey: ValueKey<String>('plugin-details-scrollbar-${plugin.id}'),
        builder: (controller) => SingleChildScrollView(
          controller: controller,
          primary: false,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    AccentIcon(
                      FluentIcons.plug_connected,
                      enabled: plugin.enabled,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            plugin.name,
                            style: theme.typography.subtitle?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: <Widget>[
                              StatusPill(
                                plugin.enabled ? '已启用' : '已停用',
                                accented: plugin.enabled,
                              ),
                              StatusPill(
                                sitePluginCategoryLabel(plugin.category),
                              ),
                              StatusPill('v${plugin.version}'),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    _PluginToggle(
                      plugin: plugin,
                      saving: saving,
                      onChanged: onChanged,
                      keyPrefix: dialogMode
                          ? 'site-plugin-dialog-toggle'
                          : 'site-plugin-toggle',
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(plugin.description, style: theme.typography.body),
                const SizedBox(height: 12),
                Text(plugin.isInstalled
                    ? '来源：导入插件 · 作者：${plugin.author} · API v${plugin.apiVersion}'
                    : '来源：内置插件'),
                if (plugin.loadError != null) ...[
                  const SizedBox(height: 12),
                  InfoBar(
                      title: const Text('插件加载失败'),
                      content: Text(plugin.loadError!),
                      severity: InfoBarSeverity.error),
                ],
                const SizedBox(height: 16),
                AppSurface(
                  padding: const EdgeInsets.all(12),
                  tone: AppSurfaceTone.muted,
                  child: Text(
                    '此解析器内置于当前后端。这里只保存启停状态，不会安装、删除或在线更新代码。',
                    style: theme.typography.caption?.copyWith(
                      color: theme.resources.textFillColorSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                if (actions != null) ...<Widget>[
                  actions!,
                  const SizedBox(height: 18),
                ],
                _PluginMetadataSection(
                  label: '匹配域名',
                  values: domains,
                ),
                _PluginMetadataSection(
                  label: '作品类型',
                  values: plugin.bookKinds.isEmpty
                      ? const <String>['未限制']
                      : plugin.bookKinds,
                ),
                _PluginMetadataSection(
                  label: '提供能力',
                  values: plugin.capabilities
                      .map(sitePluginCapabilityLabel)
                      .toList(growable: false),
                ),
                _PluginMetadataSection(
                  label: '标签',
                  values:
                      plugin.tags.isEmpty ? const <String>['无'] : plugin.tags,
                ),
                _PluginMetadataSection(
                  label: '模块标识',
                  values: <String>[plugin.id],
                ),
                _PluginMetadataSection(
                  label: '默认状态',
                  values: <String>[
                    plugin.defaultEnabled ? '默认启用' : '默认停用',
                  ],
                  last: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PluginAccountActions extends StatelessWidget {
  const PluginAccountActions({
    required this.plugin,
    required this.onLogin,
    this.onCookieLogin,
    required this.onImportBookshelf,
    required this.onLogout,
    super.key,
  });

  final SitePlugin plugin;
  final VoidCallback onLogin;
  final VoidCallback? onCookieLogin;
  final VoidCallback onImportBookshelf;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final loggedIn = plugin.accountLoggedIn;
    final actionsEnabled = plugin.enabled;
    return AppSurface(
      key: ValueKey<String>('plugin-account-actions-${plugin.id}'),
      padding: const EdgeInsets.all(14),
      tone: AppSurfaceTone.muted,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                FluentIcons.contact,
                size: 18,
                color: loggedIn
                    ? theme.accentColor
                    : theme.resources.textFillColorSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '站点账号',
                  style: theme.typography.bodyStrong,
                ),
              ),
              StatusPill(
                loggedIn ? '已登录' : '未登录',
                accented: loggedIn,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            actionsEnabled
                ? loggedIn
                    ? '登录态仅保存在当前后端进程内，可把账号书架一键加入青卷。'
                    : '使用站点官方 App 扫码登录后，可读取当前账号书架。'
                : '请先启用此插件，再使用账号登录与书架导入。',
            style: theme.typography.caption?.copyWith(
              color: theme.resources.textFillColorSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (!loggedIn)
                FilledButton(
                  key: ValueKey<String>('plugin-login-${plugin.id}'),
                  onPressed: actionsEnabled ? onLogin : null,
                  child: const Text('扫码登录'),
                ),
              if (!loggedIn && onCookieLogin != null)
                Button(
                  key: ValueKey<String>('plugin-cookie-login-${plugin.id}'),
                  onPressed: actionsEnabled ? onCookieLogin : null,
                  child: const Text('Cookie 登录'),
                ),
              FilledButton(
                key: ValueKey<String>('plugin-bookshelf-import-${plugin.id}'),
                onPressed:
                    actionsEnabled && loggedIn ? onImportBookshelf : null,
                child: const Text('一键添加账号书架'),
              ),
              if (loggedIn)
                Button(
                  key: ValueKey<String>('plugin-logout-${plugin.id}'),
                  onPressed: onLogout,
                  child: const Text('退出账号'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PluginToggle extends StatelessWidget {
  const _PluginToggle({
    required this.plugin,
    required this.saving,
    required this.onChanged,
    required this.keyPrefix,
  });

  final SitePlugin plugin;
  final bool saving;
  final ValueChanged<bool> onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => Semantics(
        label: '${plugin.name}站点插件',
        toggled: plugin.enabled,
        child: SizedBox(
          width: 42,
          height: 28,
          child: saving
              ? const Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: ProgressRing(strokeWidth: 2.4),
                  ),
                )
              : ToggleSwitch(
                  key: ValueKey<String>('$keyPrefix-${plugin.id}'),
                  checked: plugin.enabled,
                  onChanged: onChanged,
                ),
        ),
      );
}

class _PluginMetadataSection extends StatelessWidget {
  const _PluginMetadataSection({
    required this.label,
    required this.values,
    this.last = false,
  });

  final String label;
  final List<String> values;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.typography.caption?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.resources.textFillColorSecondary,
            ),
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: values.map(StatusPill.new).toList(growable: false),
          ),
        ],
      ),
    );
  }
}

class SourceRuleTile extends StatelessWidget {
  const SourceRuleTile({
    required this.source,
    required this.saving,
    required this.onChanged,
    super.key,
  });

  final BookSource source;
  final bool saving;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final mobile = usesMobileUi(context);
    return AppSurface(
      key: ValueKey<String>('source-rule-${source.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      tone: AppSurfaceTone.elevated,
      child: Row(
        children: <Widget>[
          AccentIcon(FluentIcons.database, enabled: source.enabled),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  source.name,
                  style: theme.typography.bodyLarge
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  source.description.isEmpty
                      ? source.baseUrl
                      : source.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.caption,
                ),
                if (source.tags.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: source.tags
                        .take(3)
                        .map(StatusPill.new)
                        .toList(growable: false),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (!mobile) ...<Widget>[
            Flexible(
              child: StatusPill(
                source.statusMessage.isEmpty
                    ? source.status
                    : source.statusMessage,
                accented: source.enabled,
              ),
            ),
            const SizedBox(width: 12),
          ],
          Semantics(
            label: '${source.name}外部书源',
            toggled: source.enabled,
            child: saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: ProgressRing(strokeWidth: 2.4),
                  )
                : ToggleSwitch(
                    key: ValueKey<String>('source-rule-toggle-${source.id}'),
                    checked: source.enabled,
                    onChanged: onChanged,
                  ),
          ),
        ],
      ),
    );
  }
}

class SourceRulesEmptyState extends StatelessWidget {
  const SourceRulesEmptyState({
    required this.onPaste,
    required this.onImport,
    super.key,
  });

  final VoidCallback onPaste;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final compact = usesMobileUi(context);
    const message = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '暂未导入外部书源',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        SizedBox(height: 5),
        Text('可以粘贴 JSON、Legado 书源文本，或从可信网址导入。'),
      ],
    );
    final actions = <Widget>[
      Button(onPressed: onPaste, child: const Text('粘贴配置')),
      FilledButton(onPressed: onImport, child: const Text('导入网址')),
    ];
    return AppSurface(
      tone: AppSurfaceTone.muted,
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const AccentIcon(FluentIcons.database),
                const SizedBox(height: 12),
                message,
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Expanded(child: actions[0]),
                    const SizedBox(width: 8),
                    Expanded(child: actions[1]),
                  ],
                ),
              ],
            )
          : Row(
              children: <Widget>[
                const AccentIcon(FluentIcons.database),
                const SizedBox(width: 14),
                const Expanded(child: message),
                const SizedBox(width: 12),
                actions[0],
                const SizedBox(width: 8),
                actions[1],
              ],
            ),
    );
  }
}
