import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../app/app_scope.dart';
import '../core/state/load_state.dart';
import '../core/models/source.dart';
import '../features/sources/sources_controller.dart';
import 'mobile_action_button.dart';
import 'mobile_page.dart';
import 'mobile_settings_route.dart';
import 'mobile_state.dart';
import 'mobile_widgets.dart';

class MobileSourcesPage extends StatefulWidget {
  const MobileSourcesPage({super.key});

  @override
  State<MobileSourcesPage> createState() => _MobileSourcesPageState();
}

class _MobileSourcesPageState extends State<MobileSourcesPage> {
  final _query = TextEditingController();
  int _filter = 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _setEnabled(BookSource source, bool enabled) async {
    try {
      await AppScope.of(context).sources.setSourceEnabled(source, enabled);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更新书源失败：$error')),
      );
    }
  }

  Future<void> _import({required bool fromUrl}) => showMobileSettingsPage<void>(
        context: context,
        title: fromUrl ? '从网址导入书源' : '粘贴书源配置',
        child: _SourceImportForm(fromUrl: fromUrl),
      );

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final sources = scope.sources;
    final canManage = scope.auth.canManageServiceConfiguration;
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[sources, scope.auth]),
      builder: (context, _) {
        final needle = _query.text.trim().toLowerCase();
        final filtered = sources.sources.where((source) {
          final matches = needle.isEmpty ||
              source.name.toLowerCase().contains(needle) ||
              source.description.toLowerCase().contains(needle);
          if (!matches) return false;
          return switch (_filter) {
            1 => source.enabled,
            2 => !source.enabled,
            _ => true,
          };
        }).toList();
        return MobilePage(
          title: '书源',
          subtitle: canManage ? '修改对连接此服务的所有用户生效' : '由管理员维护，选择可用书源查找作品',
          actions: <Widget>[
            MiuixIconButton(
              onPressed: () => sources.load(),
              child: MiuixIcon(
                vector: MiuixIcons.extended.byName('refresh')!,
                contentDescription: '刷新书源',
              ),
            ),
            if (canManage) ...<Widget>[
              const SizedBox(width: 8),
              MiuixIconButton(
                onPressed: () => _import(fromUrl: true),
                child: MiuixIcon(
                  vector: MiuixIcons.extended.byName('add')!,
                  contentDescription: '导入书源',
                ),
              ),
            ],
          ],
          child: Column(
            children: <Widget>[
              MiuixTextField(
                controller: _query,
                label: '搜索书源',
                useLabelAsPlaceholder: true,
                singleLine: true,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              MiuixTabRow(
                tabs: const <String>['全部', '已启用', '已停用'],
                selectedTabIndex: _filter,
                onTabSelected: (index) => setState(() => _filter = index),
              ),
              const SizedBox(height: 14),
              if (sources.error != null && sources.sources.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text('书源更新中断，显示上次结果。${sources.error}',
                        style: TextStyle(
                            color: MiuixTheme.of(context).colors.error))),
              Expanded(
                child: _buildContent(sources, filtered, canManage),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildContent(
    SourcesController sources,
    List<BookSource> filtered,
    bool canManage,
  ) {
    if (sources.sources.isEmpty &&
        (sources.state == LoadState.idle ||
            sources.state == LoadState.loading)) {
      return const MobileLoadingView('正在加载书源');
    }
    if (sources.sources.isEmpty && sources.state == LoadState.error) {
      return MobileEmptyView(
        icon: MiuixIcon(vector: MiuixIcons.extended.byName('help')!),
        title: '无法加载书源',
        message: sources.error ?? '未知错误',
        action: MiuixTextButton('重试', onPressed: () => sources.load()),
      );
    }
    if (filtered.isEmpty) {
      return MobileEmptyView(
        icon: MiuixIcon(vector: MiuixIcons.extended.byName('layers')!),
        title: sources.sources.isEmpty ? '暂未配置书源' : '没有匹配的书源',
        message: canManage
            ? '导入并启用至少一个兼容书源后，即可在搜索页发现作品。'
            : '书源由管理员统一维护，请联系管理员添加或启用书源。',
        action: canManage && sources.sources.isEmpty
            ? MobileActionButton(
                icon: Icons.add_rounded,
                onPressed: () => _import(fromUrl: true),
                child: const Text('导入书源'),
              )
            : null,
      );
    }
    return ListView.builder(
      key: PageStorageKey<String>('mobile-sources-$_filter'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(bottom: mobileNavigationClearance(context)),
      itemCount: filtered.length + (canManage ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == filtered.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: <Widget>[
              Expanded(
                  child: MobileActionButton(
                tonal: true,
                onPressed: () => _import(fromUrl: false),
                child: const Text('粘贴配置'),
              )),
              const SizedBox(width: 10),
              Expanded(
                  child: MobileActionButton(
                onPressed: () => _import(fromUrl: true),
                child: const Text('导入网址'),
              )),
            ]),
          );
        }
        final source = filtered[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (index > 0) const Divider(height: 1),
            MiuixSwitchPreference(
              title: source.name,
              summary:
                  '${source.description.isEmpty ? source.baseUrl : source.description}\n${source.enabled ? '已启用' : '已停用'}${!source.supported ? ' · 暂不支持此书源协议' : ''}',
              value: source.enabled,
              enabled: canManage && !sources.isSourceSaving(source.id),
              onChanged: (value) => _setEnabled(source, value),
              bottomAction: source.statusMessage.isEmpty
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(source.statusMessage,
                          style: TextStyle(
                              color: source.status == 'error'
                                  ? MiuixTheme.of(context).colors.error
                                  : MiuixTheme.of(context)
                                      .colors
                                      .onBackgroundVariant)),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _SourceImportForm extends StatefulWidget {
  const _SourceImportForm({required this.fromUrl});
  final bool fromUrl;

  @override
  State<_SourceImportForm> createState() => _SourceImportFormState();
}

class _SourceImportFormState extends State<_SourceImportForm> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_loading) return;
    if (_controller.text.trim().isEmpty) {
      setState(() => _error = widget.fromUrl ? '请输入书源地址' : '请粘贴书源配置');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final scope = AppScope.of(context);
      if (!scope.auth.canManageServiceConfiguration) {
        throw StateError('需要管理员权限才能导入书源');
      }
      final sources = scope.sources;
      final result = widget.fromUrl
          ? await sources.importUrl(_controller.text.trim())
          : await sources.importText(_controller.text.trim());
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                '新增 ${result.imported.length} 个书源，更新 ${result.updated.length} 个${result.ignored.isNotEmpty ? '，忽略 ${result.ignored.length} 个不兼容配置' : ''}')));
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text('支持兼容的 JSON 或 Legado 书源。导入后会对使用此服务的用户生效。'),
          const SizedBox(height: 20),
          MiuixTextField(
            controller: _controller,
            label: widget.fromUrl ? '书源地址' : 'JSON 或 Legado 书源文本',
            useLabelAsPlaceholder: true,
            maxLines: widget.fromUrl ? 1 : 8,
            minLines: widget.fromUrl ? 1 : 5,
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(_error!,
                style: TextStyle(color: MiuixTheme.of(context).colors.error)),
          ],
          const SizedBox(height: 16),
          MobileActionButton(
            icon: Icons.add_rounded,
            busy: _loading,
            onPressed: _loading ? null : _submit,
            child: Text(_loading ? '正在导入' : '导入'),
          ),
        ],
      );
}
