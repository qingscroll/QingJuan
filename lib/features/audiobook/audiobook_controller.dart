import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/models/book.dart';
import '../../core/models/tts_speech_style.dart';
import '../../core/models/audiobook_position.dart';
import 'audiobook_positioning.dart';

typedef ChapterLoader = Future<ChapterContent> Function(
  int chapterIndex,
  String mode,
);

enum AudiobookPlaybackState {
  idle,
  loading,
  playing,
  paused,
  stopped,
  completed,
  error,
}

enum AudiobookControlIntent { play, pause, stop, chapter, mode }

abstract class TtsEngine {
  Future<void> initialize(String language);
  Future<void> speak(String text);
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> setRate(double value);
  Future<void> setPitch(double value);
  Future<void> setVolume(double value);
  Future<void> dispose();
}

List<String> splitTextForTts(String text, {int maxLength = 800}) {
  final limit = maxLength.clamp(8, 4000);
  final normalized = text
      .replaceAll('\r', '')
      .replaceAllMapped(
        RegExp(r'([。！？!?；;])\s*\n+'),
        (match) => match.group(1)!,
      )
      .replaceAll(RegExp(r'\s*\n+\s*'), '。')
      .replaceAll(RegExp(r'[\t ]+'), ' ')
      .trim();
  if (normalized.isEmpty) return const <String>[];

  final chunks = <String>[];
  var start = 0;
  const punctuation = '。！？!?；;，,、：:';
  while (start < normalized.length) {
    var end = (start + limit).clamp(0, normalized.length);
    if (end < normalized.length) {
      final minimumBreak = start + limit ~/ 3;
      for (var index = end - 1; index >= minimumBreak; index--) {
        if (punctuation.contains(normalized[index])) {
          end = index + 1;
          break;
        }
      }
    }
    final chunk = normalized.substring(start, end).trim();
    if (chunk.isNotEmpty) chunks.add(chunk);
    start = end;
  }
  return chunks;
}

class AudiobookController extends ChangeNotifier {
  AudiobookController({
    required this.detail,
    required this.engine,
    required this.loadChapter,
    int? initialChapterIndex,
    this.initialStyle = TtsSpeechStyle.natural,
    AudiobookPosition? initialPosition,
    this.beforePlay,
    this.onUserIntent,
  })  : chapterIndex = (initialChapterIndex ??
                initialPosition?.chapterIndex ??
                detail.progress.chapterIndex)
            .clamp(1, detail.chapters.length),
        _pendingRestore = initialChapterIndex == null ? initialPosition : null,
        mode = initialPosition?.mode ?? 'translated',
        style = initialStyle,
        rate = initialStyle.defaultRate;

  final BookDetail detail;
  final TtsEngine engine;
  final ChapterLoader loadChapter;
  final TtsSpeechStyle initialStyle;
  final Future<bool> Function()? beforePlay;
  final void Function(AudiobookControlIntent intent)? onUserIntent;

  AudiobookPlaybackState state = AudiobookPlaybackState.idle;
  int chapterIndex;
  int chunkIndex = 0;
  List<String> chunks = const <String>[];
  String mode;
  TtsSpeechStyle style;
  double rate;
  double volume = 1;
  String? error;

  bool _initialized = false;
  bool _disposed = false;
  bool _starting = false;
  bool _playLoopActive = false;
  int _startIntent = 0;
  int _playbackToken = 0;
  Completer<void>? _resumeSignal;
  Future<void>? _shutdown;
  AudiobookPosition? _pendingRestore;
  AudiobookPosition get position => captureAudiobookPosition(
      chapterIndex: chapterIndex,
      mode: mode,
      chunkIndex: chunkIndex,
      chunks: chunks);

  bool get isPlaying => state == AudiobookPlaybackState.playing;
  bool get isPaused => state == AudiobookPlaybackState.paused;
  bool get isLoading => state == AudiobookPlaybackState.loading;
  bool get isClosed => _disposed;
  bool get canPause => isPlaying || (_playLoopActive && isLoading);

  Chapter get currentChapter => detail.chapters.firstWhere(
        (chapter) => chapter.index == chapterIndex,
        orElse: () => detail.chapters.first,
      );

  String get currentText {
    if (chunks.isEmpty) return '';
    return chunks[chunkIndex.clamp(0, chunks.length - 1)];
  }

  double get chapterProgress {
    if (chunks.isEmpty) return 0;
    if (state == AudiobookPlaybackState.completed) return 100;
    return (chunkIndex / chunks.length * 100).clamp(0, 100);
  }

  Future<void> initialize() async {
    if (_initialized && state != AudiobookPlaybackState.error) return;
    _initialized = true;
    try {
      await engine.initialize(_languageCode(detail.book.language));
      await engine.setRate(rate);
      await engine.setPitch(style.basePitch);
      await engine.setVolume(volume);
      await _loadCurrentChapter();
    } catch (exception) {
      _setError(exception);
    }
  }

