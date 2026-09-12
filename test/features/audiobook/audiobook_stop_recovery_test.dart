import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/models/audiobook_position.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/features/audiobook/audiobook_controller.dart';
import 'package:qingjuan/features/audiobook/audiobook_coordinator.dart';
import 'package:qingjuan/features/audiobook/audiobook_media_runtime.dart';
import 'package:qingjuan/features/audiobook/audiobook_position_store.dart';

import 'audiobook_background_fixtures.dart';

void main() {
  for (final stopFrom in ['media', 'sleep timer']) {
    for (final oldLoadFinishesFirst in [true, false]) {
      test(
          '$stopFrom stops an automatic chapter load and playback can recover '
          '(old load finishes first: $oldLoadFinishesFirst)', () async {
        final engine = BackgroundEngine();
        final runtime = BackgroundRuntime();
        final coordinator = AudiobookCoordinator(
            engineFactory: (_) => engine,
            initializePlatform: (_) async => runtime,
            positionStore: (_, __, ___) => _MemoryPositionStore());
        final requested = Completer<void>();
        final oldLoad = Completer<ChapterContent>();
        var chapterLoads = 0;
        addTearDown(() async {
          if (!oldLoad.isCompleted) {
            oldLoad.complete(backgroundContent(2, 'translated'));
          }
          await coordinator.close();
        });
        final controller = await coordinator.open(
            instanceId: 'instance',
            ownerId: 'owner',
            detail: backgroundDetail,
            isCurrentContext: () => true,
            loadChapter: (index, mode) async {
              if (index == 1) {
                return backgroundContent(index, mode, text: '第一章。');
              }
              chapterLoads++;
              if (chapterLoads == 1) {
                requested.complete();
                return oldLoad.future;
              }
              return backgroundContent(index, mode, text: '重新加载的第二章。');
            });
        final originalPlayback = coordinator.play();
        await _settle();
        expect(engine.spoken, ['第一章。']);
        engine.complete();
        await requested.future;
        expect(controller.isLoading, isTrue);

        if (stopFrom == 'media') {
          final handler = AudiobookMediaHandler()..coordinator = coordinator;
          await handler.stop();
        } else {
          await coordinator.sleepTimer.onElapsed();
        }
        expect(controller.state, AudiobookPlaybackState.stopped);

        if (oldLoadFinishesFirst) {
          oldLoad.complete(backgroundContent(2, 'translated', text: '旧请求。'));
          await originalPlayback;
          expect(controller.state, AudiobookPlaybackState.stopped);
          expect(engine.spoken, ['第一章。']);
          expect(chapterLoads, 1);
        }

        final resumedPlayback = coordinator.play();
        await _settle();
        expect(chapterLoads, 2,
            reason: 'An explicit play must reload a cancelled chapter');
        expect(controller.isPlaying, isTrue);
        expect(engine.spoken, ['第一章。', '重新加载的第二章。']);
        if (!oldLoadFinishesFirst) {
          oldLoad.complete(backgroundContent(2, 'translated', text: '旧请求。'));
          await originalPlayback;
          expect(controller.currentText, '重新加载的第二章。');
          expect(controller.isPlaying, isTrue);
          expect(engine.spoken, ['第一章。', '重新加载的第二章。']);
        }
        await coordinator.stop();
        await resumedPlayback;
      });
    }
  }

  test('a stopped manual chapter load cannot restart its old autoplay intent',
      () async {
    final engine = BackgroundEngine();
    final requested = Completer<void>();
    final oldLoad = Completer<ChapterContent>();
    var chapterLoads = 0;
    final controller = AudiobookController(
        detail: backgroundDetail,
        engine: engine,
        loadChapter: (index, mode) async {
          if (index == 1) return backgroundContent(index, mode);
          chapterLoads++;
          if (chapterLoads == 1) {
            requested.complete();
            return oldLoad.future;
          }
          return backgroundContent(index, mode, text: '重新加载的第二章。');
        });
    addTearDown(controller.dispose);
    await controller.initialize();
    final moving = controller.moveChapter(1, autoplay: true);
    await requested.future;
    await controller.stop();
    oldLoad.complete(backgroundContent(2, 'translated', text: '旧请求。'));
    await _settle();
    expect(controller.state, AudiobookPlaybackState.stopped);
    expect(chapterLoads, 1,
        reason: 'A superseded autoplay intent must not trigger a new load');
    expect(engine.spoken, isEmpty);
    await moving;

    final resumedPlayback = controller.play();
    await _settle();
    expect(engine.spoken, ['重新加载的第二章。']);
    expect(controller.isPlaying, isTrue);
    await controller.stop();
    await resumedPlayback;
  });

  for (final lateLoadFails in [false, true]) {
    test(
        'stopping a recovery load allows another play before old requests finish '
        '(late loads fail: $lateLoadFails)', () async {
      final engine = BackgroundEngine();
      final loads = <Completer<ChapterContent>>[];
      final controller = AudiobookController(
          detail: backgroundDetail,
          engine: engine,
          loadChapter: (index, mode) async {
            if (index == 1) return backgroundContent(index, mode);
            final pending = Completer<ChapterContent>();
            loads.add(pending);
            return pending.future;
          });
      addTearDown(() {
        controller.dispose();
        for (final pending in loads) {
          if (!pending.isCompleted) {
            pending.complete(backgroundContent(2, 'translated'));
          }
        }
      });
      await controller.initialize();
      final moving = controller.moveChapter(1, autoplay: true);
      await _settle();
      expect(loads, hasLength(1));
      await controller.stop();
      final firstRecovery = controller.play();
      await _settle();
      expect(loads, hasLength(2));
      expect(controller.isLoading, isTrue);
      await controller.stop();
      final secondRecovery = controller.play();
      await _settle();
      expect(loads, hasLength(3));

      loads.last.complete(backgroundContent(2, 'translated', text: '最新请求的正文。'));
      await _settle();
      expect(engine.spoken, ['最新请求的正文。']);
      expect(controller.isPlaying, isTrue);
      for (final pending in loads.take(2)) {
        if (lateLoadFails) {
          pending.completeError(StateError('旧章节请求失败'));
        } else {
          pending.complete(backgroundContent(2, 'translated', text: '旧请求。'));
        }
      }
      await Future.wait([moving, firstRecovery]);
      expect(engine.spoken, ['最新请求的正文。']);
      expect(controller.currentText, '最新请求的正文。');
      expect(controller.isPlaying, isTrue);
      expect(controller.error, isNull);
      await controller.stop();
      await secondRecovery;
    });
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

class _MemoryPositionStore implements AudiobookPositionStore {
  @override
  Future<AudiobookPosition?> load() async => null;
  @override
  Future<void> save(AudiobookPosition position) async {}
}
