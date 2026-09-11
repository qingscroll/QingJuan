part of 'mobile_my_page.dart';

class _ThemeCard extends StatelessWidget {
  const _ThemeCard();
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context).appState;
    final colors = MiuixTheme.of(context).colors;
    return Column(
        key: const ValueKey('mobile-my-theme'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 10),
              child: Text('外观',
                  style: MiuixTheme.of(context)
                      .textStyles
                      .footnote1
                      .copyWith(color: colors.onBackgroundVariant))),
          LayoutBuilder(builder: (context, constraints) {
            final stacked = MediaQuery.textScalerOf(context).scale(14) > 22 ||
                constraints.maxWidth < 280;
            final options = <Widget>[
              for (final mode in AppThemeMode.values)
                Semantics(
                    selected: app.themeMode == mode,
                    child: MobilePressable(
                      key: ValueKey<String>('my-theme-${mode.name}'),
                      onPressed: () => unawaited(app.setThemeMode(mode)),
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 72),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 12),
                        decoration: BoxDecoration(
                            color: app.themeMode == mode
                                ? colors.primaryContainer
                                : colors.surfaceContainer,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: app.themeMode == mode
                                    ? colors.primary
                                    : colors.dividerLine)),
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              Icon(
                                  switch (mode) {
                                    AppThemeMode.system =>
                                      Icons.brightness_auto_outlined,
                                    AppThemeMode.light =>
                                      Icons.light_mode_outlined,
                                    AppThemeMode.dark =>
                                      Icons.dark_mode_outlined
                                  },
                                  color: app.themeMode == mode
                                      ? colors.primary
                                      : colors.onBackgroundVariant,
                                  size: 22),
                              const SizedBox(height: 6),
                              Text(
                                  switch (mode) {
                                    AppThemeMode.system => '跟随系统',
                                    AppThemeMode.light => '浅色',
                                    AppThemeMode.dark => '深色'
                                  },
                                  textAlign: TextAlign.center,
                                  style: MiuixTheme.of(context)
                                      .textStyles
                                      .footnote1
                                      .copyWith(
                                          color: app.themeMode == mode
                                              ? colors.primary
                                              : colors.onBackground,
                                          fontWeight: app.themeMode == mode
                                              ? FontWeight.w600
                                              : FontWeight.w400)),
                            ]),
                      ),
                    )),
            ];
            if (stacked) {
              return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final option in options)
                      Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: option)
                  ]);
            }
            return Row(children: [
              for (var i = 0; i < options.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: options[i])
              ]
            ]);
          }),
        ]);
  }
}

class _BackendSettingsPanel extends StatefulWidget {
  const _BackendSettingsPanel({this.connectionLink});
  final BackendConnectionLink? connectionLink;
  @override
  State<_BackendSettingsPanel> createState() => _BackendSettingsPanelState();
}

