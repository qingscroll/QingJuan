import 'dart:async';
import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';

import '../../app/app_scope.dart';
import '../../core/models/site_plugin.dart';
import '../../core/state/load_state.dart';
import '../../shared/app_surface.dart';
import '../../shared/feedback_widgets.dart';
import '../../shared/mobile_sheet.dart';
import '../../shared/page_frame.dart';
import '../../shared/desktop_subpage.dart';
import '../../shared/responsive.dart';
import '../../shared/smooth_scroll.dart';
import 'sources_controller.dart';
import 'widgets/plugin_browser_login_dialog.dart';
import 'widgets/plugin_settings_widgets.dart';
import 'widgets/plugin_package_widgets.dart';
import 'widgets/plugin_maintenance_widgets.dart';

class PluginsPage extends StatefulWidget {
  const PluginsPage({this.onBack, super.key});

  final VoidCallback? onBack;

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  static const _desktopContentMaxWidth = 1680.0;
  static const _desktopSplitMinWidth = 960.0;
  static const _desktopCatalogMinWidth = 320.0;
  static const _desktopCatalogMaxWidth = 400.0;

  final TextEditingController _searchController = TextEditingController();
  SitePluginStatusFilter _statusFilter = SitePluginStatusFilter.all;
  String? _selectedPluginId;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _setPluginEnabled(
    BuildContext context,
    SitePlugin plugin,
    bool enabled,
  ) async {
    try {
      await AppScope.of(context).sources.setPluginEnabled(plugin, enabled);
    } catch (error) {
      if (!context.mounted) return;
      displayInfoBar(
        context,
        builder: (_, __) => InfoBar(
          title: const Text('插件状态保存失败'),
          content: Text('$error'),
          severity: InfoBarSeverity.error,
        ),
      );
    }
  }

  List<SitePlugin> _visiblePlugins(List<SitePlugin> plugins) {
    final query = _searchController.text.trim().toLowerCase();
    return plugins.where((plugin) {
      if (!_statusFilter.matches(plugin)) return false;
      if (query.isEmpty) return true;
      final searchable = <String>[
        plugin.id,
        plugin.name,
        plugin.description,
        plugin.category,
        sitePluginCategoryLabel(plugin.category),
        plugin.version,
        ...plugin.domains,
        ...plugin.bookKinds,
        ...plugin.tags,
        ...plugin.capabilities,
        ...plugin.capabilities.map(sitePluginCapabilityLabel),
      ].join('\n').toLowerCase();
      return searchable.contains(query);
    }).toList(growable: false);
  }

  SitePlugin? _findPlugin(List<SitePlugin> plugins, String? id) {
    if (id == null) return null;
    for (final plugin in plugins) {
      if (plugin.id == id) return plugin;
    }
    return null;
  }

