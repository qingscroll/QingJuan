import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/models/audiobook_position.dart';
import 'package:qingjuan/features/audiobook/audiobook_controller.dart';
import 'package:qingjuan/features/audiobook/audiobook_coordinator.dart';
import 'package:qingjuan/features/audiobook/audiobook_position_store.dart';
import 'package:qingjuan/features/audiobook/audiobook_positioning.dart';
import 'package:qingjuan/features/audiobook/audiobook_sleep_timer.dart';
import 'package:qingjuan/features/audiobook/audiobook_media_runtime.dart';
import 'package:audio_service/audio_service.dart';
import 'audiobook_background_fixtures.dart';

void main() {
  test(
      'file position isolates instance owner book and ignores incomplete commit',
      () async {
    final dir = await Directory.systemTemp.createTemp('qj-audiobook-');
    addTearDown(() => dir.delete(recursive: true));
    FileAudiobookPositionStore store(
            String instance, String owner, String book) =>
        FileAudiobookPositionStore(
            instanceId: instance,
            ownerId: owner,
            bookId: book,
            directory: () async => dir);
    final first = store('instance', 'owner', 'book');
    final position = captureAudiobookPosition(
        chapterIndex: 1,
        mode: 'original',
        chunkIndex: 1,
        chunks: ['secret body', 'second']);
    await first.save(position);
    await first.save(captureAudiobookPosition(
        chapterIndex: 2, mode: 'translated', chunkIndex: 0, chunks: ['other']));
    final files = await dir
        .list(recursive: true)
        .where((f) => f is File)
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    await files.first.writeAsString('{torn');
    final restored = await first.load();
    expect(restored!.chunkIndex, 1);
    expect(restored.mode, 'original');
    for (final scope in [
      ['other', 'owner', 'book'],
      ['instance', 'other', 'book'],
      ['instance', 'owner', 'other']
    ]) {
      expect(await store(scope[0], scope[1], scope[2]).load(), isNull);
    }
    final text = await files.last.readAsString();
    expect(text, isNot(contains('secret body')));
    expect(text, isNot(contains('owner')));
    expect(text, isNot(contains('token')));
  });

  test(
      'position restores exact chunk or safe character offset after content changes',
      () {
    final saved = captureAudiobookPosition(
        chapterIndex: 1,
        mode: 'original',
        chunkIndex: 1,
        chunks: ['aaaa', 'bbbb', 'cccc']);
    expect(restoreAudiobookChunk(['aaaa', 'bbbb', 'cccc'], saved), 1);
    expect(restoreAudiobookChunk(['ab', 'cd', 'long changed paragraph'], saved),
        2);
    expect(restoreAudiobookChunk(['short'], saved), 0);
  });

  test('timer catches elapsed background deadline once and cancellation wins',
      () async {
    var now = DateTime.utc(2026);
    var stopped = 0;
    final timer = AudiobookSleepTimer(
        onElapsed: () async {
          stopped++;
        },
        now: () => now);
    addTearDown(timer.dispose);
    timer.set(const Duration(minutes: 5));
    now = now.add(const Duration(minutes: 10));
    await timer.checkOnResume();
    await timer.checkOnResume();
    expect(stopped, 1);
    expect(timer.deadline, isNull);
    timer.set(const Duration(minutes: 1));
    timer.set(null);
    now = now.add(const Duration(hours: 1));
    await timer.checkOnResume();
    expect(stopped, 1);
  });

  late AudiobookCoordinator coordinator;
  late List<BackgroundEngine> engines;
  late BackgroundRuntime runtime;
  late _MemoryStore positions;
  var platformStarts = 0;
  setUp(() {
    engines = [];
    runtime = BackgroundRuntime();
    positions = _MemoryStore();
    platformStarts = 0;
    coordinator = AudiobookCoordinator(
        engineFactory: (_) {
          final engine = BackgroundEngine();
          engines.add(engine);
          return engine;
        },
        initializePlatform: (_) async {
          platformStarts++;
          return runtime;
        },
        positionStore: (instance, owner, book) => positions);
  });
  tearDown(() async {
    await coordinator.close();
  });
  Future<AudiobookController> open(
          {String owner = 'owner', bool Function()? guard}) =>
      coordinator.open(
          instanceId: 'instance',
          ownerId: owner,
          detail: backgroundDetail,
          loadChapter: (index, mode) async => backgroundContent(index, mode),
          isCurrentContext: guard ?? () => true);

  test('opening and reentering book is lazy and preserves shared position',
      () async {
    final controller = await open();
    expect(platformStarts, 0);
    controller.chunkIndex = 1;
    expect(await open(), same(controller));
    expect(controller.chunkIndex, 1);
    final playing = coordinator.play();
    await _settle();
    expect(platformStarts, 1);
    expect(engines.single.spoken.single.length, 800);
    await coordinator.stop();
    await playing;
    expect(positions.position!.chunkIndex, 1);
    expect(controller.chunkIndex, 1);
    await coordinator.stopAndClear();
    final restored = await open();
    expect(restored.chunkIndex, 1);
    expect(restored.isPlaying, isFalse);
    expect(platformStarts, 1);
  });

  test('transient audio interruption resumes only without a newer user intent',
      () async {
    final controller = await open();
    final playing = coordinator.play();
    await _settle();
    await coordinator.interruption(begin: true, mayResume: true);
    expect(controller.isPaused, isTrue);
    await coordinator.interruption(begin: false, mayResume: true);
    await _settle();
    expect(controller.isPlaying, isTrue);
    expect(engines.single.resumes, 1);
    await coordinator.interruption(begin: true, mayResume: true);
    await controller.pause();
    await coordinator.interruption(begin: false, mayResume: true);
    await _settle();
    expect(controller.isPaused, isTrue);
    expect(engines.single.resumes, 1);
    await coordinator.stop();
    await playing;
  });

  test('unplugging headphones cannot auto resume after an interruption',
      () async {
    final controller = await open();
    final playing = coordinator.play();
    await _settle();
    await coordinator.interruption(begin: true, mayResume: true);
    await coordinator.headphonesDisconnected();
    await coordinator.interruption(begin: false, mayResume: true);
    expect(controller.isPaused, isTrue);
    expect(engines.single.resumes, 0);
    await coordinator.stop();
    await playing;
  });

  test(
      'logout hides and closes old content immediately, with no late audio start',
      () async {
    var valid = true;
    final controller = await open(guard: () => valid);
    runtime.focus = Completer<bool>();
    final playing = coordinator.play();
    await _settle();
    valid = false;
    final closing = coordinator.stopAndClear();
    expect(coordinator.current, isNull);
    runtime.focus!.complete(true);
    await closing;
    await playing;
    expect(controller.isClosed, isTrue);
    expect(controller.chunks, isEmpty);
    expect(engines.single.spoken, isEmpty);
    expect(engines.single.disposals, 1);
    expect(runtime.displayed, isNull);
  });

  test('pause during focus acquisition cancels late playback', () async {
    final controller = await open();
    runtime.focus = Completer<bool>();
    final playing = coordinator.play();
    await _settle();
    await controller.pause();
    runtime.focus!.complete(true);
    await playing;
    expect(engines.single.spoken, isEmpty);
    expect(controller.isPlaying, isFalse);
  });

  test('a newer pause wins while the native resume call is still pending',
      () async {
    final controller = await open();
    final playing = coordinator.play();
    await _settle();
    await controller.pause();
    engines.single.resumeGate = Completer<void>();
    final resuming = controller.play();
    await _settle();
    await controller.pause();
    engines.single.resumeGate!.complete();
    await resuming;
    expect(controller.isPaused, isTrue);
    expect(engines.single.pauses, 2);
    await coordinator.stop();
    await playing;
  });

  test(
      'concurrent opens discard the superseded request before creating an engine',
      () async {
    final first = open();
    final rejected = expectLater(first, throwsStateError);
    final second = await open(owner: 'second-owner');
    await rejected;
    expect(engines, hasLength(1));
    expect(coordinator.current, same(second));
  });

  test(
      'media state exposes chapter controls without fabricated duration or text',
      () async {
    final controller = await open();
    final handler = AudiobookMediaHandler();
    handler.coordinator = coordinator;
    final playing = coordinator.play();
    await _settle();
    handler.update(controller);
    expect(handler.mediaItem.value!.title, backgroundDetail.book.title);
    expect(handler.mediaItem.value!.duration, isNull);
    expect(handler.mediaItem.value!.artUri, isNull);
    expect(handler.playbackState.value.controls, contains(MediaControl.pause));
    expect(handler.playbackState.value.systemActions,
        isNot(contains(MediaAction.seek)));
    await handler.pause();
    expect(controller.isPaused, isTrue);
    await handler.stop();
    await playing;
    handler.update(null);
    expect(handler.mediaItem.value, isNull);
    expect(
        handler.playbackState.value.processingState, AudioProcessingState.idle);
  });
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

class _MemoryStore implements AudiobookPositionStore {
  AudiobookPosition? position;
  @override
  Future<AudiobookPosition?> load() async => position;
  @override
  Future<void> save(AudiobookPosition value) async {
    position = value;
  }
}