class _BackendSettingsPanelState extends State<_BackendSettingsPanel> {
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _initialized = false;
  bool _saving = false;
  bool _revealToken = false;
  String? _message;
  bool _failed = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final app = AppScope.of(context).appState;
    _urlController.text = widget.connectionLink?.url ?? app.remoteBackendUrl;
    _tokenController.text =
        widget.connectionLink?.token ?? app.remoteBackendToken;
    if (widget.connectionLink != null) {
      _message = '已读取连接链接，请核对服务地址后点击“验证并连接”。';
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.clear();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final scope = AppScope.of(context);
    final url = _urlController.text.trim();
    final token = _tokenController.text.trim();
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      validateBackendUrl(url);
      if (token.isEmpty) throw StateError('请填写管理员提供的连接密钥');
      await scope.backend.testRemoteConnection(baseUrl: url, token: token);
      final app = scope.appState;
      final changed = app.connectionMode != BackendConnectionMode.remote ||
          app.remoteBackendUrl.replaceAll(RegExp(r'/+$'), '') !=
              url.replaceAll(RegExp(r'/+$'), '') ||
          app.remoteBackendToken != token;
      if (changed) {
        await app.applyBackendConnection(
            mode: BackendConnectionMode.remote,
            remoteUrl: url,
            remoteToken: token);
        await scope.auth.clearForBackendSwitch();
      }
      await scope.backend.ensureReady();
      if (scope.backend.status != BackendStatus.ready) {
        throw StateError(scope.backend.message);
      }
      if (changed || !scope.auth.canAccessWorkspace) {
        await scope.auth.initializeForCurrentBackend(
            multiUser: scope.backend.multiUserEnabled);
      }
      if (scope.auth.canAccessWorkspace &&
          scope.backend.capabilities['translationModelCheck'] == true &&
          !scope.backend.translationModelCheckInProgress) {
        unawaited(_checkAfterConnection(scope.backend));
      }
      app.clearNotice();
      if (!mounted) return;
      setState(() {
        _failed = false;
        _revealToken = false;
        _message = scope.auth.canAccessWorkspace
            ? '连接已保存，可以返回书库继续阅读。'
            : '连接已验证。下一步登录你的账号，打开个人书库。';
      });
      FocusScope.of(context).unfocus();
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _message = '$error';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _scan() async {
    final link = await Navigator.of(context).push<BackendConnectionLink>(
      MaterialPageRoute(builder: (_) => const MobileConnectionScanner()),
    );
    if (!mounted || link == null) return;
    _importLink(link);
  }

  void _importLink(BackendConnectionLink link) {
    setState(() {
      _urlController.text = link.url;
      _tokenController.text = link.token;
      _revealToken = false;
      _failed = false;
      _message = '已读取连接链接，请核对服务地址后点击“验证并连接”。';
    });
  }

  Future<void> _pasteLink() async {
    try {
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      final link = BackendConnectionLink.parse(clipboard?.text ?? '');
      if (mounted) _importLink(link);
    } on Object {
      if (mounted) {
        setState(() {
          _failed = true;
          _message = '未找到有效的青卷连接链接，请在 PC 设置中复制连接链接。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[scope.backend, scope.auth]),
        builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text('连接你的阅读空间',
                      style: MiuixTheme.of(context)
                          .textStyles
                          .title4
                          .copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const Text(
                      '扫描 PC 设置中的二维码，或输入服务地址和连接密钥。局域网共享需与 PC 连接同一网络，并保持 PC 青卷运行。'),
                  const SizedBox(height: 16),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    OutlinedButton.icon(
                      key: const ValueKey('scan-backend-qr'),
                      onPressed: _saving ? null : _scan,
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                      label: const Text('扫描二维码'),
                    ),
                    OutlinedButton.icon(
                      key: const ValueKey('paste-backend-link'),
                      onPressed: _saving ? null : _pasteLink,
                      icon: const Icon(Icons.content_paste_rounded),
                      label: const Text('粘贴连接链接'),
                    ),
                  ]),
                  const SizedBox(height: 24),
                  TextField(
                      key: const ValueKey('linux-backend-url'),
                      controller: _urlController,
                      enabled: !_saving,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      decoration: const InputDecoration(
                          labelText: '服务地址',
                          hintText: 'https://books.example.com',
                          helperText: '公网地址需使用 HTTPS；支持局域网 HTTP。',
                          helperMaxLines: 3)),
                  const SizedBox(height: 20),
                  TextField(
                      key: const ValueKey('linux-backend-token'),
                      controller: _tokenController,
                      enabled: !_saving,
                      obscureText: !_revealToken,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _save(),
                      decoration: InputDecoration(
                          labelText: '连接密钥（Token）',
                          helperText: '这是服务的连接凭据，与账号密码不同。',
                          helperMaxLines: 3,
                          suffixIcon: IconButton(
                              tooltip: _revealToken ? '隐藏连接密钥' : '显示连接密钥',
                              onPressed: () =>
                                  setState(() => _revealToken = !_revealToken),
                              icon: Icon(_revealToken
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined)))),
                  const SizedBox(height: 24),
                  MobileActionButton(
                      key: const ValueKey('save-backend-connection'),
                      icon: Icons.link_rounded,
                      busy: _saving,
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? '正在验证连接…' : '验证并连接')),
                  if (_saving) ...<Widget>[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator()
                  ],
                  if (_message != null) ...<Widget>[
                    const SizedBox(height: 20),
                    MobileSettingsNotice(
                        title: _failed ? '连接未成功' : '连接信息',
                        message: _message!,
                        error: _failed,
                        action: !_failed &&
                                !scope.auth.canAccessWorkspace &&
                                scope.backend.status == BackendStatus.ready
                            ? MobileActionButton(
                                icon: Icons.login_rounded,
                                onPressed: () => showMobileAccountPage(context),
                                child: const Text('继续登录'))
                            : null),
                  ],
                ]));
  }
}

class _TranslationSettingsPanel extends StatefulWidget {
  const _TranslationSettingsPanel();
  @override
  State<_TranslationSettingsPanel> createState() =>
      _TranslationSettingsPanelState();
}

class _TranslationSettingsPanelState extends State<_TranslationSettingsPanel> {
  bool _checking = false;
  String? _error;
  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final scope = AppScope.of(context);
      await scope.backend.checkTranslationModel();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    return AnimatedBuilder(
        animation: scope.backend,
        builder: (context, _) {
          final backend = scope.backend;
          final check = backend.translationModelCheck;
          final allowed = backend.status == BackendStatus.ready &&
              scope.auth.canAccessWorkspace &&
              backend.capabilities['translationModelCheck'] == true;
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                MobileSettingsNotice(
                    title: check == null
                        ? '尚未检测翻译服务'
                        : check.available
                            ? '翻译服务可用'
                            : '翻译服务暂不可用',
                    message: check?.message ?? '连接并登录后，可以检测服务端的翻译能力。',
                    error: check != null && !check.available),
                const SizedBox(height: 20),
                if (check?.model case final model?)
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('当前模型'),
                      subtitle: Text(model)),
                if (check?.available == true)
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('可翻译的内容'),
                      subtitle:
                          Text(check!.supportsVision ? '小说文字与漫画图片' : '小说文字')),
                const Text('翻译由远程服务完成。模型和密钥由管理员在服务管理界面维护，手机无需配置。'),
                const SizedBox(height: 20),
                MobileActionButton(
                    icon: Icons.refresh_rounded,
                    busy: _checking || backend.translationModelCheckInProgress,
                    onPressed: !allowed ||
                            _checking ||
                            backend.translationModelCheckInProgress
                        ? null
                        : _check,
                    child: Text(
                        _checking || backend.translationModelCheckInProgress
                            ? '正在检测…'
                            : '刷新状态')),
                if (!allowed)
                  const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('需要已连接、已登录，且服务器支持模型检测。')),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 16),
                  MobileSettingsNotice(
                      title: '检测未完成', message: _error!, error: true)
                ],
              ]);
        });
  }
}

Future<void> _checkAfterConnection(BackendConnectionManager backend) async {
  try {
    await backend.checkTranslationModel();
  } catch (_) {/* Model availability does not determine connection success. */}
}
