import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';

import 'audiobook_controller.dart';
import 'audiobook_coordinator.dart';
import 'flutter_tts_engine.dart';

/// Composition creates this object eagerly; Android services start on first play.
AudiobookCoordinator createAudiobookCoordinator() => AudiobookCoordinator(
      engineFactory: (voice) => FlutterTtsEngine(voice: voice),
      initializePlatform: (coordinator) async => Platform.isAndroid
          ? AndroidAudiobookRuntime.create(coordinator)
          : _SystemTtsRuntime(),
    );

class _SystemTtsRuntime implements AudiobookPlatformRuntime {
  @override
  Future<bool> activate() async => true;
  @override
  Future<void> deactivate() async {}
  @override
  void update(AudiobookController? controller) {}
  @override
  Future<void> close() async {}
}

class AndroidAudiobookRuntime implements AudiobookPlatformRuntime {
  AndroidAudiobookRuntime._(this.session, this.handler);
  final AudioSession session;
  final AudiobookMediaHandler handler;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _focusOperations = Future<void>.value();
  static Future<AudiobookMediaHandler>? _handlerFuture;

  static Future<AndroidAudiobookRuntime> create(
      AudiobookCoordinator coordinator) async {
    // audio_service owns one engine/handler for the application lifetime.
    final handler = await (_handlerFuture ??= AudioService.init(
      builder: AudiobookMediaHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.tavre.qingjuan.audiobook',
        androidNotificationChannelName: '青卷听书',
        androidNotificationIcon: 'drawable/ic_audiobook_notification',
        androidStopForegroundOnPause: false,
      ),
    ).catchError((Object error, StackTrace stack) {
      _handlerFuture = null;
      Error.throwWithStackTrace(error, stack);
    }));
    final session = await AudioSession.instance;
    // Configure after FlutterTts.initialize so plugin defaults cannot override speech focus.
    await session.configure(const AudioSessionConfiguration.speech());
    handler.coordinator = coordinator;
    final runtime = AndroidAudiobookRuntime._(session, handler);
    runtime._subscriptions.add(session.interruptionEventStream.listen((event) {
      unawaited(coordinator.interruption(
        begin: event.begin,
        mayResume: event.type != AudioInterruptionType.unknown,
      ));
    }));
    runtime._subscriptions.add(session.becomingNoisyEventStream.listen((_) {
      unawaited(coordinator.headphonesDisconnected());
    }));
    return runtime;
  }

  @override
  Future<bool> activate() {
    final result = _focusOperations.then((_) => session.setActive(true));
    _focusOperations = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<void> deactivate() async {
    final result = _focusOperations.then((_) => session.setActive(false));
    _focusOperations = result.then<void>((_) {}, onError: (Object _) {});
    await result;
  }

  @override
  void update(AudiobookController? controller) => handler.update(controller);
  @override
  Future<void> close() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    handler.update(null);
    handler.coordinator = null;
    await deactivate();
  }
}

/// No invented duration or seeking: system controls operate on real chapters.
class AudiobookMediaHandler extends BaseAudioHandler {
  AudiobookCoordinator? coordinator;

  void update(AudiobookController? controller) {
    if (controller == null) {
      mediaItem.add(null);
      playbackState
          .add(PlaybackState(processingState: AudioProcessingState.idle));
      return;
    }
    mediaItem.add(MediaItem(
      id: '${controller.detail.book.id}:${controller.chapterIndex}:${controller.mode}',
      title: controller.detail.book.title,
      album: controller.currentChapter.title,
      artist: controller.mode == 'original' ? '原文 · 青卷听书' : '译文 · 青卷听书',
    ));
    final live =
        controller.isPlaying || controller.isPaused || controller.isLoading;
    playbackState.add(PlaybackState(
      controls: live
          ? [
              MediaControl.skipToPrevious,
              controller.isPlaying ? MediaControl.pause : MediaControl.play,
              MediaControl.skipToNext,
              MediaControl.stop
            ]
          : const [],
      androidCompactActionIndices: live ? const [0, 1, 2] : const [],
      processingState: controller.isLoading
          ? AudioProcessingState.buffering
          : live
              ? AudioProcessingState.ready
              : AudioProcessingState.idle,
      playing: controller.isPlaying,
    ));
  }

  @override
  Future<void> play() async {
    unawaited(coordinator?.play());
  }

  @override
  Future<void> pause() async => coordinator?.pause();
  @override
  Future<void> stop() async => coordinator?.stop();
  @override
  Future<void> skipToNext() async {
    unawaited(coordinator?.next());
  }

  @override
  Future<void> skipToPrevious() async {
    unawaited(coordinator?.previous());
  }

  @override
  Future<void> onTaskRemoved() async => coordinator?.stop();
}