  Future<void> play({bool userInitiated = true}) async {
    if (userInitiated) onUserIntent?.call(AudiobookControlIntent.play);
    if (_disposed || isPlaying || isLoading || _starting) return;
    final startIntent = ++_startIntent;
    final startingToken = _playbackToken;
    if (_initialized &&
        state == AudiobookPlaybackState.stopped &&
        chunks.isEmpty) {
      // Stopping invalidates an in-flight chapter load. Only a new play intent
      // may reload it, and another stop must remain able to cancel that retry.
      await _loadCurrentChapter();
      if (_disposed ||
          startingToken != _playbackToken ||
          startIntent != _startIntent) {
        return;
      }
    }
    _starting = true;
    if (!_initialized) await initialize();
    if (state == AudiobookPlaybackState.error || chunks.isEmpty) {
      _starting = false;
      return;
    }
    try {
      if (beforePlay != null && !await beforePlay!()) {
        _starting = false;
        _setError(StateError('暂时无法获得音频播放权限，请稍后重试'));
        return;
      }
    } catch (exception) {
      _starting = false;
      _setError(exception);
      return;
    }
    if (_disposed ||
        startingToken != _playbackToken ||
        startIntent != _startIntent) {
      _starting = false;
      return;
    }
    if (isPaused) {
      try {
        await engine.resume();
        if (_disposed || startingToken != _playbackToken) return;
        if (startIntent != _startIntent) {
          await engine.pause();
          return;
        }
        state = AudiobookPlaybackState.playing;
        _releasePause();
        error = null;
        _notify();
      } catch (exception) {
        await _handleControlError(exception);
      } finally {
        _starting = false;
      }
      return;
    }
    if (state == AudiobookPlaybackState.completed) chunkIndex = 0;
    final token = ++_playbackToken;
    state = AudiobookPlaybackState.playing;
    _playLoopActive = true;
    _starting = false;
    error = null;
    _notify();

    try {
      while (token == _playbackToken && !_disposed) {
        while (chunkIndex < chunks.length && token == _playbackToken) {
          final chunk = chunks[chunkIndex];
          await engine.setRate(style.rateFor(chunk, rate));
          await engine.setPitch(style.pitchFor(chunk));
          await _waitWhilePaused();
          if (token != _playbackToken || _disposed) return;
          await engine.speak(chunk);
          if (token != _playbackToken || _disposed) return;
          await _waitWhilePaused();
          if (token != _playbackToken || _disposed) return;
          await Future<void>.delayed(style.pauseAfter(chunk));
          await _waitWhilePaused();
          if (token != _playbackToken || _disposed) return;
          chunkIndex += 1;
          _notify();
        }
        if (token != _playbackToken || _disposed) return;
        final nextChapter = _adjacentChapter(1);
        if (nextChapter == null) {
          state = AudiobookPlaybackState.completed;
          chunkIndex = chunks.isEmpty ? 0 : chunks.length - 1;
          _notify();
          return;
        }
        chapterIndex = nextChapter.index;
        chunkIndex = 0;
        await _loadCurrentChapter();
        if (token != _playbackToken || _disposed || chunks.isEmpty) return;
        await _waitWhilePaused();
        if (token != _playbackToken || _disposed) return;
        state = AudiobookPlaybackState.playing;
        _notify();
      }
    } catch (exception) {
      if (token == _playbackToken) _setError(exception);
    } finally {
      if (token == _playbackToken) _playLoopActive = false;
    }
  }

  Future<void> pause({bool userInitiated = true}) async {
    if (userInitiated) onUserIntent?.call(AudiobookControlIntent.pause);
    _startIntent++;
    if (_starting && !_playLoopActive) {
      _playbackToken++;
      state = AudiobookPlaybackState.stopped;
      _notify();
      return;
    }
    if (!canPause) return;
    final token = _playbackToken;
    _resumeSignal ??= Completer<void>();
    state = AudiobookPlaybackState.paused;
    _notify();
    try {
      await engine.pause();
      if (_disposed || token != _playbackToken) return;
      state = AudiobookPlaybackState.paused;
      _notify();
    } catch (exception) {
      await _handleControlError(exception);
    }
  }

  Future<void> stop(
      {bool resetPosition = false, bool userInitiated = true}) async {
    if (userInitiated) onUserIntent?.call(AudiobookControlIntent.stop);
    _playbackToken += 1;
    _playLoopActive = false;
    _releasePause();
    try {
      await engine.stop();
      if (_disposed) return;
      if (resetPosition) chunkIndex = 0;
      state = AudiobookPlaybackState.stopped;
      error = null;
      _notify();
    } catch (exception) {
      _setError(exception);
    }
  }

