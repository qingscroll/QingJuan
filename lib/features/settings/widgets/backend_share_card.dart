import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/app_scope.dart';
import '../../../app/app_state.dart';
import '../../../core/backend/backend_connection_link.dart';
import '../../../core/backend/backend_connection_manager.dart';
import '../../../core/backend/lan_backend_share.dart';
import 'settings_section_card.dart';

class BackendShareCard extends StatefulWidget {
  const BackendShareCard({super.key});

  @override
  State<BackendShareCard> createState() => _BackendShareCardState();
}

class _BackendShareCardState extends State<BackendShareCard> {
  List<LanAddress> _addresses = [];
  String? _address;
  BackendConnectionLink? _remoteLink;
  int? _revision;
  bool _busy = false;
  String? _message;

  Future<void> _generate({String? address}) async {
    final scope = AppScope.of(context);
    final revision = scope.appState.backendConnectionRevision;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (scope.appState.connectionMode == BackendConnectionMode.local) {
        final addresses = await LanBackendShare.discoverAddresses();
        if (!mounted || revision != scope.appState.backendConnectionRevision) {
          return;
        }
        if (addresses.isEmpty) throw StateError('未找到内网地址，请先连接 Wi-Fi 或有线局域网。');
        final selected = address ?? _address;
        final chosen = addresses.firstWhere((a) => a.address == selected,
            orElse: () => addresses.first);
        _addresses = addresses;
        _address = chosen.address;
        await scope.backend.lanShare.start(address: chosen.address);
        if (revision != scope.appState.backendConnectionRevision) {
          await scope.backend.lanShare.stop();
          return;
        }
      } else {
        final link = BackendConnectionLink(
            url: scope.appState.backendUrl, token: scope.appState.backendToken);
        link.encode();
        _remoteLink = link;
      }
      _revision = revision;
    } catch (_) {
      // Avoid printing addresses from platform errors together with link secrets.
      if (mounted) {
        setState(() => _message = _addresses.isEmpty &&
                scope.appState.connectionMode == BackendConnectionMode.local
            ? '未找到可用内网地址，请连接 Wi-Fi 或有线网络后重试。'
            : '生成失败，请检查连接状态、所选网卡及端口 19454 是否被占用。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(BackendConnectionLink link) async {
    try {
      await Clipboard.setData(ClipboardData(text: link.encode()));
      if (mounted) setState(() => _message = '连接链接已复制');
    } on Object {
      if (mounted) setState(() => _message = '复制失败，请使用手机扫码。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge(
          [scope.appState, scope.backend, scope.backend.lanShare]),
      builder: (context, _) {
        final local =
            scope.appState.connectionMode == BackendConnectionMode.local;
        final link = local
            ? scope.backend.lanShare.connection
            : _revision == scope.appState.backendConnectionRevision
                ? _remoteLink
                : null;
        return SettingsSectionCard(
          icon: FluentIcons.cell_phone,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('手机连接', style: FluentTheme.of(context).typography.subtitle),
            const SizedBox(height: 8),
            Text(local
                ? '让手机连接此电脑的本机后端，共用书库、任务和阅读进度。'
                : '让手机连接 PC 当前使用的后端。多用户服务仍需在手机登录账号。'),
            const SizedBox(height: 8),
            const Text(
                '手机与电脑需连接同一内网。在手机“我的 → 服务连接”中选择“扫描二维码”。二维码和链接包含连接密钥，请仅分享给可信设备。'),
            if (local) ...[
              const SizedBox(height: 8),
              const Text(
                  '使用期间请保持 PC 青卷运行。首次连接时请允许 Windows 防火墙的专用网络访问；关闭共享或退出后需重新扫码。'),
            ],
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(
                key: const ValueKey('generate-backend-qr'),
                onPressed: _busy || scope.backend.status != BackendStatus.ready
                    ? null
                    : _generate,
                child: Text(_busy
                    ? '正在生成…'
                    : link == null
                        ? '生成连接二维码'
                        : '重新生成二维码'),
              ),
              if (link != null)
                Button(
                  key: const ValueKey('copy-backend-link'),
                  onPressed: _busy ? null : () => _copy(link),
                  child: const Text('复制连接链接'),
                ),
              if (local && scope.backend.lanShare.isSharing)
                Button(
                  key: const ValueKey('stop-backend-sharing'),
                  onPressed: _busy ? null : scope.backend.lanShare.stop,
                  child: const Text('关闭共享'),
                ),
              if (!local && link != null)
                Button(
                  onPressed: () => setState(() => _remoteLink = null),
                  child: const Text('隐藏二维码'),
                ),
            ]),
            if (scope.backend.status != BackendStatus.ready) ...[
              const SizedBox(height: 8),
              const Text('请先保存并连接后端，再生成二维码。'),
            ],
            if (link != null) ...[
              const SizedBox(height: 16),
              if (local && _addresses.isNotEmpty) ...[
                InfoLabel(
                    label: '内网地址（多网卡可切换）',
                    child: ComboBox<String>(
                      key: const ValueKey('sharing-network-address'),
                      value: _address,
                      isExpanded: true,
                      items: [
                        for (final a in _addresses)
                          ComboBoxItem(value: a.address, child: Text(a.label))
                      ],
                      onChanged: _busy
                          ? null
                          : (value) {
                              if (value != null) _generate(address: value);
                            },
                    )),
                const SizedBox(height: 12),
              ],
              Semantics(
                  label: '青卷后端连接二维码',
                  image: true,
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(8),
                    child: QrImageView(
                        data: link.encode(),
                        size: 240,
                        backgroundColor: Colors.white),
                  )),
              const SizedBox(height: 8),
              SelectableText(link.url),
            ],
            if (_message != null)
              Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_message!)),
          ]),
        );
      },
    );
  }
}
