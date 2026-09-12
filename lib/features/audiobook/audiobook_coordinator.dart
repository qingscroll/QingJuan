import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../core/models/book.dart';
import '../../core/models/tts_speech_style.dart';
import '../../core/models/tts_voice.dart';
import 'audiobook_controller.dart';
import 'audiobook_position_store.dart';
import 'audiobook_sleep_timer.dart';

abstract interface class AudiobookPlatformRuntime {
  Future<bool> activate();
  Future<void> deactivate();
  void update(AudiobookController? controller);
  Future<void> close();
}

typedef AudiobookStoreFactory = AudiobookPositionStore Function(
    String instanceId, String ownerId, String bookId);
typedef AudiobookRuntimeFactory = Future<AudiobookPlatformRuntime> Function(
    AudiobookCoordinator coordinator);

class AudiobookCoordinator extends ChangeNotifier {
  AudiobookCoordinator(
      {required this.engineFactory,
      required this.initializePlatform,
      AudiobookStoreFactory? positionStore})
      : _positionStore = positionStore ??
            ((instance, owner, book) => FileAudiobookPositionStore(
                instanceId: instance, ownerId: owner, bookId: book)) {
    sleepTimer = AudiobookSleepTimer(onElapsed: stop);
  }
  final TtsEngine Function(TtsVoice? voice) engineFactory;
  final AudiobookRuntimeFactory initializePlatform;
  final AudiobookStoreFactory _positionStore;
  late final AudiobookSleepTimer sleepTimer;
  AudiobookController? _current;
  AudiobookController? get current => _current;
  AudiobookPositionStore? _store;
  String? _sessionKey;
  bool Function() _contextGuard = () => false;
  int _generation = 0;
  int _openRequest = 0;
  int _intent = 0;
  int? _resumeIntent;
  int? _resumeGeneration;
  bool _disposed = false;
  String? error;
  String? _savedPosition;
  Future<void> _writes = Future<void>.value();
  Future<AudiobookPlatformRuntime>? _runtimeFuture;
  AudiobookPlatformRuntime? _runtime;
  Future<void> _closing = Future<void>.value();
  Future<void>? _closeFuture;

  Future<AudiobookController> open(
      {required String instanceId,
      required String ownerId,
      required BookDetail detail,
      required ChapterLoader loadChapter,
      required bool Function() isCurrentContext,
      int? initialChapterIndex,
      TtsVoice? voice,
      TtsSpeechStyle style = TtsSpeechStyle.natural}) async {
    if (_disposed ||
        instanceId.isEmpty ||
        ownerId.isEmpty ||
        !isCurrentContext()) {
      throw StateError('当前听书身份不可用，请重新打开作品');
    }
    final request = ++_openRequest;
    final key =
        jsonEncode([instanceId, ownerId, detail.book.id, voice?.pluginValue]);
    final active = _current;
    if (active != null && _sessionKey == key && _contextGuard()) {
      if (initialChapterIndex != null &&
          initialChapterIndex != active.chapterIndex) {
        final from =
            detail.chapters.indexWhere((c) => c.index == active.chapterIndex);
        final to =
            detail.chapters.indexWhere((c) => c.index == initialChapterIndex);
        if (from >= 0 && to >= 0) await active.moveChapter(to - from);
      }
      return active;
    }
    await _clear(invalidateOpen: false);
    if (request != _openRequest || !isCurrentContext() || _disposed) {
      throw StateError('听书身份已切换');
    }
    final generation = ++_generation;
    final store = _positionStore(instanceId, ownerId, detail.book.id);
    final saved = await store.load();
    if (generation != _generation || !isCurrentContext() || _disposed) {
      throw StateError('听书身份已切换');
    }
    _store = store;
    _sessionKey = key;
    _contextGuard = isCurrentContext;
    _savedPosition = null;
    error = null;
    late final AudiobookController controller;
    controller = AudiobookController(
        detail: detail,
        engine: engineFactory(voice),
        loadChapter: (index, mode) async {
          if (!_valid(generation)) throw StateError('听书身份已切换');
          final content = await loadChapter(index, mode);
          if (!_valid(generation)) throw StateError('听书身份已切换');
          return content;
        },
        initialChapterIndex: initialChapterIndex,
        initialPosition: saved,
        initialStyle: style,
        beforePlay: () => _beforePlay(generation),
        onUserIntent: _userIntent);
    _current = controller;
    controller.addListener(_changed);
    await controller.initialize();
    if (!_valid(generation)) throw StateError('听书身份已切换');
    _changed();
    return controller;
  }

