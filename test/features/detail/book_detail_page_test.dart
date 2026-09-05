import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/app/app_theme.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/detail/book_detail_page.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/manga_translation/manga_bookshelf_import.dart';
import 'package:qingjuan/features/manga_translation/manga_translation_coordinator.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:qingjuan/shared/responsive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../reader/mobile_fixture_capture.dart';

void main() {
  setUpAll(loadMobileCaptureFonts);
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  for (final brightness in Brightness.values) {
    testWidgets('mobile detail fixture ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      final harness = await _Harness.create(
        MockClient((_) async => _jsonResponse(_detailPayload)),
        brightness: brightness,
        child: const UiPlatformScope(
            platform: TargetPlatform.android,
            child: BookDetailPage(bookId: 'book-1')),
      );
      addTearDown(harness.dispose);
      await tester.pumpWidget(RepaintBoundary(key: key, child: harness.widget));
      await tester.pumpAndSettle();
      expect(find.text('开始阅读'), findsOneWidget);
      await saveMobileFixture(tester, key, 'detail-${brightness.name}');
      await tester.tap(find.byIcon(FluentIcons.more));
      await tester.pumpAndSettle();
      expect(find.text('下载全部章节'), findsOneWidget);
      expect(find.text('导出全部章节'), findsOneWidget);
      await saveMobileFixture(tester, key, 'detail-actions-${brightness.name}');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'mobile download posts a task and preserves selected chapter scope',
      (tester) async {
    final downloaded = <int>[];
    final harness = await _Harness.create(MockClient((request) async {
      if (request.url.path == '/api/v1/books/book-1/chapters/download') {
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        downloaded.addAll((payload['chapterIndexes'] as List).cast<int>());
        return _jsonResponse({
          'id': 'download-1',
          'bookId': 'book-1',
          'taskType': 'download',
          'status': 'queued',
          'totalCount': 1,
          'completedCount': 0,
          'progress': 0
        });
      }
      if (request.url.path == '/api/v1/tasks') return _jsonResponse([]);
      return _jsonResponse(_detailPayloadWithKind('长小说'));
    }),
        child: const UiPlatformScope(
            platform: TargetPlatform.android,
            child: BookDetailPage(bookId: 'book-1')));
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mobile-chapter-1')));
    await tester.pump();
    await tester.tap(find.text('管理所选章节'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载所选章节'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(downloaded, [1]);
    expect(find.text('TXT'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 740), const Size(1024, 800)]) {
    testWidgets('mobile detail supports 200 percent text at $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final harness = await _Harness.create(
          MockClient((_) async => _jsonResponse(_detailPayloadWithKind('长小说'))),
          child: MediaQuery(
              data: MediaQueryData(
                  size: size, textScaler: const TextScaler.linear(2)),
              child: const UiPlatformScope(
                  platform: TargetPlatform.android,
                  child: BookDetailPage(bookId: 'book-1'))));
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.widget);
      await tester.pumpAndSettle();
      expect(find.text('开始阅读'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('posts the selected chapter export format and destination', () async {
    final directory = await Directory.systemTemp.createTemp('qingjuan-export-');
    addTearDown(() => directory.delete(recursive: true));
    final targetPath = '${directory.path}${Platform.pathSeparator}第三章.docx';
    late http.Request capturedRequest;
    final api = ApiClient(
      () => 'http://127.0.0.1:8000',
      client: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response.bytes(<int>[1, 2, 3], 200);
        }
        capturedRequest = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'bookId': 'book-1',
            'chapterIndex': 3,
            'format': 'docx',
            'artifactId': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'fileName': '第三章.docx',
            'downloadUrl':
                '/books/book-1/exports/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'contentType':
                'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            'sizeBytes': 3,
            'expiresAt': '2026-08-11T00:00:00Z',
            'fileCount': 1,
          }),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
    );
    addTearDown(api.close);

    final result = await api.exportChapter(
      bookId: 'book-1',
      chapterIndex: 3,
      format: 'docx',
      targetPath: targetPath,
    );

    expect(capturedRequest.method, 'POST');
    expect(capturedRequest.url.path, '/api/v1/books/book-1/chapters/3/export');
    expect(
      jsonDecode(capturedRequest.body),
      <String, Object?>{
        'format': 'docx',
      },
    );
    expect(result['fileCount'], 1);
    expect(await File(targetPath).readAsBytes(), <int>[1, 2, 3]);
  });

  test('posts selected chapters through the book export endpoint', () async {
    final directory = await Directory.systemTemp.createTemp('qingjuan-export-');
    addTearDown(() => directory.delete(recursive: true));
    final targetPath = '${directory.path}${Platform.pathSeparator}测试作品.epub';
    late http.Request capturedRequest;
    final api = ApiClient(
      () => 'http://127.0.0.1:8000',
      client: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response.bytes(<int>[4, 5, 6], 200);
        }
        capturedRequest = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'bookId': 'book-1',
            'format': 'epub',
            'artifactId': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            'fileName': '测试作品.epub',
            'downloadUrl':
                '/books/book-1/exports/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            'contentType': 'application/epub+zip',
            'sizeBytes': 3,
            'expiresAt': '2026-08-11T00:00:00Z',
            'chapterCount': 2,
            'fileCount': 1,
          }),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
    );
    addTearDown(api.close);

    final result = await api.exportBook(
      bookId: 'book-1',
      chapterIndexes: const <int>[2, 4],
      format: 'epub',
      targetPath: targetPath,
    );

    expect(capturedRequest.method, 'POST');
    expect(capturedRequest.url.path, '/api/v1/books/book-1/export');
    expect(
      jsonDecode(capturedRequest.body),
      <String, Object?>{
        'format': 'epub',
        'chapterIndexes': <int>[2, 4],
      },
    );
    expect(result['chapterCount'], 2);
    expect(await File(targetPath).readAsBytes(), <int>[4, 5, 6]);
  });

  testWidgets('loads detail after AppScope becomes available', (tester) async {
    final harness = await _Harness.create(
      MockClient((request) async {
        expect(request.url.path, '/api/v1/books/book-1');
        return http.Response(
          jsonEncode(_detailPayload),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('测试作品'), findsWidgets);
    expect(find.text('暂时无法加载'), findsNothing);
    expect(find.text('听小说'), findsOneWidget);
  });

  testWidgets(
      'Android detail expands the full synopsis in the main reading flow',
      (tester) async {
    final longSynopsis = List<String>.filled(
      10,
      '这是一段用于验证滑动行为的超长书籍简介，确保完整内容保留在详情页中。',
    ).join();
    final payload = <String, Object?>{
      ..._detailPayload,
      'book': <String, Object?>{
        ...(_detailPayload['book']! as Map<String, Object?>),
        'synopsis': longSynopsis,
      },
      'synopsis': longSynopsis,
    };
    final harness = await _Harness.create(
      MockClient((_) async => http.Response(
            jsonEncode(payload),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          )),
      child: const MediaQuery(
        data: MediaQueryData(size: Size(390, 844)),
        child: UiPlatformScope(
          platform: TargetPlatform.android,
          child: BookDetailPage(bookId: 'book-1'),
        ),
      ),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.widget<Text>(find.text(longSynopsis)).maxLines, 3);
    await tester.tap(find.text('展开简介'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(longSynopsis)).maxLines, isNull);
    expect(find.text('收起简介'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hides audiobook action for manga books', (tester) async {
    final payload = <String, Object?>{
      ..._detailPayload,
      'book': <String, Object?>{
        ...(_detailPayload['book']! as Map<String, Object?>),
        'bookKind': '漫画',
      },
    };
    final harness = await _Harness.create(
      MockClient((_) async => http.Response(
            jsonEncode(payload),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          )),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('听小说'), findsNothing);
  });

  testWidgets(
      'Windows manga sends every chapter to the dedicated translation workspace',
      (tester) async {
    final imports = <MangaBookshelfImportRequest>[];
    var legacyTranslationRequests = 0;
    final payload = _detailPayloadWithKind('漫画');
    final harness = await _Harness.create(
      MockClient((request) async {
        if (request.method == 'GET' &&
            request.url.path == '/api/v1/books/book-1') {
          return _jsonResponse(payload);
        }
        if (request.url.path.contains('/chapters/translate')) {
          legacyTranslationRequests += 1;
        }
        return _jsonResponse(<String, String>{'detail': 'unexpected'}, 500);
      }),
      importBookshelfBook: _capturingImporter(imports),
      child: _platformDetailLauncher(TargetPlatform.windows),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.tap(find.text('打开作品'));
    await tester.pumpAndSettle();

    expect(find.text('漫画翻译'), findsOneWidget);
    await tester.tap(find.text('漫画翻译'));
    await tester.pumpAndSettle();

    expect(imports, hasLength(1));
    expect(imports.single.bookId, 'book-1');
    expect(imports.single.chapterIndexes, <int>[1, 2]);
    expect(harness.appState.section, AppSection.translator);
    expect(find.text('打开作品'), findsOneWidget);
    expect(legacyTranslationRequests, 0);
  });

  testWidgets(
      'Windows manga sends only checked chapters to the dedicated workspace',
      (tester) async {
    final imports = <MangaBookshelfImportRequest>[];
    final harness = await _Harness.create(
      MockClient((request) async {
        if (request.method == 'GET' &&
            request.url.path == '/api/v1/books/book-1') {
          return _jsonResponse(_detailPayloadWithKind('漫画'));
        }
        return _jsonResponse(<String, String>{'detail': 'unexpected'}, 500);
      }),
      importBookshelfBook: _capturingImporter(imports),
      child: _platformDetailLauncher(TargetPlatform.windows),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.tap(find.text('打开作品'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();

    expect(find.text('翻译所选到工作台'), findsOneWidget);
    await tester.tap(find.text('翻译所选到工作台'));
    await tester.pumpAndSettle();

    expect(imports, hasLength(1));
    expect(imports.single.chapterIndexes, <int>[1]);
    expect(harness.appState.section, AppSection.translator);
    expect(find.text('打开作品'), findsOneWidget);
  });

  testWidgets('Windows novels keep the legacy translation task action',
      (tester) async {
    final imports = <MangaBookshelfImportRequest>[];
    final legacyChapters = <List<int>>[];
    final harness = await _Harness.create(
      _legacyTranslationClient(
        _detailPayloadWithKind('长小说'),
        legacyChapters,
      ),
      importBookshelfBook: _capturingImporter(imports),
      child: _platformDetailLauncher(TargetPlatform.windows),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.tap(find.text('打开作品'));
    await tester.pumpAndSettle();

    expect(find.text('翻译全部'), findsOneWidget);
    await tester.tap(find.text('翻译全部'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(legacyChapters, <List<int>>[
      <int>[1, 2],
    ]);
    expect(imports, isEmpty);
    expect(harness.appState.section, isNot(AppSection.translator));
    expect(find.text('测试作品'), findsWidgets);
  });

  testWidgets('non-Windows manga keeps the legacy translation task action',
      (tester) async {
    final imports = <MangaBookshelfImportRequest>[];
    final legacyChapters = <List<int>>[];
    final harness = await _Harness.create(
      _legacyTranslationClient(
        _detailPayloadWithKind('漫画'),
        legacyChapters,
      ),
      importBookshelfBook: _capturingImporter(imports),
      child: _platformDetailLauncher(TargetPlatform.android),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.tap(find.text('打开作品'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(FluentIcons.more));
    await tester.pumpAndSettle();
    expect(find.text('翻译全部章节'), findsOneWidget);
    expect(find.text('漫画翻译'), findsNothing);
    await tester.tap(find.text('翻译全部章节'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(legacyChapters, <List<int>>[
      <int>[1, 2],
    ]);
    expect(imports, isEmpty);
    expect(harness.appState.section, isNot(AppSection.translator));
    expect(find.text('测试作品'), findsWidgets);
  });

  testWidgets('opens import-compatible novel chapter export formats',
      (tester) async {
    final harness = await _Harness.create(
      MockClient((_) async => http.Response(
            jsonEncode(_detailPayload),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          )),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(
      find.byKey(const ValueKey<String>('chapter-export-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('导出本章'), findsOneWidget);
    expect(find.text('TXT'), findsOneWidget);
    expect(find.text('TEXT'), findsOneWidget);
    expect(find.text('DOCX'), findsOneWidget);
    expect(find.text('EPUB'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('TXT')).dx,
      closeTo(
        tester.getTopLeft(find.text('通用 UTF-8 纯文本，可重新导入青卷。')).dx,
        0.5,
      ),
    );
  });

  testWidgets('mobile export action opens the export format dialog',
      (tester) async {
    final harness = await _Harness.create(
      MockClient((_) async => http.Response(
            jsonEncode(_detailPayload),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          )),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byIcon(FluentIcons.more));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出全部章节'));
    await tester.pumpAndSettle();

    expect(find.text('导出全部章节'), findsOneWidget);
    expect(find.text('TXT'), findsOneWidget);
    expect(find.text('TEXT'), findsOneWidget);
    expect(find.text('DOCX'), findsOneWidget);
    expect(find.text('EPUB'), findsOneWidget);
  });

  testWidgets('opens ordered image ZIP and PDF formats for manga chapters',
      (tester) async {
    final payload = <String, Object?>{
      ..._detailPayload,
      'book': <String, Object?>{
        ...(_detailPayload['book']! as Map<String, Object?>),
        'bookKind': '漫画',
      },
    };
    final harness = await _Harness.create(
      MockClient((_) async => http.Response(
            jsonEncode(payload),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          )),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(
      find.byKey(const ValueKey<String>('chapter-export-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('导出本章'), findsOneWidget);
    expect(find.text('图片 ZIP'), findsOneWidget);
    expect(find.text('PDF'), findsOneWidget);
    expect(find.text('TXT'), findsNothing);
  });

  testWidgets('offers recovery and bookshelf deletion when detail fails',
      (tester) async {
    var deleteRequested = false;
    final harness = await _Harness.create(
      MockClient((request) async {
        if (request.method == 'DELETE') {
          deleteRequested = true;
          expect(request.url.path, '/api/v1/books/book-1');
          return http.Response(
            jsonEncode(<String, String>{
              'status': 'ok',
              'bookId': 'book-1',
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        expect(request.url.path, '/api/v1/books/book-1');
        return http.Response(
          jsonEncode(<String, String>{
            'detail': '本地书籍目录不存在：C:/QingJuan/data/library/测试',
          }),
          404,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
      child: const _DetailLauncher(),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.tap(find.text('打开作品'));
    await tester.pumpAndSettle();

    expect(find.text('暂时无法加载'), findsOneWidget);
    expect(find.byIcon(FluentIcons.back), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('从书架删除'), findsOneWidget);

    await tester.tap(find.text('从书架删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除这本书？'), findsOneWidget);
    expect(deleteRequested, isFalse);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(deleteRequested, isTrue);
    expect(find.text('打开作品'), findsOneWidget);
  });

  testWidgets('returns from missing directory error without deleting',
      (tester) async {
    final harness = await _Harness.create(
      MockClient((_) async => http.Response(
            jsonEncode(<String, String>{
              'detail': '本地书籍目录不存在：C:/QingJuan/data/library/测试',
            }),
            404,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          )),
      child: const _DetailLauncher(),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.tap(find.text('打开作品'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(FluentIcons.back));
    await tester.pumpAndSettle();

    expect(find.text('打开作品'), findsOneWidget);
    expect(find.text('暂时无法加载'), findsNothing);
  });

  testWidgets('keeps error page available when bookshelf deletion fails',
      (tester) async {
    final harness = await _Harness.create(
      MockClient((request) async {
        final detail = request.method == 'DELETE'
            ? '无法删除书架记录'
            : '本地书籍目录不存在：C:/QingJuan/data/library/测试';
        return http.Response(
          jsonEncode(<String, String>{'detail': detail}),
          request.method == 'DELETE' ? 500 : 404,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();
    await tester.tap(find.text('从书架删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('删除失败'), findsOneWidget);
    expect(find.text('暂时无法加载'), findsOneWidget);
    expect(find.text('从书架删除'), findsOneWidget);
  });

  testWidgets('builds only visible chapter rows for a large book',
      (tester) async {
    final chapters = List<Object?>.generate(
      1000,
      (index) => <String, Object?>{
        'index': index + 1,
        'title': '第${index + 1}章',
        'downloaded': true,
        'translated': false,
        'wordCount': 1200,
        'imageCount': 0,
      },
    );
    final payload = <String, Object?>{
      ..._detailPayload,
      'chapters': chapters,
    };
    final harness = await _Harness.create(
      MockClient((_) async => http.Response(
            jsonEncode(payload),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          )),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(Checkbox).evaluate().length, lessThan(50));
    expect(find.text('1000. 第1000章'), findsNothing);
  });

  testWidgets('Android detail header stays below the system status area',
      (tester) async {
    final harness = await _Harness.create(
      MockClient((_) async => http.Response(
            jsonEncode(_detailPayload),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          )),
      child: const MediaQuery(
        data: MediaQueryData(
          size: Size(390, 844),
          padding: EdgeInsets.only(top: 44, bottom: 24),
          viewPadding: EdgeInsets.only(top: 44, bottom: 24),
        ),
        child: UiPlatformScope(
          platform: TargetPlatform.android,
          child: BookDetailPage(bookId: 'book-1'),
        ),
      ),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.widget);
    await tester.pumpAndSettle();

    final header = find.byKey(const ValueKey('detail-mobile-header'));
    expect(header, findsOneWidget);
    expect(tester.getTopLeft(header).dy, greaterThanOrEqualTo(44));
    expect(tester.takeException(), isNull);
  });
}

const _detailPayload = <String, Object?>{
  'book': <String, Object?>{
    'id': 'book-1',
    'title': '测试作品',
    'sourceUrl': 'https://example.com/book-1',
    'bookKind': '长小说',
    'language': '中文',
    'status': '已导入',
    'chapterCount': 1,
    'translated': false,
    'synopsis': '用于验证页面生命周期。',
    'lastReadChapterIndex': 1,
  },
  'author': '测试作者',
  'synopsis': '用于验证页面生命周期。',
  'totalWords': 1200,
  'downloadedChapterCount': 1,
  'translatedChapterCount': 0,
  'progress': <String, Object?>{
    'lastChapterIndex': 1,
    'lastScrollRatio': 0.0,
  },
  'chapters': <Object?>[
    <String, Object?>{
      'index': 1,
      'title': '第一章',
      'downloaded': true,
      'translated': false,
      'wordCount': 1200,
      'imageCount': 0,
    },
  ],
};

Map<String, Object?> _detailPayloadWithKind(String kind) => <String, Object?>{
      ..._detailPayload,
      'book': <String, Object?>{
        ...(_detailPayload['book']! as Map<String, Object?>),
        'bookKind': kind,
        'chapterCount': 2,
      },
      'downloadedChapterCount': 2,
      'chapters': <Object?>[
        <String, Object?>{
          'index': 1,
          'title': '第一章',
          'downloaded': true,
          'translated': false,
          'wordCount': 1200,
          'imageCount': kind == '漫画' ? 2 : 0,
        },
        <String, Object?>{
          'index': 2,
          'title': '第二章',
          'downloaded': true,
          'translated': false,
          'wordCount': 900,
          'imageCount': kind == '漫画' ? 3 : 0,
        },
      ],
    };

http.Response _jsonResponse(Object? payload, [int statusCode = 200]) =>
    http.Response(
      jsonEncode(payload),
      statusCode,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );

MangaBookshelfImportInvoker _capturingImporter(
  List<MangaBookshelfImportRequest> imports,
) {
  return (
    request, {
    onProgress,
    abortTrigger,
  }) async {
    imports.add(request);
    return MangaBookshelfImportResult(
      bookId: request.bookId,
      bookTitle: request.bookTitle,
      sourceRoot: Directory.systemTemp.path,
      filePaths: const <String>[],
      chapterCount: request.chapterIndexes.length,
    );
  };
}

http.Client _legacyTranslationClient(
  Map<String, Object?> detail,
  List<List<int>> capturedChapters,
) {
  return MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/api/v1/books/book-1') {
      return _jsonResponse(detail);
    }
    if (request.method == 'POST' &&
        request.url.path == '/api/v1/books/book-1/chapters/translate') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      capturedChapters.add(
        (body['chapterIndexes'] as List<dynamic>)
            .whereType<num>()
            .map((value) => value.toInt())
            .toList(),
      );
      return _jsonResponse(<String, Object?>{
        'id': 'translate-1',
        'bookId': 'book-1',
        'taskType': 'translate',
        'status': 'queued',
        'totalCount': capturedChapters.last.length,
        'completedCount': 0,
        'progress': 0,
        'message': '任务已创建',
        'attempts': 0,
        'updatedAt': '2026-08-30T00:00:00Z',
      });
    }
    if (request.method == 'GET' && request.url.path == '/api/v1/tasks') {
      return _jsonResponse(<Object?>[]);
    }
    return _jsonResponse(<String, String>{'detail': 'unexpected'}, 500);
  });
}

Widget _platformDetailLauncher(TargetPlatform platform) => MediaQuery(
      data: MediaQueryData(
        size: platform == TargetPlatform.windows
            ? const Size(1280, 800)
            : const Size(390, 844),
      ),
      child: UiPlatformScope(
        platform: platform,
        child: const _DetailLauncher(),
      ),
    );

class _Harness {
  _Harness({
    required this.widget,
    required this.appState,
    required this.api,
    required this.library,
    required this.sources,
    required this.tasks,
    required this.settings,
    required this.mangaTranslation,
  });

  static Future<_Harness> create(
    http.Client client, {
    Widget child = const BookDetailPage(bookId: 'book-1'),
    MangaBookshelfImportInvoker? importBookshelfBook,
    Brightness brightness = Brightness.light,
  }) async {
    final appState = AppState(await SharedPreferences.getInstance());
    final api = ApiClient(() => appState.backendUrl, client: client);
    final backend = BackendConnectionManager(api, isConfigured: () => false);
    final library = LibraryController(api);
    final sources = SourcesController(api);
    final tasks = TasksController(api);
    final settings = SettingsController(api);
    final mangaTranslation = importBookshelfBook == null
        ? null
        : MangaTranslationCoordinator(
            api,
            importBookshelfBook: importBookshelfBook,
          );
    final widget = FluentApp(
      theme: captureMobileFixtures
          ? buildQingJuanTheme(brightness).copyWith(
              typography: buildQingJuanTheme(brightness)
                  .typography
                  .apply(fontFamily: 'Roboto'))
          : buildQingJuanTheme(brightness),
      builder: captureMobileFixtures
          ? (context, child) => DefaultTextStyle(
              style: const TextStyle(fontFamily: 'Roboto'), child: child!)
          : null,
      debugShowCheckedModeBanner: false,
      home: AppScope(
        appState: appState,
        api: api,
        backend: backend,
        auth: AuthController.localAdministrator(api),
        library: library,
        sources: sources,
        tasks: tasks,
        settings: settings,
        mangaTranslation: mangaTranslation,
        child: child,
      ),
    );
    return _Harness(
      widget: widget,
      appState: appState,
      api: api,
      library: library,
      sources: sources,
      tasks: tasks,
      settings: settings,
      mangaTranslation: mangaTranslation,
    );
  }

  final Widget widget;
  final AppState appState;
  final ApiClient api;
  final LibraryController library;
  final SourcesController sources;
  final TasksController tasks;
  final SettingsController settings;
  final MangaTranslationCoordinator? mangaTranslation;

  void dispose() {
    mangaTranslation?.dispose();
    library.dispose();
    sources.dispose();
    tasks.dispose();
    settings.dispose();
    api.close();
  }
}

class _DetailLauncher extends StatelessWidget {
  const _DetailLauncher();

  @override
  Widget build(BuildContext context) {
    return Navigator(
      onGenerateRoute: (_) => PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => const _DetailLauncherButton(),
      ),
    );
  }
}

class _DetailLauncherButton extends StatelessWidget {
  const _DetailLauncherButton();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Button(
        onPressed: () => Navigator.of(context).push<void>(
          PageRouteBuilder<void>(
            pageBuilder: (_, __, ___) => const BookDetailPage(bookId: 'book-1'),
          ),
        ),
        child: const Text('打开作品'),
      ),
    );
  }
}