  Future<void> moveChapter(int delta, {bool autoplay = false}) async {
    onUserIntent?.call(AudiobookControlIntent.chapter);
    final target = _adjacentChapter(delta);
    if (target == null) return;
    final token = ++_playbackToken;
    _playLoopActive = false;
    _releasePause();
    try {
      await engine.stop();
      if (_disposed || token != _playbackToken) return;
      chapterIndex = target.index;
      chunkIndex = 0;
      await _loadCurrentChapter();
      if (_disposed || token != _playbackToken) return;
      if (autoplay && state != AudiobookPlaybackState.error) {
        await play();
      }
    } catch (exception) {
      if (token == _playbackToken) _setError(exception);
    }
  }

  Future<void> setMode(String value) async {
    onUserIntent?.call(AudiobookControlIntent.mode);
    if (value == mode) return;
    _playbackToken += 1;
    _playLoopActive = false;
    _releasePause();
    try {
      await engine.stop();
      mode = value;
      chunkIndex = 0;
      await _loadCurrentChapter();
    } catch (exception) {
      _setError(exception);
    }
  }

  Future<void> setRate(double value) async {
    rate = value.clamp(0.2, 1);
    _notify();
    try {
      await engine.setRate(rate);
    } catch (exception) {
      await _handleControlError(exception);
    }
  }

  Future<void> setStyle(TtsSpeechStyle value) async {
    if (style == value) return;
    style = value;
    rate = value.defaultRate;
    _notify();
    try {
      await engine.setRate(rate);
      await engine.setPitch(value.basePitch);
    } catch (exception) {
      await _handleControlError(exception);
    }
  }

  Future<void> setVolume(double value) async {
    volume = value.clamp(0, 1);
    _notify();
    try {
      await engine.setVolume(volume);
    } catch (exception) {
      await _handleControlError(exception);
    }
  }

  Future<void> _handleControlError(Object exception) async {
    _playbackToken += 1;
    _playLoopActive = false;
    _releasePause();
    try {
      await engine.stop();
    } catch (_) {
      // 原始控制错误更有诊断价值；停止失败不应再形成未处理异步异常。
    }
    _setError(exception);
  }

  Future<void> _loadCurrentChapter() async {
    final token = _playbackToken;
    chunks = const [];
    state = AudiobookPlaybackState.loading;
    error = null;
    _notify();
    try {
      final content = await loadChapter(chapterIndex, mode);
      if (_disposed || token != _playbackToken) return;
      final text = content.content.trim().isNotEmpty
          ? content.content
          : content.paragraphs.join('\n');
      chunks = splitTextForTts(text);
      if (chunks.isEmpty) {
        throw StateError('当前章节没有可朗读的文字内容');
      }
      chunkIndex = chunkIndex.clamp(0, chunks.length - 1);
      final restore = _pendingRestore;
      _pendingRestore = null;
      if (restore != null &&
          restore.chapterIndex == chapterIndex &&
          restore.mode == mode) {
        chunkIndex = restoreAudiobookChunk(chunks, restore);
      }
      state = _resumeSignal == null
          ? AudiobookPlaybackState.idle
          : AudiobookPlaybackState.paused;
      _notify();
    } catch (exception) {
      if (token == _playbackToken) _setError(exception);
    }
  }

  Chapter? _adjacentChapter(int delta) {
    final currentPosition = detail.chapters.indexWhere(
      (chapter) => chapter.index == chapterIndex,
    );
    final nextPosition = currentPosition + delta;
    if (currentPosition < 0 ||
        nextPosition < 0 ||
        nextPosition >= detail.chapters.length) {
      return null;
    }
    return detail.chapters[nextPosition];
  }

  void _setError(Object exception) {
    if (_disposed) return;
    error = _readableTtsError(exception);
    state = AudiobookPlaybackState.error;
    _notify();
  }

  String _readableTtsError(Object exception) {
    if (exception is StateError) {
      return exception.message.toString();
    }
    if (exception is PlatformException) {
      final message = exception.message?.trim();
      return message == null || message.isEmpty
          ? '设备朗读服务调用失败，请检查 TTS 引擎和语音包后重试'
          : '设备朗读失败：$message';
    }
    return '设备朗读服务暂时不可用，请停止后重试';
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _waitWhilePaused() async {
    if (isPaused) await _resumeSignal?.future;
  }

  void _releasePause() {
    final signal = _resumeSignal;
    _resumeSignal = null;
    if (signal?.isCompleted == false) signal!.complete();
  }

  Future<void> shutdown() {
    if (_shutdown != null) return _shutdown!;
    _disposed = true;
    chunks = const [];
    state = AudiobookPlaybackState.stopped;
    notifyListeners();
    _playbackToken++;
    _releasePause();
    return _shutdown ??= engine.dispose();
  }

  String _languageCode(String language) => switch (language) {
        '英文' => 'en-US',
        '日文' => 'ja-JP',
        _ => 'zh-CN',
      };

  @override
  void dispose() {
    unawaited(shutdown().catchError((Object _) {
      // Widget 已销毁，TTS 关闭只能尽力完成，不能再向界面发送错误状态。
    }));
    super.dispose();
  }
}
