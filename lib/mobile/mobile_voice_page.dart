import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import '../app/app_scope.dart';
import '../core/models/tts_speech_style.dart';
import '../core/models/tts_voice.dart';
import '../features/audiobook/tts_voice_service.dart';
import 'mobile_settings_route.dart';
import 'mobile_sheet.dart';

class MobileVoicePage extends StatefulWidget {
  const MobileVoicePage({this.voiceService, super.key});
  final TtsVoiceService? voiceService;
  @override
  State<MobileVoicePage> createState() => _MobileVoicePageState();
}

class _MobileVoicePageState extends State<MobileVoicePage> {
  late final TtsVoiceService _service =
      widget.voiceService ?? FlutterTtsVoiceService();
  List<TtsVoice> _voices = const [];
  String _query = '';
  bool _loading = true;
  String? _error;
  String? _previewing;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_service.dispose());
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final voices = await _service.loadVoices();
      if (mounted) setState(() => _voices = voices);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _select(TtsVoice? voice) async {
    final app = AppScope.of(context).appState;
    try {
      await _service.stop();
      await app.setTtsVoice(voice);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _preview(TtsVoice voice) async {
    final style = AppScope.of(context).appState.ttsSpeechStyle;
    setState(() {
      _previewing = voice.stableKey;
      _error = null;
    });
    try {
      await _service.preview(voice, style: style);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _previewing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context).appState;
    return AnimatedBuilder(
        animation: app,
        builder: (context, _) {
          final filtered = _voices
              .where((voice) => '${voice.name} ${voice.description}'
                  .toLowerCase()
                  .contains(_query.toLowerCase()))
              .toList();
          return Scaffold(
            appBar: AppBar(title: const Text('听书声音'), actions: [
              IconButton(
                  onPressed: _loading ? null : _load,
                  tooltip: '重新读取系统声音',
                  icon: const Icon(Icons.refresh_rounded))
            ]),
            body: SafeArea(
                top: false,
                child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: CustomScrollView(slivers: <Widget>[
                          SliverPadding(
                              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                              sliver: SliverToBoxAdapter(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: <Widget>[
                                    const Text('使用这台设备的系统声音。选择立即保存，用于之后的听书。'),
                                    const SizedBox(height: 12),
                                    ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        title: const Text('朗读风格'),
                                        subtitle:
                                            Text(app.ttsSpeechStyle.label),
                                        trailing: const Icon(
                                            Icons.chevron_right_rounded),
                                        onTap: () => showMobileSheet<void>(
                                            context: context,
                                            title: '朗读风格',
                                            child: Column(children: [
                                              for (final style
                                                  in TtsSpeechStyle.values)
                                                ListTile(
                                                    title: Text(style.label),
                                                    subtitle:
                                                        Text(style.description),
                                                    trailing:
                                                        app.ttsSpeechStyle ==
                                                                style
                                                            ? const Icon(Icons
                                                                .check_rounded)
                                                            : null,
                                                    onTap: () {
                                                      unawaited(
                                                          app.setTtsSpeechStyle(
                                                              style));
                                                      Navigator.pop(context);
                                                    })
                                            ]))),
                                    const Divider(height: 1),
                                    ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        title: const Text('跟随系统声音'),
                                        subtitle: const Text('使用设备默认语音'),
                                        trailing: app.ttsVoice == null
                                            ? Icon(Icons.check_circle_rounded,
                                                color: MiuixTheme.of(context)
                                                    .colors
                                                    .primary)
                                            : null,
                                        onTap: () => _select(null)),
                                    const SizedBox(height: 8),
                                    TextField(
                                        decoration: const InputDecoration(
                                            hintText: '搜索声音或语言',
                                            prefixIcon:
                                                Icon(Icons.search_rounded)),
                                        onChanged: (value) =>
                                            setState(() => _query = value)),
                                    if (_loading) ...<Widget>[
                                      const SizedBox(height: 20),
                                      const LinearProgressIndicator()
                                    ],
                                    if (_error != null) ...<Widget>[
                                      const SizedBox(height: 16),
                                      MobileSettingsNotice(
                                          title: '声音暂不可用',
                                          message: _error!,
                                          error: true)
                                    ],
                                    if (!_loading &&
                                        _voices.isEmpty) ...<Widget>[
                                      const SizedBox(height: 20),
                                      const Text(
                                          '未找到系统声音。请在 Android 系统设置中安装或启用文字转语音引擎，然后重新读取。')
                                    ],
                                    if (!_loading &&
                                        _voices.isNotEmpty &&
                                        filtered.isEmpty)
                                      const Padding(
                                          padding: EdgeInsets.only(top: 20),
                                          child: Text('没有匹配的声音，试试其他名称或语言。')),
                                  ]))),
                          SliverPadding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 20),
                              sliver: SliverList.builder(
                                  itemCount: filtered.length,
                                  itemBuilder: (context, index) {
                                    final voice = filtered[index];
                                    final selected = app.ttsVoice?.stableKey ==
                                        voice.stableKey;
                                    return Column(children: <Widget>[
                                      ListTile(
                                          contentPadding: EdgeInsets.zero,
                                          selected: selected,
                                          title: Text(voice.name,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis),
                                          subtitle: Text(voice.description),
                                          onTap: () => _select(voice),
                                          leading: selected
                                              ? Icon(Icons.check_circle_rounded,
                                                  color: MiuixTheme.of(context)
                                                      .colors
                                                      .primary)
                                              : const Icon(Icons
                                                  .record_voice_over_outlined),
                                          trailing: IconButton(
                                              tooltip:
                                                  _previewing == voice.stableKey
                                                      ? '正在试听'
                                                      : '试听 ${voice.name}',
                                              onPressed: _previewing != null
                                                  ? null
                                                  : () => _preview(voice),
                                              icon: Icon(_previewing ==
                                                      voice.stableKey
                                                  ? Icons.graphic_eq_rounded
                                                  : Icons
                                                      .play_circle_outline_rounded))),
                                      const Divider(height: 1),
                                    ]);
                                  })),
                          const SliverToBoxAdapter(child: SizedBox(height: 28)),
                        ])))),
          );
        });
  }
}
