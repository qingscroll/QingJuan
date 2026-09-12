import 'dart:async';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import '../../core/models/tts_speech_style.dart';
import '../../core/models/tts_voice.dart';
import '../../shared/motion.dart';
import '../../mobile/mobile_action_button.dart';
import 'audiobook_controller.dart';
import 'audiobook_coordinator.dart';
import 'audiobook_page.dart';

Future<void> showActiveAudiobook(BuildContext context,
    {required AudiobookCoordinator coordinator,
    TtsVoice? voice,
    Future<void> Function(TtsSpeechStyle style)? onStyleChanged}) async {
  final current = coordinator.current;
  if (current == null || current.isClosed) return;
  await Navigator.of(context).push<void>(qjPageRoute<void>(
    context: context,
    builder: (_) => AudiobookPage(
      detail: current.detail,
      loadChapter: current.loadChapter,
      controller: current,
      sleepTimer: coordinator.sleepTimer,
      voice: voice,
      style: current.style,
      onStyleChanged: onStyleChanged,
    ),
  ));
}

class AudiobookResumeEntry extends StatelessWidget {
  const AudiobookResumeEntry(
      {required this.coordinator,
      this.onOpen,
      this.voice,
      this.onStyleChanged,
      this.mobile = false,
      super.key});
  final AudiobookCoordinator coordinator;
  final bool mobile;
  final void Function(AudiobookController controller)? onOpen;
  final TtsVoice? voice;
  final Future<void> Function(TtsSpeechStyle style)? onStyleChanged;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: coordinator,
      builder: (context, _) {
        final current = coordinator.current;
        if (current == null) return const SizedBox.shrink();
        void open() {
          if (onOpen != null) {
            onOpen!(current);
            return;
          }
          unawaited(showActiveAudiobook(context,
              coordinator: coordinator,
              voice: voice,
              onStyleChanged: onStyleChanged));
        }

        final title =
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('听书 · ${current.detail.book.title}',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(current.currentChapter.title,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          if (coordinator.error != null) Text(coordinator.error!),
        ]);
        final VoidCallback? toggle = current.isLoading
            ? null
            : () {
                unawaited(current.isPlaying
                    ? coordinator.pause()
                    : coordinator.play());
              };
        void close() {
          unawaited(coordinator.stopAndClear());
        }

        final playIcon =
            current.isPlaying ? FluentIcons.pause : FluentIcons.play;
        final playLabel = current.isPlaying ? '暂停听书' : '继续听书';
        return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              Expanded(
                  child: mobile
                      ? MobileActionButton(
                          onPressed: open, tonal: true, child: title)
                      : Button(onPressed: open, child: title)),
              const SizedBox(width: 8),
              if (mobile) ...[
                SizedBox(
                    width: 48,
                    height: 48,
                    child: material.IconButton(
                        icon: Icon(playIcon),
                        tooltip: playLabel,
                        onPressed: toggle)),
                SizedBox(
                    width: 48,
                    height: 48,
                    child: material.IconButton(
                        icon: const Icon(FluentIcons.stop),
                        tooltip: '关闭听书',
                        onPressed: close)),
              ] else ...[
                IconButton(
                    icon: Icon(playIcon, semanticLabel: playLabel),
                    onPressed: toggle),
                IconButton(
                    icon: const Icon(FluentIcons.stop, semanticLabel: '关闭听书'),
                    onPressed: close),
              ],
            ]));
      });
}
