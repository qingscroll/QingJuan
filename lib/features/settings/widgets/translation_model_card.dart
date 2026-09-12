import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';

import '../../../core/backend/backend_connection_manager.dart';
import '../../../core/models/settings.dart';
import '../settings_controller.dart';
import 'settings_section_card.dart';

class TranslationModelCard extends StatefulWidget {
  const TranslationModelCard({
    required this.backend,
    required this.settings,
    required this.localConfiguration,
    required this.checking,
    required this.onCheck,
    super.key,
  });

  final BackendConnectionManager backend;
  final SettingsController settings;
  final bool localConfiguration;
  final bool checking;
  final Future<void> Function(bool force) onCheck;

  @override
  State<TranslationModelCard> createState() => _TranslationModelCardState();
}

class _TranslationModelCardState extends State<TranslationModelCard> {
  final _translationBaseUrlController = TextEditingController();
  final _translationModelController = TextEditingController();
  final _translationApiKeyController = TextEditingController();
  final _systemPromptController = TextEditingController();
  final _ocrBaseUrlController = TextEditingController();
  final _ocrApiKeyController = TextEditingController();

  bool _translationEnabled = false;
  bool _supportsVision = false;
  bool _clearTranslationApiKey = false;
  bool _ocrEnabled = false;
  bool _clearOcrApiKey = false;
  bool _saving = false;
  late TranslationSettings _appliedSettings;

  @override
  void initState() {
    super.initState();
    _applySettings(widget.settings.value);
  }

