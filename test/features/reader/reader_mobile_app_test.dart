import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/reader/reader_page.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:qingjuan/mobile/mobile_app.dart';
import 'package:qingjuan/shared/feedback_widgets.dart';
import 'package:qingjuan/shared/motion.dart';
import 'package:qingjuan/shared/responsive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mobile_fixture_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadMobileCaptureFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final theme in <AppThemeMode>[AppThemeMode.light, AppThemeMode.dark]) {
    for (final flow in ReaderFlowMode.values) {
      testWidgets(
        'real mobile route has normal loading and ${flow.name} text in ${theme.name}',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final response = Completer<http.Response>();
          final appState = AppState(await SharedPreferences.getInstance());
          await appState.setThemeMode(theme);
          await appState.setReaderFlowMode(flow);
          await appState.setReaderPaletteMode(theme == AppThemeMode.dark
              ? ReaderPaletteMode.night
              : ReaderPaletteMode.white);
          // A typography repair must keep the reader's saved preference.
          await appState.setReaderFontSize(23);
          final api = ApiClient(
            () => appState.backendUrl,
            client: MockClient((request) async {
              if (request.method == 'GET') return response.future;
              return http.Response('{}', 200);
            }),
          );
          final backend =
              BackendConnectionManager(api, isConfigured: () => false);
          final auth = AuthController.localAdministrator(api);
          final library = LibraryController(api);
          final sources = SourcesController(api);
          final tasks = TasksController(api);
          final settings = SettingsController(api);
          addTearDown(() async {
            library.dispose();
            sources.dispose();
            tasks.dispose();
            settings.dispose();
            auth.dispose();
            await backend.dispose();
            api.close();
            appState.dispose();
          });
          final navigatorKey = GlobalKey<NavigatorState>();
          final previewKey = GlobalKey();

          // Exercise the production root. Extra FluentApp, Material, or
          // DefaultTextStyle wrappers here would conceal route inheritance bugs.
          await tester.pumpWidget(
            RepaintBoundary(
              key: previewKey,
              child: UiPlatformScope(
                platform: TargetPlatform.android,
                child: AppScope(
                  appState: appState,
                  api: api,
                  backend: backend,
                  auth: auth,
                  library: library,
                  sources: sources,
                  tasks: tasks,
                  settings: settings,
                  child: MobileQingJuanApp(navigatorKey: navigatorKey),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          unawaited(navigatorKey.currentState!.push<void>(
            qjPageRoute<void>(
              context: navigatorKey.currentContext!,
              builder: (_) => const ReaderPage(
                detail: _detail,
                initialChapterIndex: 1,
              ),
            ),
          ));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));

          expect(find.byType(LoadingView), findsOneWidget);
          expect(
            find.byWidgetPredicate((widget) =>
                widget is Semantics &&
                widget.properties.label == '正在打开章节' &&
                widget.properties.liveRegion == true),
            findsOneWidget,
          );
          expect(find.text('正在打开章节'), findsNothing);
          final routeStyle =
              DefaultTextStyle.of(tester.element(find.byType(LoadingView)))
                  .style;
          expect(routeStyle.fontSize, lessThanOrEqualTo(18));
          expect(routeStyle.fontWeight, FontWeight.w400);
          expect(routeStyle.decoration, TextDecoration.none);
          expect(routeStyle.color, isNot(const Color(0xffff0000)));
          await saveMobileFixture(
            tester,
            previewKey,
            'reader-route-${flow.name}-loading-${theme.name}',
            settle: false,
          );

          response.complete(http.Response(
            jsonEncode(_chapter),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          ));
          await tester.pumpAndSettle();
          expect(find.byType(LoadingView), findsNothing);
          expect(tester.takeException(), isNull);

          final TextStyle bodyStyle;
          if (flow == ReaderFlowMode.paged) {
            final body = find.byWidgetPredicate(
              (widget) =>
                  widget is RichText &&
                  widget.text.toPlainText().contains(_body),
            );
            expect(body, findsOneWidget);
            bodyStyle = tester.renderObject<RenderParagraph>(body).text.style!;
          } else {
            final body = find.byWidgetPredicate(
              (widget) =>
                  widget is SelectableText &&
                  (widget.textSpan?.toPlainText().contains(_body) ?? false),
            );
            expect(body, findsOneWidget);
            bodyStyle = tester.widget<SelectableText>(body).style!;
          }
          expect(bodyStyle.fontSize, 23);
          expect(bodyStyle.height, 1.65);
          expect(bodyStyle.fontWeight, FontWeight.normal);
          expect(bodyStyle.fontStyle, FontStyle.normal);
          expect(bodyStyle.decoration, TextDecoration.none);
          expect(bodyStyle.color, isNot(const Color(0xffff0000)));
          expect(appState.readerFontSize, 23);
          await tester.tapAt(const Offset(195, 422));
          await tester.pumpAndSettle();
          await saveMobileFixture(
            tester,
            previewKey,
            'reader-route-${flow.name}-${theme.name}',
          );

          navigatorKey.currentState!.pop();
          await tester.pumpAndSettle();
          expect(find.byType(ReaderPage), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
      );
    }
  }
}

const _body = '清晨的风从窗外吹进来，书页轻轻翻动。'
    '她停在读到一半的段落，听着远处传来的钟声，才发现天已经亮了。';
const _secondParagraph = '桌上的茶还留着一点温度。她把窗帘拉开，'
    '光线落在纸面上，字句变得清晰起来。今天的故事，就从这安静的一刻继续。';
const _thirdParagraph = '阅读不必匆忙。遇见喜欢的句子，可以多停留片刻；'
    '再次打开时，仍能回到刚才的位置。';
const _detail = BookDetail(
  book: Book(
    id: 'reader-mobile-route',
    title: '移动阅读测试',
    sourceUrl: 'https://example.com/book',
    kind: '长小说',
    language: '中文',
    status: '已导入',
    chapterCount: 1,
    translated: false,
    synopsis: '',
    lastReadChapterIndex: 1,
  ),
  author: '测试作者',
  synopsis: '',
  totalWords: 14,
  downloadedCount: 1,
  translatedCount: 0,
  progress: ReadingProgress(chapterIndex: 1, scrollRatio: 0),
  chapters: <Chapter>[
    Chapter(
      index: 1,
      title: '第一章',
      downloaded: true,
      translated: false,
      wordCount: 14,
      imageCount: 0,
    ),
  ],
);

const _chapter = <String, Object?>{
  'chapter': <String, Object?>{
    'index': 1,
    'title': '第一章',
    'downloaded': true,
    'translated': false,
    'wordCount': 14,
    'imageCount': 0,
  },
  'content': '$_body\n$_secondParagraph\n$_thirdParagraph',
  'paragraphs': <String>[_body, _secondParagraph, _thirdParagraph],
  'mode': 'translated',
  'translatedAvailable': false,
  'imageSources': <String>[],
  'pageTranslations': <String>[],
};
