import 'dart:async';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/features/audiobook/audiobook_controller.dart';
import 'package:qingjuan/features/audiobook/audiobook_coordinator.dart';

const backgroundDetail = BookDetail(
  book: Book(
      id: 'background-book',
      title: '听书测试',
      sourceUrl: '',
      kind: '长小说',
      language: '中文',
      status: '已下载',
      chapterCount: 2,
      translated: false,
      synopsis: '',
      lastReadChapterIndex: 1),
  author: '作者',
  synopsis: '',
  totalWords: 2000,
  downloadedCount: 2,
  translatedCount: 0,
  progress: ReadingProgress(chapterIndex: 1, scrollRatio: 0),
  chapters: [
    Chapter(
        index: 1,
        title: '第一章',
        downloaded: true,
        translated: false,
        wordCount: 1000,
        imageCount: 0),
    Chapter(
        index: 2,
        title: '第二章',
        downloaded: true,
        translated: false,
        wordCount: 1000,
        imageCount: 0),
  ],
);
ChapterContent backgroundContent(int index, String mode, {String? text}) =>
    ChapterContent(
      chapter: backgroundDetail.chapters[index - 1],
      content: text ?? '甲' * 1700,
      paragraphs: const [],
      mode: mode,
      translatedAvailable: false,
      imageSources: const [],
      pageTranslations: const [],
    );

class BackgroundEngine implements TtsEngine {
  final spoken = <String>[];
  int pauses = 0, resumes = 0, disposals = 0, stops = 0;
  Completer<void>? speech;
  Completer<void>? resumeGate;
  @override
  Future<void> initialize(String language) async {}
  @override
  Future<void> setRate(double value) async {}
  @override
  Future<void> setPitch(double value) async {}
  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    speech = Completer<void>();
    await speech!.future;
  }

  void complete() {
    if (speech?.isCompleted == false) speech!.complete();
  }

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> resume() async {
    resumes++;
    await resumeGate?.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    complete();
  }

  @override
  Future<void> dispose() async {
    disposals++;
    complete();
  }
}

class BackgroundRuntime implements AudiobookPlatformRuntime {
  int activations = 0, deactivations = 0;
  AudiobookController? displayed;
  Completer<bool>? focus;
  @override
  Future<bool> activate() async {
    activations++;
    return focus?.future ?? true;
  }

  @override
  Future<void> deactivate() async {
    deactivations++;
  }

  @override
  void update(AudiobookController? controller) {
    displayed = controller;
  }

  @override
  Future<void> close() async {}
}
