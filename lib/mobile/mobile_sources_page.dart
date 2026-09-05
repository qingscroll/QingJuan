import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../app/app_scope.dart';
import '../core/state/load_state.dart';
import '../features/sources/sources_controller.dart';
import 'mobile_page.dart';
import 'mobile_preferences.dart';
import 'mobile_sheet.dart';
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

  Future<void> _import({required bool fromUrl}) async {
    final controller = TextEditingController();
    String? error;
    await showMobileSheet<void>(
      context: context,
      title: fromUrl ? '从网址导入书源' : '粘贴书源配置',
      child: StatefulBuilder(
        builder: (context, setSheetState) {
          var loading = false;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              MiuixTextField(
                controller: controller,
                label: fromUrl ? '书源地址' : 'JSON 或 Legado 书源文本',
                useLabelAsPlaceholder: true,
                maxLines: fromUrl ? 1 : 8,
                minLines: fromUrl ? 1 : 5,
              ),
              if (error != null) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  error!,
                  style: TextStyle(color: MiuixTheme.of(context).colors.error),
                ),
              ],
              const SizedBox(height: 16),
              MiuixButton(
                onPressed: loading
                    ? null
                    : () async {
                        setSheetState(() => loading = true);
                        try {
                          final sources = AppScope.of(context).sources;
                          if (fromUrl) {
                            await sources.importUrl(controller.text);
                          } else {
                            await sources.importText(controller.text);
                          }
                          if (context.mounted) Navigator.pop(context);
                        } catch (exception) {
                          setSheetState(() {
                            loading = false;
                            error = '$exception';
                          });
                        }
                      },
                colors: MiuixButtonDefaults.buttonColorsPrimary(context),
                child: MiuixText(loading ? '正在导入' : '导入'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final sources = scope.sources;
    final canManage = scope.auth.canManageServiceConfiguration;
    return AnimatedBuilder(
      animation: sources,
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
          subtitle: '${sources.sources.where((s) => s.enabled).length} 个书源已启用',
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
    List<dynamic> filtered,
    bool canManage,
  ) {
    if (sources.state == LoadState.idle || sources.state == LoadState.loading) {
      return const MobileLoadingView('正在加载书源');
    }
    if (sources.state == LoadState.error) {
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
            ? MiuixButton(
                onPressed: () => _import(fromUrl: true),
                colors: MiuixButtonDefaults.buttonColorsPrimary(context),
                child: const MiuixText('导入书源'),
              )
            : null,
      );
    }
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 18),
      children: <Widget>[
        MobileCard(
          color: MiuixTheme.of(context).colors.tertiaryContainer,
          child: Row(
            children: <Widget>[
              _metric('${sources.sources.length}', '全部'),
              _metric(
                '${sources.sources.where((s) => s.enabled).length}',
                '已启用',
              ),
              _metric(
                '${sources.sources.where((s) => s.supported).length}',
                '可搜索',
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        MobilePreferenceGroup(
          title: '书源列表',
          children: <Widget>[
            for (final source in filtered)
              MiuixSwitchPreference(
                title: source.name,
                summary: source.description.isEmpty
                    ? source.baseUrl
                    : source.description,
                value: source.enabled,
                enabled: canManage && !sources.isSourceSaving(source.id),
                onChanged: (value) => sources.setSourceEnabled(source, value),
                bottomAction: source.statusMessage.isEmpty
                    ? null
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: MobilePill(
                          source.statusMessage,
                          color: source.status == 'error'
                              ? MiuixTheme.of(context).colors.error
                              : null,
                        ),
                      ),
              ),
          ],
        ),
        if (canManage) ...<Widget>[
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: MiuixButton(
                  onPressed: () => _import(fromUrl: false),
                  child: const MiuixText('粘贴配置'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: MiuixButton(
                  onPressed: () => _import(fromUrl: true),
                  colors: MiuixButtonDefaults.buttonColorsPrimary(context),
                  child: const MiuixText('导入网址'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _metric(String value, String label) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(value, style: MiuixTheme.of(context).textStyles.title3),
          const SizedBox(height: 3),
          Text(
            label,
            style: MiuixTheme.of(context).textStyles.footnote1.copyWith(
                  color: MiuixTheme.of(context).colors.onSurfaceVariantSummary,
                ),
          ),
        ],
      ),
    );
  }
}

