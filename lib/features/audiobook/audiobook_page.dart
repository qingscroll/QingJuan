import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';

import '../../app/app_scope.dart';
import '../../core/models/book.dart';
import '../../mobile/mobile_book_cover.dart';
import '../../mobile/mobile_action_button.dart';
import '../../mobile/mobile_voice_page.dart';
import '../../shared/motion.dart';
import '../../core/models/tts_speech_style.dart';
import '../../core/models/tts_voice.dart';
import '../../shared/feedback_widgets.dart';
import '../../shared/mobile_sheet.dart';
import '../../shared/responsive.dart';
import '../../shared/smooth_scroll.dart';
import 'audiobook_controller.dart';
import 'audiobook_sleep_timer.dart';
import 'audiobook_timer_control.dart';
import 'flutter_tts_engine.dart';

class AudiobookPage extends StatefulWidget {
  const AudiobookPage({
    required this.detail,
    required this.loadChapter,
    this.initialChapterIndex,
    this.engine,
    this.voice,
    this.style = TtsSpeechStyle.natural,
    this.onStyleChanged,
    this.controller,
    this.sleepTimer,
    super.key,
  });

  final BookDetail detail;
  final ChapterLoader loadChapter;
  final int? initialChapterIndex;
  final TtsEngine? engine;
  final TtsVoice? voice;
  final TtsSpeechStyle style;
  final Future<void> Function(TtsSpeechStyle style)? onStyleChanged;

  /// An application-owned session survives navigation; injected engines remain page-owned.
  final AudiobookController? controller;
  final AudiobookSleepTimer? sleepTimer;

  @override
  State<AudiobookPage> createState() => _AudiobookPageState();
}