  Future<void> _showPluginDetails(
    BuildContext context,
    SitePlugin plugin,
  ) async {
    final controller = AppScope.of(context).sources;
    Widget details(BuildContext routeContext) {
      final content = AnimatedBuilder(
        animation: controller,
        builder: (_, __) {
          final current = _findPlugin(controller.plugins, plugin.id) ?? plugin;
          return PluginDetailsPane(
            plugin: current,
            saving: controller.isPluginSaving(current.id),
            dialogMode: true,
            actions: _pluginActions(context, current, controller),
            onChanged: (enabled) =>
                _setPluginEnabled(context, current, enabled),
          );
        },
      );
      if (usesMobileUi(routeContext)) {
        return MobileSheet(
          title: '插件详情',
          subtitle: plugin.name,
          onClose: () => Navigator.of(routeContext).pop(),
          child: SizedBox(
            height: (MediaQuery.sizeOf(routeContext).height * 0.66)
                .clamp(360.0, 600.0),
            child: content,
          ),
        );
      }
      return ContentDialog(
        title: const Text('插件详情'),
        content: SizedBox(width: 560, height: 480, child: content),
        actions: <Widget>[
          Button(
            onPressed: () => Navigator.of(routeContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      );
    }

    if (usesMobileUi(context)) {
      await showMobileSheet<void>(context: context, builder: details);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: details,
    );
  }

  Widget? _pluginActions(
    BuildContext context,
    SitePlugin plugin,
    SourcesController controller,
  ) {
    final supportsLogin = plugin.capabilities.contains('account_login');
    final supportsImport = plugin.capabilities.contains('bookshelf_import');
    if (plugin.isInstalled) {
      return Wrap(spacing: 8, runSpacing: 8, children: [
        if (AppScope.of(context).backend.capabilities['pluginMaintenance'] ==
            true)
          PluginMaintenanceButton(plugin: plugin, controller: controller),
        PluginPackageUninstallButton(plugin: plugin, controller: controller),
      ]);
    }
    if (!supportsLogin && !supportsImport) return null;
    return PluginAccountActions(
      plugin: plugin,
      onLogin: () => _showPluginLogin(context, plugin, controller),
      onCookieLogin: plugin.capabilities.contains('cookie_login')
          ? () => _showPluginCookieLogin(context, plugin, controller)
          : null,
      onImportBookshelf: () =>
          _showBookshelfImport(context, plugin, controller),
      onLogout: () => _logoutPluginAccount(context, plugin, controller),
    );
  }

  Future<void> _showPluginLogin(
    BuildContext context,
    SitePlugin plugin,
    SourcesController controller,
  ) {
    Widget builder(BuildContext _) =>
        plugin.capabilities.contains('browser_login')
            ? PluginBrowserLoginDialog(plugin: plugin, controller: controller)
            : _PluginQrLoginDialog(
                plugin: plugin,
                controller: controller,
              );
    if (usesMobileUi(context)) {
      return showMobileSheet<void>(context: context, builder: builder);
    }
    return showDialog<void>(
      context: context,
      builder: builder,
    );
  }

  Future<void> _showPluginCookieLogin(
    BuildContext context,
    SitePlugin plugin,
    SourcesController controller,
  ) async {
    Widget builder(BuildContext _) => _PluginCookieLoginDialog(
          plugin: plugin,
          controller: controller,
        );
    final Future<bool?> result = usesMobileUi(context)
        ? showMobileSheet<bool>(context: context, builder: builder)
        : showDialog<bool>(context: context, builder: builder);
    final loggedIn = await result;
    if (loggedIn != true || !context.mounted) return;
    displayInfoBar(
      context,
      builder: (_, __) => InfoBar(
        title: Text('${plugin.name}账号已连接'),
        content: const Text('现在可以一键添加当前账号书架。'),
        severity: InfoBarSeverity.success,
      ),
    );
  }

  Future<void> _showBookshelfImport(
    BuildContext context,
    SitePlugin plugin,
    SourcesController controller,
  ) {
    Widget builder(BuildContext _) => _PluginBookshelfImportDialog(
          plugin: plugin,
          controller: controller,
          onCompleted: () => AppScope.of(context).library.load(silent: true),
        );
    if (usesMobileUi(context)) {
      return showMobileSheet<void>(
        context: context,
        barrierDismissible: false,
        builder: builder,
      );
    }
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: builder,
    );
  }

  Future<void> _logoutPluginAccount(
    BuildContext context,
    SitePlugin plugin,
    SourcesController controller,
  ) async {
    try {
      await controller.logoutPluginAccount(plugin.id);
      if (!context.mounted) return;
      displayInfoBar(
        context,
        builder: (_, __) => const InfoBar(
          title: Text('已退出站点账号'),
          content: Text('后端内存中的登录会话已清除。'),
          severity: InfoBarSeverity.success,
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      displayInfoBar(
        context,
        builder: (_, __) => InfoBar(
          title: const Text('退出账号失败'),
          content: Text('$error'),
          severity: InfoBarSeverity.error,
        ),
      );
    }
  }

  Widget _emptyResults() => const EmptyView(
        icon: FluentIcons.search,
        title: '没有匹配的插件',
        message: '请更换搜索词或状态筛选。',
      );

  Widget _buildGroupedList(
    BuildContext context,
    List<SitePlugin> plugins,
    SourcesController controller,
  ) {
    final groups = groupSitePlugins(plugins);
    return QjScrollControllerBuilder(
      debugLabel: 'plugins-grouped-list',
      builder: (context, scrollController) => ListView(
        key: const ValueKey('plugin-grouped-list'),
        controller: scrollController,
        children: <Widget>[
          PluginOverview(plugins: controller.plugins),
          const SizedBox(height: 16),
          PluginFilterBar(
            searchController: _searchController,
            filter: _statusFilter,
            resultCount: plugins.length,
            onQueryChanged: (_) => setState(() {}),
            onFilterChanged: (value) => setState(() => _statusFilter = value),
          ),
          const SizedBox(height: 18),
          if (plugins.isEmpty)
            _emptyResults()
          else
            for (final entry in groups.entries) ...<Widget>[
              SectionTitle(
                sitePluginCategoryLabel(entry.key),
                trailing: Text('${entry.value.length} 个'),
              ),
              for (final plugin in entry.value)
                SitePluginTile(
                  plugin: plugin,
                  saving: controller.isPluginSaving(plugin.id),
                  onChanged: (enabled) =>
                      _setPluginEnabled(context, plugin, enabled),
                  onDetails: () => _showPluginDetails(context, plugin),
                ),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }

  Widget _buildReady(
    BuildContext context,
    List<SitePlugin> allPlugins,
    SourcesController controller,
  ) {
    final visiblePlugins = _visiblePlugins(allPlugins);
    return LayoutBuilder(
      builder: (context, constraints) {
        final split = !usesMobileUi(context) &&
            constraints.maxWidth >= _desktopSplitMinWidth;
        if (!split) {
          return _buildGroupedList(context, visiblePlugins, controller);
        }
        final catalogWidth = (constraints.maxWidth * 0.28)
            .clamp(_desktopCatalogMinWidth, _desktopCatalogMaxWidth)
            .toDouble();
        final selected = _findPlugin(visiblePlugins, _selectedPluginId) ??
            (visiblePlugins.isEmpty ? null : visiblePlugins.first);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            PluginOverview(plugins: allPlugins),
            const SizedBox(height: 14),
            PluginFilterBar(
              searchController: _searchController,
              filter: _statusFilter,
              resultCount: visiblePlugins.length,
              onQueryChanged: (_) => setState(() {}),
              onFilterChanged: (value) => setState(() => _statusFilter = value),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: visiblePlugins.isEmpty
                  ? _emptyResults()
                  : Row(
                      key: const ValueKey('plugin-workspace'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        SizedBox(
                          width: catalogWidth,
                          child: PluginCatalog(
                            plugins: visiblePlugins,
                            selectedId: selected?.id,
                            onSelected: (plugin) => setState(
                              () => _selectedPluginId = plugin.id,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: PluginDetailsPane(
                            plugin: selected!,
                            saving: controller.isPluginSaving(selected.id),
                            actions:
                                _pluginActions(context, selected, controller),
                            onChanged: (enabled) => _setPluginEnabled(
                              context,
                              selected,
                              enabled,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context).sources;
    final page = AnimatedBuilder(
      animation: controller,
      builder: (context, _) => PageFrame(
        title: usesMobileUi(context) ? '站点插件' : '插件配置',
        subtitle: usesMobileUi(context)
            ? '管理搜索、导入和账号书架所使用的解析器。'
            : '导入、更新和管理当前后端使用的站点解析器。',
        command: PluginPackageImportButton(controller: controller),
        scrollable: false,
        maxContentWidth: usesMobileUi(context) ? null : _desktopContentMaxWidth,
        desktopHorizontalPadding: 24,
        compactHeader: Row(
          children: <Widget>[
            if (widget.onBack != null) ...<Widget>[
              Tooltip(
                message: '返回设置',
                child: IconButton(
                  key: const ValueKey('mobile-plugins-back-button'),
                  icon: const Icon(
                    FluentIcons.back,
                    semanticLabel: '返回设置',
                  ),
                  onPressed: widget.onBack,
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '站点插件',
                    style: FluentTheme.of(context).typography.title?.copyWith(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  Text(
                    '${controller.plugins.where((plugin) => plugin.enabled).length} 个站点插件已启用',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FluentTheme.of(context).typography.caption,
                  ),
                ],
              ),
            ),
          ],
        ),
        child: Expanded(
          child: switch (controller.state) {
            LoadState.idle ||
            LoadState.loading =>
              const LoadingView(label: '正在加载插件配置'),
            LoadState.error => ErrorView(
                message: controller.error ?? '未知错误',
                onRetry: controller.load,
              ),
            _ when controller.plugins.isEmpty => const EmptyView(
                icon: FluentIcons.plug_connected,
                title: '后端没有提供插件清单',
                message: '请更新后端后重试。',
              ),
            _ => _buildReady(context, controller.plugins, controller),
          },
        ),
      ),
    );
    return usesMobileUi(context) || widget.onBack == null
        ? page
        : DesktopSubpage(
            title: '插件配置',
            showContentTitle: false,
            maxContentWidth: _desktopContentMaxWidth,
            onBack: widget.onBack,
            backLabel: '返回设置',
            child: page,
          );
  }
}

class _PluginQrLoginDialog extends StatefulWidget {
  const _PluginQrLoginDialog({
    required this.plugin,
    required this.controller,
  });

  final SitePlugin plugin;
  final SourcesController controller;

  @override
  State<_PluginQrLoginDialog> createState() => _PluginQrLoginDialogState();
}

class _PluginQrLoginDialogState extends State<_PluginQrLoginDialog> {
  SitePluginLoginQrCode? _qrCode;
  Timer? _poller;
  bool _polling = false;
  String _message = '正在获取登录二维码…';
  String? _error;
  String? _terminalStatus;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _poller?.cancel();
    setState(() {
      _qrCode = null;
      _error = null;
      _terminalStatus = null;
      _message = '正在获取登录二维码…';
    });
    try {
      final qrCode = await widget.controller.startPluginLogin(widget.plugin.id);
      if (!mounted) return;
      setState(() {
        _qrCode = qrCode;
        _message = '请使用${widget.plugin.name}官方 App 扫码并在手机上确认';
      });
      _poller = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_poll()),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  Future<void> _poll() async {
    final qrCode = _qrCode;
    if (qrCode == null || _polling) return;
    _polling = true;
    try {
      final result = await widget.controller.pollPluginLogin(
        widget.plugin.id,
        qrCode.flowId,
      );
      if (!mounted) return;
      setState(() {
        _message = result.message;
        _terminalStatus = result.isTerminal ? result.status : null;
      });
      if (result.isTerminal) _poller?.cancel();
    } catch (error) {
      _poller?.cancel();
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _terminalStatus = 'error';
      });
    } finally {
      _polling = false;
    }
  }

  Widget _qrImage() {
    final value = _qrCode?.qrImageBase64 ?? '';
    if (value.isEmpty) return const ProgressRing();
    try {
      final payload = value.contains(',') ? value.split(',').last : value;
      return Image.memory(
        base64Decode(payload),
        width: 240,
        height: 240,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        semanticLabel: '${widget.plugin.name}登录二维码',
      );
    } on FormatException {
      return const Text('二维码数据无效，请重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final success = _terminalStatus == 'success';
    final canRetry = _error != null ||
        _terminalStatus == 'cancelled' ||
        _terminalStatus == 'expired' ||
        _terminalStatus == 'error';
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (_error == null && !success) _qrImage(),
        if (success)
          const Icon(
            FluentIcons.completed_solid,
            size: 54,
            color: Color(0xFF107C10),
          ),
        const SizedBox(height: 16),
        Text(
          _error ?? _message,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          '登录凭据只保存在当前青卷后端进程内，不会显示或写入客户端设置。',
          textAlign: TextAlign.center,
          style: FluentTheme.of(context).typography.caption,
        ),
        if (widget.plugin.capabilities.contains('cookie_login')) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            '若当前网络无法获取二维码，请关闭此窗口并选择“Cookie 登录”。',
            textAlign: TextAlign.center,
            style: FluentTheme.of(context).typography.caption,
          ),
        ],
      ],
    );
    final actions = <Widget>[
      if (canRetry)
        Button(
          key: const ValueKey('plugin-login-retry'),
          onPressed: _start,
          child: const Text('重新获取'),
        ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(success ? '完成' : '关闭'),
      ),
    ];
    if (usesMobileUi(context)) {
      return MobileSheet(
        title: '${widget.plugin.name}扫码登录',
        subtitle: '使用官方 App 完成账号授权',
        onClose: () => Navigator.of(context).pop(),
        actions: actions,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
          child: body,
        ),
      );
    }
    return ContentDialog(
      title: Text('${widget.plugin.name}扫码登录'),
      content: SizedBox(width: 420, child: body),
      actions: actions,
    );
  }
}

class _PluginCookieLoginDialog extends StatefulWidget {
  const _PluginCookieLoginDialog({
    required this.plugin,
    required this.controller,
  });

  final SitePlugin plugin;
  final SourcesController controller;

  @override
  State<_PluginCookieLoginDialog> createState() =>
      _PluginCookieLoginDialogState();
}

class _PluginCookieLoginDialogState extends State<_PluginCookieLoginDialog> {
  final TextEditingController _cookieController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _cookieController.clear();
    _cookieController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final cookies = _cookieController.text.trim();
    _cookieController.clear();
    if (cookies.isEmpty) {
      setState(
        () => _error = '请粘贴已登录${widget.plugin.name}网页请求中的完整 Cookie。',
      );
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.controller.loginPluginWithCookies(widget.plugin.id, cookies);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '在浏览器登录${widget.plugin.name}后，从开发者工具的网络请求中复制完整 Cookie 请求头。'
          '该内容只提交给当前青卷后端并保存在进程内存中。',
        ),
        const SizedBox(height: 14),
        PasswordBox(
          key: const ValueKey('plugin-cookie-login-input'),
          controller: _cookieController,
          enabled: !_submitting,
          autofocus: true,
          revealMode: PasswordRevealMode.peekAlways,
          placeholder: 'Cookie 请求头',
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 10),
          InfoBar(
            title: const Text('登录失败'),
            content: Text(_error!),
            severity: InfoBarSeverity.error,
          ),
        ],
      ],
    );
    final actions = <Widget>[
      Button(
        onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('plugin-cookie-login-submit'),
        onPressed: _submitting ? null : _submit,
        child: _submitting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: ProgressRing(strokeWidth: 2.4),
              )
            : const Text('验证并登录'),
      ),
    ];
    if (usesMobileUi(context)) {
      return MobileSheet(
        title: '${widget.plugin.name} Cookie 登录',
        subtitle: '登录信息只发送至当前后端',
        onClose: _submitting ? null : () => Navigator.of(context).pop(false),
        actions: actions,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
          child: body,
        ),
      );
    }
    return ContentDialog(
      title: Text('${widget.plugin.name} Cookie 登录'),
      content: SizedBox(width: 480, child: body),
      actions: actions,
    );
  }
}

class _PluginBookshelfImportDialog extends StatefulWidget {
  const _PluginBookshelfImportDialog({
    required this.plugin,
    required this.controller,
    required this.onCompleted,
  });

  final SitePlugin plugin;
  final SourcesController controller;
  final Future<void> Function() onCompleted;

  @override
  State<_PluginBookshelfImportDialog> createState() =>
      _PluginBookshelfImportDialogState();
}

class _PluginBookshelfImportDialogState
    extends State<_PluginBookshelfImportDialog> {
  SitePluginBookshelfImportJob? _job;
  Timer? _poller;
  bool _polling = false;
  bool _notifiedCompletion = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _poller?.cancel();
    setState(() {
      _job = null;
      _error = null;
      _notifiedCompletion = false;
    });
    try {
      final job =
          await widget.controller.startPluginBookshelfImport(widget.plugin.id);
      if (!mounted) return;
      setState(() => _job = job);
      _poller = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(_poll()),
      );
      await _poll();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  Future<void> _poll() async {
    final job = _job;
    if (job == null || _polling || !job.isActive) return;
    _polling = true;
    try {
      final next = await widget.controller.fetchPluginBookshelfImport(
        widget.plugin.id,
        job.id,
      );
      if (!mounted) return;
      setState(() => _job = next);
      if (!next.isActive) {
        _poller?.cancel();
        if (!_notifiedCompletion) {
          _notifiedCompletion = true;
          await widget.onCompleted();
        }
      }
    } catch (error) {
      _poller?.cancel();
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      _polling = false;
    }
  }

  Widget _resultList(SitePluginBookshelfImportJob job) {
    if (job.items.isEmpty) return const SizedBox.shrink();
    return ListView.builder(
      itemCount: job.items.length,
      itemBuilder: (context, index) {
        final item = job.items[index];
        final label = switch (item.status) {
          'imported' => '新增',
          'skipped' => '跳过',
          'unsupported' => '暂不支持',
          _ => '失败',
        };
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(width: 42, child: StatusPill(label)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(item.title),
                    if (item.message.isNotEmpty)
                      Text(
                        item.message,
                        style: FluentTheme.of(context).typography.caption,
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;
    final active = _error == null && (job?.isActive ?? true);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (_error != null)
          InfoBar(
            title: const Text('书架导入失败'),
            content: Text(_error!),
            severity: InfoBarSeverity.error,
          )
        else if (job == null)
          const Expanded(
            child: Center(child: ProgressRing()),
          )
        else ...<Widget>[
          ProgressBar(value: job.progress.clamp(0, 100)),
          const SizedBox(height: 10),
          Text(job.message),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              StatusPill('发现 ${job.discoveredCount} 本'),
              StatusPill('新增 ${job.importedCount} 本'),
              StatusPill('跳过 ${job.skippedCount} 本'),
              StatusPill('暂不支持 ${job.unsupportedCount} 本'),
              StatusPill('失败 ${job.failedCount} 本'),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(child: _resultList(job)),
        ],
      ],
    );
    final actions = <Widget>[
      if (_error != null)
        Button(
          key: const ValueKey('plugin-bookshelf-import-retry'),
          onPressed: _start,
          child: const Text('重试'),
        ),
      FilledButton(
        onPressed: active ? null : () => Navigator.of(context).pop(),
        child: const Text('完成'),
      ),
    ];
    if (usesMobileUi(context)) {
      return MobileSheet(
        title: '添加${widget.plugin.name}账号书架',
        subtitle: '逐本去重并显示处理结果',
        onClose: active ? null : () => Navigator.of(context).pop(),
        actions: actions,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
          child: SizedBox(
            height:
                (MediaQuery.sizeOf(context).height * 0.52).clamp(330.0, 520.0),
            child: body,
          ),
        ),
      );
    }
    return ContentDialog(
      title: Text('添加${widget.plugin.name}账号书架'),
      content: SizedBox(width: 560, height: 430, child: body),
      actions: actions,
    );
  }
}