  @override
  void didUpdateWidget(covariant TranslationModelCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(_appliedSettings, widget.settings.value)) {
      _applySettings(widget.settings.value);
    }
  }

  void _applySettings(TranslationSettings settings) {
    _appliedSettings = settings;
    final model = settings.translationModel;
    final ocr = settings.mangaOcr;
    _translationEnabled = model.enabled;
    _translationBaseUrlController.text = model.baseUrl;
    _translationModelController.text = model.model;
    _translationApiKeyController.text = model.apiKey;
    _supportsVision = model.supportsVision;
    _clearTranslationApiKey = model.clearApiKey;
    _systemPromptController.text = settings.systemPrompt;
    _ocrEnabled = ocr.enabled;
    _ocrBaseUrlController.text = ocr.baseUrl;
    _ocrApiKeyController.text = ocr.apiKey;
    _clearOcrApiKey = ocr.clearApiKey;
  }

  @override
  void dispose() {
    _translationBaseUrlController.dispose();
    _translationModelController.dispose();
    _translationApiKeyController.dispose();
    _systemPromptController.dispose();
    _ocrBaseUrlController.dispose();
    _ocrApiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSectionCard(
      icon: FluentIcons.locale_language,
      child: widget.localConfiguration
          ? _localModelConfiguration(context)
          : _remoteModelStatus(),
    );
  }

  Widget _localModelConfiguration(BuildContext context) {
    final settings = widget.settings.value;
    final canEdit = !_saving && !widget.settings.saving;
    final canSubmit = widget.backend.status == BackendStatus.ready &&
        !_saving &&
        !widget.settings.saving;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const InfoBar(
          title: Text('模型配置保存在本机后端'),
          content: Text(
            'API 密钥只提交到当前 Windows 本机后端，不写入客户端偏好；已保存的密钥不会回显。',
          ),
          severity: InfoBarSeverity.info,
        ),
        const SizedBox(height: 16),
        _settingToggle(
          title: '启用 OpenAI 兼容翻译',
          subtitle: '小说和漫画翻译共用这套模型配置。',
          value: _translationEnabled,
          key: const ValueKey('translation-model-enabled'),
          onChanged: canEdit
              ? (value) => setState(() => _translationEnabled = value)
              : null,
        ),
        const SizedBox(height: 12),
        _translationModelStatusBar(),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final baseUrl = InfoLabel(
              label: 'API 根地址',
              child: TextBox(
                key: const ValueKey('translation-model-base-url'),
                controller: _translationBaseUrlController,
                enabled: canEdit,
                placeholder: 'https://api.openai.com/v1',
              ),
            );
            final model = InfoLabel(
              label: '模型',
              child: TextBox(
                key: const ValueKey('translation-model-name'),
                controller: _translationModelController,
                enabled: canEdit,
                placeholder: 'gpt-5.4',
              ),
            );
            if (constraints.maxWidth < 620) {
              return Column(
                children: <Widget>[
                  baseUrl,
                  const SizedBox(height: 12),
                  model,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(flex: 3, child: baseUrl),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: model),
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        InfoLabel(
          label: 'API 密钥',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: TextBox(
                  key: const ValueKey('translation-model-api-key'),
                  controller: _translationApiKeyController,
                  enabled: canEdit && !_clearTranslationApiKey,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  placeholder: settings.translationModel.apiKeyConfigured
                      ? '已保存；留空保持现有密钥'
                      : '输入 API 密钥',
                ),
              ),
              if (settings.translationModel.apiKeyConfigured) ...<Widget>[
                const SizedBox(width: 8),
                Button(
                  key: const ValueKey('clear-translation-model-api-key'),
                  onPressed: canEdit
                      ? () => setState(() {
                            _clearTranslationApiKey = !_clearTranslationApiKey;
                            if (_clearTranslationApiKey) {
                              _translationApiKeyController.clear();
                            }
                          })
                      : null,
                  child: Text(_clearTranslationApiKey ? '取消清除' : '清除'),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _clearTranslationApiKey
              ? '保存后将清除本机后端中的翻译 API 密钥。'
              : '更换 API Origin 时，留空会自动清除旧密钥。',
          style: FluentTheme.of(context).typography.caption,
        ),
        const SizedBox(height: 12),
        ToggleSwitch(
          key: const ValueKey('translation-model-supports-vision'),
          checked: _supportsVision,
          onChanged: canEdit
              ? (value) => setState(() => _supportsVision = value)
              : null,
          content: const Text('模型支持视觉输入'),
        ),
        const SizedBox(height: 12),
        InfoLabel(
          label: '系统提示词',
          child: TextBox(
            key: const ValueKey('translation-system-prompt'),
            controller: _systemPromptController,
            enabled: canEdit,
            minLines: 4,
            maxLines: 8,
            placeholder: '输入翻译规则和输出要求',
          ),
        ),
        const SizedBox(height: 20),
        const Divider(),
        const SizedBox(height: 16),
        _settingToggle(
          title: '启用外部漫画 OCR',
          subtitle: '关闭时继续使用 Windows 本机 RapidOCR 与系统 OCR。',
          value: _ocrEnabled,
          key: const ValueKey('manga-ocr-enabled'),
          onChanged:
              canEdit ? (value) => setState(() => _ocrEnabled = value) : null,
        ),
        const SizedBox(height: 12),
        InfoLabel(
          label: 'OCR API 地址',
          child: TextBox(
            key: const ValueKey('manga-ocr-base-url'),
            controller: _ocrBaseUrlController,
            enabled: canEdit,
            placeholder: 'https://example.com/ocr',
          ),
        ),
        const SizedBox(height: 12),
        InfoLabel(
          label: 'OCR API 密钥',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: TextBox(
                  key: const ValueKey('manga-ocr-api-key'),
                  controller: _ocrApiKeyController,
                  enabled: canEdit && !_clearOcrApiKey,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  placeholder: settings.mangaOcr.apiKeyConfigured
                      ? '已保存；留空保持现有密钥'
                      : '可选',
                ),
              ),
              if (settings.mangaOcr.apiKeyConfigured) ...<Widget>[
                const SizedBox(width: 8),
                Button(
                  key: const ValueKey('clear-manga-ocr-api-key'),
                  onPressed: canEdit
                      ? () => setState(() {
                            _clearOcrApiKey = !_clearOcrApiKey;
                            if (_clearOcrApiKey) {
                              _ocrApiKeyController.clear();
                            }
                          })
                      : null,
                  child: Text(_clearOcrApiKey ? '取消清除' : '清除'),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: <Widget>[
            FilledButton(
              key: const ValueKey('save-local-model-settings'),
              onPressed: canSubmit ? () => unawaited(_save()) : null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (_saving || widget.settings.saving) ...<Widget>[
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: ProgressRing(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(_saving || widget.settings.saving ? '正在保存' : '保存模型配置'),
                ],
              ),
            ),
            Button(
              onPressed: widget.backend.status == BackendStatus.ready &&
                      !widget.checking &&
                      !_saving
                  ? () => unawaited(widget.onCheck(true))
                  : null,
              child: Text(widget.checking ? '正在检测' : '重新检测模型'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _remoteModelStatus() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const InfoBar(
            title: Text('由 Linux 后端管理界面统一配置'),
            content: Text(
              '远程客户端只创建服务端翻译任务，不接收模型密钥；每次连接都会执行模型自检。',
            ),
            severity: InfoBarSeverity.info,
          ),
          const SizedBox(height: 14),
          _translationModelStatusBar(),
          const SizedBox(height: 12),
          Button(
            onPressed:
                widget.backend.status == BackendStatus.ready && !widget.checking
                    ? () => unawaited(widget.onCheck(false))
                    : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (widget.checking) ...<Widget>[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: ProgressRing(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                ] else ...<Widget>[
                  const Icon(FluentIcons.refresh, size: 14),
                  const SizedBox(width: 8),
                ],
                Text(widget.checking ? '正在检测' : '重新检测模型'),
              ],
            ),
          ),
        ],
      );

  Widget _settingToggle({
    required String title,
    required String subtitle,
    required bool value,
    required Key key,
    required ValueChanged<bool>? onChanged,
  }) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ToggleSwitch(
            key: key,
            checked: value,
            onChanged: onChanged,
            semanticLabel: title,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: FluentTheme.of(context).typography.caption,
                ),
              ],
            ),
          ),
        ],
      );

  Future<void> _save() async {
    if (_saving) return;
    try {
      _validate();
    } catch (error) {
      _showError('$error');
      return;
    }

    setState(() => _saving = true);
    final current = widget.settings.value;
    widget.settings.update(
      current.copyWith(
        systemPrompt: _systemPromptController.text.trim(),
        translationModel: current.translationModel.copyWith(
          enabled: _translationEnabled,
          baseUrl: _translationBaseUrlController.text.trim(),
          apiKey: _translationApiKeyController.text.trim(),
          model: _translationModelController.text.trim(),
          supportsVision: _supportsVision,
          clearApiKey: _clearTranslationApiKey,
        ),
        mangaOcr: current.mangaOcr.copyWith(
          enabled: _ocrEnabled,
          baseUrl: _ocrBaseUrlController.text.trim(),
          apiKey: _ocrApiKeyController.text.trim(),
          clearApiKey: _clearOcrApiKey,
        ),
      ),
    );
    try {
      await widget.settings.save();
      _translationApiKeyController.clear();
      _ocrApiKeyController.clear();
      _clearTranslationApiKey = false;
      _clearOcrApiKey = false;
      await widget.onCheck(true);
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (_, __) => const InfoBar(
          title: Text('模型配置已保存'),
          content: Text('配置已写入 Windows 本机后端，并已重新执行模型自检。'),
          severity: InfoBarSeverity.success,
        ),
      );
    } catch (error) {
      if (mounted) _showError('$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _validate() {
    if (_systemPromptController.text.trim().isEmpty) {
      throw StateError('系统提示词不能为空');
    }
    if (_translationEnabled) {
      _validateHttpUrl(
        _translationBaseUrlController.text,
        emptyMessage: '启用翻译模型后必须填写 API 根地址',
        invalidMessage: '翻译模型 API 根地址必须是有效的 HTTP 或 HTTPS 地址',
      );
      if (_translationModelController.text.trim().isEmpty) {
        throw StateError('启用翻译模型后必须填写模型名称');
      }
    }
    if (_ocrEnabled) {
      _validateHttpUrl(
        _ocrBaseUrlController.text,
        emptyMessage: '启用外部 OCR 后必须填写 API 地址',
        invalidMessage: 'OCR API 地址必须是有效的 HTTP 或 HTTPS 地址',
      );
    }
  }

  void _validateHttpUrl(
    String raw, {
    required String emptyMessage,
    required String invalidMessage,
  }) {
    final value = raw.trim();
    if (value.isEmpty) throw StateError(emptyMessage);
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw StateError(invalidMessage);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    displayInfoBar(
      context,
      builder: (_, __) => InfoBar(
        title: const Text('模型配置保存失败'),
        content: Text(message),
        severity: InfoBarSeverity.error,
      ),
    );
  }

  Widget _translationModelStatusBar() {
    final check = widget.backend.translationModelCheck;
    final location = widget.localConfiguration ? '本机' : '服务端';
    if (widget.localConfiguration && !_translationEnabled) {
      return const InfoBar(
        title: Text('翻译模型未启用'),
        content: Text('可以先填写下方配置；打开“启用 OpenAI 兼容翻译”并保存后，即可使用翻译。'),
        severity: InfoBarSeverity.info,
      );
    }
    if (widget.localConfiguration &&
        !widget.settings.value.translationModel.enabled &&
        _translationEnabled) {
      return const InfoBar(
        title: Text('翻译模型待保存'),
        content: Text('填写 API 根地址、模型名称和密钥，然后点击“保存模型配置”完成启用与自检。'),
        severity: InfoBarSeverity.info,
      );
    }
    if (check == null) {
      return InfoBar(
        title: Text('等待$location模型自检'),
        content: const Text('连接后端后会自动读取当前翻译模型状态。'),
        severity: InfoBarSeverity.info,
      );
    }
    final title = switch (check.status) {
      TranslationModelCheckStatus.ready => '$location翻译模型可用',
      TranslationModelCheckStatus.disabled => '$location翻译模型未启用',
      TranslationModelCheckStatus.unconfigured => '$location翻译模型未配置完整',
      TranslationModelCheckStatus.failed => '$location翻译模型自检失败',
    };
    final details = <String>[
      if (check.model != null && check.model!.isNotEmpty) check.model!,
      if (check.latencyMs != null) '${check.latencyMs} ms',
      if (check.available) check.supportsVision ? '支持视觉' : '仅文本',
      if (check.cached) '近期检查结果',
    ];
    return InfoBar(
      title: Text(title),
      content: Text(
        check.available && details.isNotEmpty
            ? details.join(' · ')
            : widget.localConfiguration
                ? check.message
                    .replaceAll('Linux 服务端', '本机后端')
                    .replaceAll('Linux 管理界面', '本机翻译设置')
                : check.message,
      ),
      severity: switch (check.status) {
        TranslationModelCheckStatus.ready => InfoBarSeverity.success,
        TranslationModelCheckStatus.failed => InfoBarSeverity.error,
        _ => InfoBarSeverity.warning,
      },
    );
  }
}