class _AudiobookPageState extends State<AudiobookPage> {
  late final AudiobookController _controller;
  final ScrollController _textScrollController = QjScrollController(
    debugLabel: 'audiobook-text',
  );

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ??
        AudiobookController(
          detail: widget.detail,
          engine: widget.engine ?? FlutterTtsEngine(voice: widget.voice),
          loadChapter: widget.loadChapter,
          initialChapterIndex: widget.initialChapterIndex,
          initialStyle: widget.style,
        );
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    _textScrollController.dispose();
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        if (_controller.isClosed) {
          return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('听书会话已结束或身份已切换'),
            HyperlinkButton(
                onPressed: () => Navigator.maybePop(context),
                child: const Text('返回')),
          ]));
        }
        final theme = FluentTheme.of(context);
        if (!usesMobileUi(context)) return _buildDesktopPage(context, theme);
        return _buildMobilePlayer(context, theme);
      },
    );
  }

  Future<void> _showPlaybackSettings() => showMobileSheet<void>(
        context: context,
        builder: (sheetContext) => MobileSheet(
          title: '声音与播放',
          onClose: () => Navigator.pop(sheetContext),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前音色：${widget.voice?.name ?? '系统默认音色'}'),
                  const SizedBox(height: 8),
                  Text(
                    '音色选择用于下次听书。当前播放将先停止。',
                    style: FluentTheme.of(context).typography.caption,
                  ),
                  if (context.getInheritedWidgetOfExactType<AppScope>() != null)
                    HyperlinkButton(
                      onPressed: () async {
                        Navigator.pop(sheetContext);
                        await _controller.stop();
                        if (!mounted) return;
                        await Navigator.of(
                          this.context,
                        ).pushReplacement<void, void>(
                          qjPageRoute<void>(
                            context: this.context,
                            builder: (_) => const MobileVoicePage(),
                          ),
                        );
                      },
                      child: const Text('结束本次听书并选择音色'),
                    ),
                  const SizedBox(height: 20),
                  if (widget.sleepTimer != null) ...[
                    AudiobookTimerControl(timer: widget.sleepTimer!),
                    const SizedBox(height: 20),
                  ],
                  _SpeechSettings(
                    controller: _controller,
                    onStyleChanged: (style) async {
                      await _controller.setStyle(style);
                      await widget.onStyleChanged?.call(style);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _buildMobilePlayer(BuildContext context, FluentThemeData theme) {
    return ColoredBox(
      key: const ValueKey('mobile-audiobook-player'),
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: IconButton(
                      icon: Icon(
                        FluentIcons.back,
                        semanticLabel:
                            widget.controller == null ? '结束听书并返回' : '返回并保留听书',
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '正在听书',
                      style: theme.typography.bodyStrong?.copyWith(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: IconButton(
                      icon: const Icon(
                        FluentIcons.settings,
                        semanticLabel: '声音与播放设置',
                      ),
                      onPressed: _showPlaybackSettings,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: SizedBox(
                            width: 126,
                            height: 176,
                            child: MobileBookCover(
                              title: widget.detail.book.title,
                              cover: widget.detail.book.cover,
                              borderRadius: 10,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          widget.detail.book.title,
                          textAlign: TextAlign.center,
                          style: theme.typography.bodyStrong,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _controller.currentChapter.title,
                          textAlign: TextAlign.center,
                          style: theme.typography.subtitle?.copyWith(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '第 ${_controller.chapterIndex} / ${widget.detail.chapters.length} 章 · ${_stateLabel(_controller.state)}',
                          textAlign: TextAlign.center,
                          style: theme.typography.caption,
                        ),
                        const SizedBox(height: 24),
                        Semantics(
                          label: '本章朗读进度',
                          value: '${_controller.chapterProgress.round()}%',
                          child: ProgressBar(
                            value: _controller.chapterProgress,
                            strokeWidth: 3,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _PlaybackControls(controller: _controller),
                        const SizedBox(height: 12),
                        HyperlinkButton(
                          onPressed: _showPlaybackSettings,
                          child: Text(
                            '声音与播放 · 语速 ${_controller.rate.toStringAsFixed(2)}',
                          ),
                        ),
                        const SizedBox(height: 24),
                        Container(
                          height: 1,
                          color: theme.resources.dividerStrokeColorDefault,
                        ),
                        const SizedBox(height: 18),
                        Text('正在朗读的文字', style: theme.typography.bodyStrong),
                        const SizedBox(height: 12),
                        if (_controller.isLoading)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 28),
                            child: LoadingView(label: '正在准备本章朗读'),
                          )
                        else if (_controller.error != null)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('暂时无法播放',
                                  style: theme.typography.bodyStrong),
                              const SizedBox(height: 8),
                              Text(_controller.error!,
                                  style: theme.typography.body
                                      ?.copyWith(height: 1.5)),
                              const SizedBox(height: 16),
                              MobileActionButton(
                                tonal: true,
                                icon: FluentIcons.refresh,
                                onPressed: _controller.initialize,
                                child: const Text('重试播放'),
                              ),
                            ],
                          )
                        else
                          SelectionArea(
                            child: Text(
                              _controller.currentText.isEmpty
                                  ? '本章暂无可朗读文字。'
                                  : _controller.currentText,
                              style: theme.typography.bodyLarge?.copyWith(
                                fontSize: 17,
                                height: 1.65,
                              ),
                            ),
                          ),
                        const SizedBox(height: 24),
                        Text(
                          widget.controller == null
                              ? '由设备语音引擎朗读，离开听书页面后停止播放。'
                              : '由设备语音引擎朗读，返回后继续播放。可通过通知控制或定时停止。',
                          style: theme.typography.caption?.copyWith(
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopPage(BuildContext context, FluentThemeData theme) {
    return NavigationView(
      key: const ValueKey('desktop-audiobook-page'),
      appBar: NavigationAppBar(
        automaticallyImplyLeading: false,
        leading: Tooltip(
          message: '返回作品详情',
          child: IconButton(
            icon: const Icon(FluentIcons.back, semanticLabel: '返回作品详情'),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        title: Text('听书 · ${widget.detail.book.title}'),
      ),
      content: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  _controller.currentChapter.title,
                  style: theme.typography.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Text(
                  '第 ${_controller.chapterIndex} / '
                  '${widget.detail.chapters.length} 章 · '
                  '${_stateLabel(_controller.state)}',
                  style: theme.typography.caption,
                ),
                const SizedBox(height: 20),
                ProgressBar(value: _controller.chapterProgress),
                const SizedBox(height: 24),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: theme.cardColor,
                      border: Border.all(
                        color: theme.resources.cardStrokeColorDefault,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: _controller.isLoading
                        ? const LoadingView(label: '正在加载章节正文')
                        : _controller.error != null
                            ? ErrorView(
                                message: _controller.error!,
                                onRetry: _controller.initialize,
                              )
                            : SingleChildScrollView(
                                controller: _textScrollController,
                                child: SelectionArea(
                                  child: Text(
                                    _controller.currentText,
                                    style: theme.typography.bodyLarge?.copyWith(
                                      height: 1.8,
                                    ),
                                  ),
                                ),
                              ),
                  ),
                ),
                const SizedBox(height: 20),
                _PlaybackControls(controller: _controller),
                const SizedBox(height: 18),
                if (widget.sleepTimer != null) ...[
                  AudiobookTimerControl(timer: widget.sleepTimer!),
                  const SizedBox(height: 12),
                ],
                _SpeechSettings(
                  controller: _controller,
                  onStyleChanged: (style) async {
                    await _controller.setStyle(style);
                    await widget.onStyleChanged?.call(style);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _stateLabel(AudiobookPlaybackState state) => switch (state) {
        AudiobookPlaybackState.loading => '加载中',
        AudiobookPlaybackState.playing => '正在播放',
        AudiobookPlaybackState.paused => '已暂停',
        AudiobookPlaybackState.stopped => '已停止',
        AudiobookPlaybackState.completed => '本书播放完成',
        AudiobookPlaybackState.error => '播放失败',
        AudiobookPlaybackState.idle => '准备播放',
      };
}

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({required this.controller});

  final AudiobookController controller;

  @override
  Widget build(BuildContext context) {
    if (!usesMobileUi(context)) {
      return Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 14,
        runSpacing: 10,
        children: <Widget>[
          Button(
            onPressed: controller.chapterIndex > 1 && !controller.isLoading
                ? () => unawaited(
                      controller.moveChapter(-1,
                          autoplay: controller.isPlaying),
                    )
                : null,
            child: const Text('上一章'),
          ),
          Tooltip(
            message: '停止播放',
            child: IconButton(
              icon: const Icon(
                FluentIcons.stop,
                size: 20,
                semanticLabel: '停止播放',
              ),
              onPressed: controller.isLoading
                  ? null
                  : () => unawaited(controller.stop()),
            ),
          ),
          FilledButton(
            onPressed: controller.isLoading
                ? null
                : () => unawaited(
                      controller.isPlaying
                          ? controller.pause()
                          : controller.play(),
                    ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  controller.isPlaying ? FluentIcons.pause : FluentIcons.play,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  controller.isPlaying
                      ? '暂停'
                      : controller.isPaused
                          ? '继续'
                          : '播放',
                ),
              ],
            ),
          ),
          Button(
            onPressed: controller.chapterIndex <
                        controller.detail.chapters.length &&
                    !controller.isLoading
                ? () => unawaited(
                      controller.moveChapter(1, autoplay: controller.isPlaying),
                    )
                : null,
            child: const Text('下一章'),
          ),
        ],
      );
    }
    return Column(
      children: [
        Row(
          children: [
            SizedBox(
              width: 56,
              height: 56,
              child: IconButton(
                onPressed: controller.chapterIndex > 1 && !controller.isLoading
                    ? () => unawaited(
                          controller.moveChapter(
                            -1,
                            autoplay: controller.isPlaying,
                          ),
                        )
                    : null,
                icon: const Icon(
                  FluentIcons.previous,
                  semanticLabel: '上一章',
                  size: 22,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: MobileActionButton(
                  busy: controller.isLoading,
                  icon: controller.isPlaying
                      ? FluentIcons.pause
                      : FluentIcons.play,
                  onPressed: controller.isLoading || controller.error != null
                      ? null
                      : () => unawaited(
                            controller.isPlaying
                                ? controller.pause()
                                : controller.play(),
                          ),
                  child: Text(
                    controller.isPlaying
                        ? '暂停'
                        : controller.isPaused
                            ? '继续'
                            : '播放',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            SizedBox(
              width: 56,
              height: 56,
              child: IconButton(
                onPressed: controller.chapterIndex <
                            controller.detail.chapters.length &&
                        !controller.isLoading
                    ? () => unawaited(
                          controller.moveChapter(
                            1,
                            autoplay: controller.isPlaying,
                          ),
                        )
                    : null,
                icon: const Icon(
                  FluentIcons.next,
                  semanticLabel: '下一章',
                  size: 22,
                ),
              ),
            ),
          ],
        ),
        HyperlinkButton(
          onPressed:
              controller.isLoading ? null : () => unawaited(controller.stop()),
          child: const Text('停止播放'),
        ),
      ],
    );
  }
}

class _SpeechSettings extends StatelessWidget {
  const _SpeechSettings({
    required this.controller,
    required this.onStyleChanged,
  });

  final AudiobookController controller;
  final Future<void> Function(TtsSpeechStyle style) onStyleChanged;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    if (!usesMobileUi(context)) {
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 18,
        runSpacing: 12,
        children: <Widget>[
          SizedBox(
            width: 230,
            child: InfoLabel(
              label: '朗读风格',
              child: ComboBox<TtsSpeechStyle>(
                value: controller.style,
                isExpanded: true,
                items: TtsSpeechStyle.values
                    .map(
                      (style) => ComboBoxItem<TtsSpeechStyle>(
                        value: style,
                        child: Text(
                          style.label,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: controller.isLoading
                    ? null
                    : (style) {
                        if (style != null) unawaited(onStyleChanged(style));
                      },
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('朗读版本'),
              const SizedBox(width: 10),
              ToggleButton(
                checked: controller.mode == 'original',
                onChanged: controller.isLoading
                    ? null
                    : (checked) => unawaited(
                          controller
                              .setMode(checked ? 'original' : 'translated'),
                        ),
                child: Text(controller.mode == 'original' ? '原文' : '译文'),
              ),
            ],
          ),
          SizedBox(
            width: 250,
            child: Row(
              children: <Widget>[
                const Text('语速'),
                Expanded(
                  child: Slider(
                    value: controller.rate,
                    min: 0.2,
                    max: 1,
                    divisions: 8,
                    onChanged: (value) => unawaited(controller.setRate(value)),
                  ),
                ),
                Text('${controller.rate.toStringAsFixed(2)}×'),
              ],
            ),
          ),
          SizedBox(
            width: 250,
            child: Row(
              children: <Widget>[
                const Text('音量'),
                Expanded(
                  child: Slider(
                    value: controller.volume,
                    min: 0,
                    max: 1,
                    divisions: 10,
                    onChanged: (value) =>
                        unawaited(controller.setVolume(value)),
                  ),
                ),
                Text('${(controller.volume * 100).round()}%'),
              ],
            ),
          ),
          SizedBox(
            width: 320,
            child: Text(
              controller.style.description,
              style: theme.typography.caption,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '播放设置',
          style: theme.typography.subtitle?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: InfoLabel(
            label: '朗读风格',
            child: ComboBox<TtsSpeechStyle>(
              value: controller.style,
              isExpanded: true,
              items: TtsSpeechStyle.values
                  .map(
                    (style) => ComboBoxItem<TtsSpeechStyle>(
                      value: style,
                      child: Text(style.label, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: controller.isLoading
                  ? null
                  : (style) {
                      if (style != null) unawaited(onStyleChanged(style));
                    },
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '朗读版本',
                style: theme.typography.body?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ToggleButton(
              checked: controller.mode == 'original',
              onChanged: controller.isLoading
                  ? null
                  : (checked) => unawaited(
                        controller.setMode(checked ? 'original' : 'translated'),
                      ),
              child: Text(controller.mode == 'original' ? '原文' : '译文'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: Row(
            children: <Widget>[
              const Text('语速'),
              Expanded(
                child: Slider(
                  value: controller.rate,
                  min: 0.2,
                  max: 1,
                  divisions: 8,
                  onChanged: (value) => unawaited(controller.setRate(value)),
                ),
              ),
              Text('${controller.rate.toStringAsFixed(2)}×'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: Row(
            children: <Widget>[
              const Text('音量'),
              Expanded(
                child: Slider(
                  value: controller.volume,
                  min: 0,
                  max: 1,
                  divisions: 10,
                  onChanged: (value) => unawaited(controller.setVolume(value)),
                ),
              ),
              Text('${(controller.volume * 100).round()}%'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: Text(
            controller.style.description,
            style: theme.typography.caption?.copyWith(height: 1.45),
          ),
        ),
      ],
    );
  }
}
