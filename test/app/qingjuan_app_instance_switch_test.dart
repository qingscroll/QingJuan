import 'dart:async';
import 'dart:convert';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/app/qingjuan_app.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/backend/user_session_store.dart';
import 'package:qingjuan/core/models/audiobook_position.dart';
import 'package:qingjuan/core/models/settings.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/audiobook/audiobook_coordinator.dart';
import 'package:qingjuan/features/audiobook/audiobook_position_store.dart';
import 'package:qingjuan/features/detail/book_detail_page.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/features/translation_quality/translation_quality_page.dart';
import '../features/audiobook/audiobook_background_fixtures.dart';

void main() {
  testWidgets(
      'same URL and account but new instance clears old routes books and audiobook',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'qingjuan.backend.remote.url': 'https://backend.test'});
    final app = AppState(await SharedPreferences.getInstance(),
        initialRemoteBackendToken: 'connection-token');
    var instance = 'instance-one';
    var heartbeatFails = false;
    var bookRequests = 0;
    late AuthController auth;
    final api = ApiClient(() => app.backendUrl,
        token: () => app.backendToken,
        userToken: () => auth.userToken,
        connectionRevision: () => app.backendConnectionRevision,
        client: MockClient((request) async {
          switch (request.url.path) {
            case '/api/v1/meta':
              if (heartbeatFails) throw http.ClientException('Offline');
              return _json({
                'service': 'qingjuan-backend',
                'apiVersion': '1',
                'instanceId': instance,
                'capabilities': {'multiUser': true}
              });
            case '/api/v1/auth/session':
              return _json({
                'id': 'same-owner',
                'username': 'reader',
                'role': 'user',
                'status': 'active'
              });
            case '/api/v1/books':
              bookRequests++;
              return _json([
                {
                  'id': 'book-$instance',
                  'title': 'Book $instance',
                  'sourceUrl': '',
                  'kind': '长小说',
                  'language': '中文',
                  'status': 'ready',
                  'chapterCount': 1,
                  'translated': false,
                  'localPath': '',
                  'synopsis': ''
                }
              ]);
            case '/api/v1/sources':
            case '/api/v1/tasks':
            case '/api/v1/plugins':
              return _json([]);
            case '/api/v1/settings':
              return _json(TranslationSettings.defaults().toJson());
            case '/api/v1/devices/heartbeat':
              return http.Response('', 204);
            default:
              return _json({'detail': 'Unexpected ${request.url.path}'}, 404);
          }
        }));
    auth =
        AuthController(api, _StoredSession(), backendUrl: () => app.backendUrl);
    final backend = BackendConnectionManager(api, isConfigured: () => true);
    final library = LibraryController(api);
    final engine = BackgroundEngine();
    final audiobook = AudiobookCoordinator(
        engineFactory: (_) => engine,
        initializePlatform: (_) async => BackgroundRuntime(),
        positionStore: (instance, owner, book) => _Positions());
    await tester.pumpWidget(QingJuanApp.testing(
        appState: app,
        api: api,
        backend: backend,
        auth: auth,
        library: library,
        sources: SourcesController(api),
        tasks: TasksController(api),
        settings: SettingsController(api),
        audiobook: audiobook));
    await tester.pumpAndSettle();
    expect(auth.isAuthenticated, isTrue);
    expect(library.books.single.id, 'book-instance-one');
    final workspace = auth.workspaceIdentity;
    final guard = api.captureContextGuard();
    await audiobook.open(
        instanceId: instance,
        ownerId: 'same-owner',
        detail: backgroundDetail,
        loadChapter: (index, mode) async => backgroundContent(index, mode),
        isCurrentContext: guard);
    final previous = audiobook.current!;
    unawaited(audiobook.play());
    await tester.pumpAndSettle();
    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(navigator.push<void>(FluentPageRoute<void>(
        builder: (_) => const Center(child: Text('Old instance route')))));
    await tester.pumpAndSettle();
    expect(find.text('Old instance route'), findsOneWidget);
    final generationBeforeOutage = library.contextGeneration;
    heartbeatFails = true;
    await backend.probeRemoteHealth();
    await tester.pump(const Duration(milliseconds: 300));
    expect(backend.status, BackendStatus.failed);
    expect(library.contextGeneration, generationBeforeOutage);
    expect(library.books.single.id, 'book-instance-one');
    expect(find.text('Old instance route'), findsOneWidget);
    expect(audiobook.current, same(previous));
    expect(previous.isClosed, isFalse);
    final requestsBefore = bookRequests;
    heartbeatFails = false;
    instance = 'instance-two';
    await backend.probeRemoteHealth();
    await tester.pumpAndSettle();
    expect(auth.workspaceIdentity, workspace);
    expect(find.text('Old instance route'), findsNothing);
    expect(bookRequests, greaterThan(requestsBefore));
    expect(library.books.single.id, 'book-instance-two');
    expect(audiobook.current, isNull);
    expect(previous.isClosed, isTrue);
    expect(previous.chunks, isEmpty);
    expect(engine.disposals, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
      'new instance revokes old glossary before session and model checks finish',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(
        {'qingjuan.backend.remote.url': 'https://backend.test'});
    final app = AppState(await SharedPreferences.getInstance(),
        initialRemoteBackendToken: 'connection-token');
    var instance = 'instance-one';
    var glossarySaves = 0;
    var modelChecks = 0;
    final restoredSession = Completer<http.Response>();
    final checkedModel = Completer<http.Response>();
    final book = {
      'id': 'same-book',
      'title': '尚未下载的小说',
      'kind': '长小说',
      'language': '英语',
      'sourceUrl': '',
      'chapterCount': 0,
    };
    final session = {
      'id': 'same-owner',
      'username': 'reader',
      'role': 'user',
      'status': 'active'
    };
    late AuthController auth;
    final api = ApiClient(() => app.backendUrl,
        token: () => app.backendToken,
        userToken: () => auth.userToken,
        connectionRevision: () => app.backendConnectionRevision,
        client: MockClient((request) async {
          switch (request.url.path) {
            case '/api/v1/meta':
              return _json({
                'service': 'qingjuan-backend',
                'apiVersion': '1',
                'instanceId': instance,
                'capabilities': {
                  'multiUser': true,
                  'translationQuality': true,
                  'translationModelCheck': instance == 'instance-two'
                }
              });
            case '/api/v1/auth/session':
              return instance == 'instance-one'
                  ? _json(session)
                  : restoredSession.future;
            case '/api/v1/translation-model/check':
              modelChecks++;
              return checkedModel.future;
            case '/api/v1/books':
              return _json([book]);
            case '/api/v1/books/same-book':
              return _json(
                  {'book': book, 'chapters': [], 'downloadedChapterCount': 0});
            case '/api/v1/books/same-book/glossary':
              if (request.method == 'PUT') glossarySaves++;
              // A restored instance can legitimately reuse both book id and
              // revision, so the server would accept an incorrectly sent edit.
              return _json(
                  {'bookId': 'same-book', 'revision': 0, 'entries': []});
            case '/api/v1/sources':
            case '/api/v1/tasks':
            case '/api/v1/plugins':
              return _json([]);
            case '/api/v1/settings':
              return _json(TranslationSettings.defaults().toJson());
            case '/api/v1/devices/heartbeat':
              return http.Response('', 204);
            default:
              return _json({'detail': 'Unexpected ${request.url.path}'}, 404);
          }
        }));
    auth =
        AuthController(api, _StoredSession(), backendUrl: () => app.backendUrl);
    final backend = BackendConnectionManager(api, isConfigured: () => true);
    final library = LibraryController(api);
    await tester.pumpWidget(QingJuanApp.testing(
        appState: app,
        api: api,
        backend: backend,
        auth: auth,
        library: library,
        sources: SourcesController(api),
        tasks: TasksController(api),
        settings: SettingsController(api)));
    await tester.pumpAndSettle();
    final navigator =
        tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(navigator.push<void>(FluentPageRoute<void>(
        builder: (_) => const BookDetailPage(bookId: 'same-book'))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('作品管理'));
    await tester.tap(find.text('作品管理'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('术语与人名'));
    await tester.tap(find.text('术语与人名'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quality-add-term')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('quality-term-source')), 'Alice');
    await tester.enterText(
        find.byKey(const ValueKey('quality-term-target')), '艾丽丝');
    final saveOldDraft = tester
        .widget<FilledButton>(find.ancestor(
            of: find.text('保存术语'), matching: find.byType(FilledButton)))
        .onPressed!;
    final oldGeneration = library.contextGeneration;
    instance = 'instance-two';
    await backend.probeRemoteHealth();

    // A callback retained by a frame must already be harmless before the next
    // frame removes the old page, even while authentication is still pending.
    expect(restoredSession.isCompleted, isFalse);
    expect(library.contextGeneration, greaterThan(oldGeneration));
    expect(library.books, isEmpty);
    saveOldDraft();
    expect(glossarySaves, 0);
    restoredSession.complete(_json(session));
    await tester.pump();
    expect(modelChecks, 1);
    expect(checkedModel.isCompleted, isFalse);
    saveOldDraft();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(glossarySaves, 0);
    expect(find.byType(TranslationQualityPage), findsNothing);
    expect(find.byType(BookDetailPage), findsNothing);
    checkedModel.complete(_json({'status': 'ready', 'message': '模型可用'}));
    await tester.pumpAndSettle();
    expect(library.books.single.id, 'same-book');
    expect(glossarySaves, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

http.Response _json(Object value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status,
        headers: {'content-type': 'application/json'});

class _StoredSession implements UserSessionStore {
  @override
  Future<String?> readToken(String backendUrl) async => 'same-session';
  @override
  Future<void> deleteToken() async {}
  @override
  Future<void> writeToken(
      {required String backendUrl, required String token}) async {}
}

class _Positions implements AudiobookPositionStore {
  @override
  Future<AudiobookPosition?> load() async => null;
  @override
  Future<void> save(AudiobookPosition position) async {}
}