  bool _valid(int generation) =>
      !_disposed && generation == _generation && _contextGuard();

  Future<bool> _beforePlay(int generation) async {
    if (!_valid(generation)) return false;
    late final AudiobookPlatformRuntime runtime;
    try {
      runtime = await (_runtimeFuture ??= initializePlatform(this));
    } catch (_) {
      _runtimeFuture = null;
      rethrow;
    }
    _runtime = runtime;
    if (!_valid(generation)) return false;
    final active = await runtime.activate();
    if (!_valid(generation)) {
      await runtime.deactivate();
      return false;
    }
    return active;
  }

  void _userIntent(AudiobookControlIntent intent) {
    _intent++;
    _resumeIntent = null;
    _resumeGeneration = null;
    if (intent == AudiobookControlIntent.stop) sleepTimer.set(null);
  }

  void _changed() {
    final controller = _current;
    _runtime?.update(controller);
    if (controller != null &&
        const [
          AudiobookPlaybackState.stopped,
          AudiobookPlaybackState.completed,
          AudiobookPlaybackState.error
        ].contains(controller.state)) {
      unawaited(_runtime?.deactivate().catchError((Object _) {
        if (!_disposed) error = '系统音频会话尚未释放，请停止后重试';
      }));
    }
    if (controller != null &&
        controller.chunks.isNotEmpty &&
        !controller.isLoading) {
      final position = controller.position;
      final key = jsonEncode(position.toJson());
      final store = _store;
      if (store != null && key != _savedPosition) {
        _savedPosition = key;
        _writes =
            _writes.then((_) => store.save(position)).catchError((Object _) {
          if (!_disposed && identical(store, _store)) {
            _savedPosition = null;
            error = '听书位置尚未保存，请检查设备空间';
            notifyListeners();
          }
        });
      }
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> play() async => _current?.play();
  Future<void> pause() async => _current?.pause();
  Future<void> stop() async {
    sleepTimer.set(null);
    await _current?.stop();
    await _runtime?.deactivate();
    await _writes;
  }

  Future<void> previous() async =>
      _current?.moveChapter(-1, autoplay: _current?.isPlaying ?? false);
  Future<void> next() async =>
      _current?.moveChapter(1, autoplay: _current?.isPlaying ?? false);

  Future<void> interruption(
      {required bool begin, required bool mayResume}) async {
    final controller = _current;
    if (controller == null) return;
    if (begin) {
      if (!controller.canPause) return;
      _resumeIntent = mayResume ? _intent : null;
      _resumeGeneration = mayResume ? _generation : null;
      await controller.pause(userInitiated: false);
      return;
    }
    final resume = mayResume &&
        _resumeIntent == _intent &&
        _resumeGeneration == _generation &&
        _contextGuard() &&
        controller.isPaused;
    _resumeIntent = null;
    _resumeGeneration = null;
    if (resume) unawaited(controller.play(userInitiated: false));
  }

  Future<void> headphonesDisconnected() async {
    _userIntent(AudiobookControlIntent.pause);
    await _current?.pause(userInitiated: false);
  }

  Future<void> stopAndClear() => _clear(invalidateOpen: true);

  Future<void> _clear({required bool invalidateOpen}) {
    if (_disposed) return _closing;
    if (invalidateOpen) ++_openRequest;
    ++_generation;
    sleepTimer.set(null);
    final previous = _current;
    if (previous != null) {
      _changed();
      previous.removeListener(_changed);
    }
    _current = null;
    _sessionKey = null;
    _contextGuard = () => false;
    _store = null;
    _runtime?.update(null);
    if (!_disposed) notifyListeners();
    _closing = _closing.then((_) async {
      if (previous != null) {
        try {
          await previous.shutdown();
        } catch (_) {
          error = '听书关闭未完成，请检查系统朗读服务';
        } finally {
          previous.dispose();
        }
      }
      await _runtime?.deactivate();
      await _writes;
    }).catchError((Object _) {
      if (!_disposed) error = '听书关闭未完成，请检查系统朗读服务';
    });
    return _closing;
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    await stopAndClear();
    _disposed = true;
    sleepTimer.dispose();
    try {
      final runtime = _runtime ?? await _runtimeFuture;
      await runtime?.close();
    } catch (_) {
      // The application is already disposed; no late UI callback is possible.
    } finally {
      super.dispose();
    }
  }
}
