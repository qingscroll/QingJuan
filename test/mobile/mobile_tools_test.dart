import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/models/source.dart';
import 'package:qingjuan/core/models/task.dart';
import 'package:qingjuan/core/models/user_account.dart';
import 'package:qingjuan/core/state/load_state.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:qingjuan/mobile/mobile_app.dart';
import 'package:qingjuan/shared/responsive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{
        'qingjuan.backend.remote.url': 'https://test.example',
        'qingjuan.backendMode': 'remote',
      }));

  testWidgets(
      'task progress converts server percentages to a fractional indicator',
      (tester) async {
    final fixture = await _Fixture.create((_) async => _json(<Object>[]));
    addTearDown(fixture.dispose);
    fixture.tasks.tasks = <BookTask>[
      BookTask.fromJson(<String, Object>{..._task('running'), 'progress': 37.5})
    ];
    await _mount(tester, fixture, AppSection.tasks);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        0.375);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('task retry submits once and refreshes its final status',
      (tester) async {
    final response = Completer<http.Response>();
    var retries = 0;
    final fixture = await _Fixture.create((request) async {
      if (request.method == 'POST') {
        expect(request.url.path, '/api/v1/tasks/task-1/retry');
        retries++;
        return response.future;
      }
      return _json(<Object>[_task('completed')]);
    });
    addTearDown(fixture.dispose);
    await _mount(tester, fixture, AppSection.tasks);
    await tester.tap(find.text('重试任务'));
    await tester.pump();
    expect(find.text('正在重试'), findsOneWidget);
    final retry = tester.widget<FilledButton>(
      find.ancestor(of: find.text('正在重试'), matching: find.byType(FilledButton)),
    );
    expect(retry.onPressed, isNull);
    expect(retries, 1);

    response.complete(_json(_task('completed')));
    await tester.pumpAndSettle();
    expect(fixture.tasks.tasks.single.status, 'completed');
    expect(find.text('重试任务'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('source switch saves the new value to the real controller',
      (tester) async {
    final requests = <http.Request>[];
    final fixture = await _Fixture.create((request) async {
      requests.add(request);
      expect(request.method, 'PUT');
      expect(request.url.path, '/api/v1/sources/source-1/enabled');
      expect(jsonDecode(request.body), <String, Object>{'enabled': false});
      return _json(_source(false));
    });
    addTearDown(fixture.dispose);
    await _mount(tester, fixture, AppSection.sources);
    await tester.tap(find.text('测试书源'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(fixture.sources.sources.single.enabled, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('closing an in-flight source import safely leaves the sheet',
      (tester) async {
    final importResponse = Completer<http.Response>();
    var imports = 0;
    final fixture = await _Fixture.create((request) async {
      if (request.method == 'POST') {
        imports++;
        expect(request.url.path, '/api/v1/sources/import-text');
        expect(jsonDecode(request.body), <String, Object>{'content': '[{}]'});
        return importResponse.future;
      }
      return _json(request.url.path.endsWith('/sources')
          ? <Object>[_source(true)]
          : <Object>[]);
    });
    addTearDown(fixture.dispose);
    await _mount(tester, fixture, AppSection.sources);
    await tester.tap(find.text('粘贴配置'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '[{}]');
    await tester.tap(find.text('导入'));
    await tester.pump();
    expect(imports, 1);
    expect(find.text('正在导入'), findsOneWidget);

    Navigator.of(tester.element(find.text('粘贴书源配置'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('粘贴书源配置'), findsNothing);
    importResponse.complete(_json(<String, Object>{'imported': <Object>[]}));
    await tester.pumpAndSettle();
    expect(imports, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ordinary users can inspect sources but cannot mutate them',
      (tester) async {
    final requests = <http.Request>[];
    final fixture = await _Fixture.create((request) async {
      requests.add(request);
      return _json(<String, Object>{});
    });
    addTearDown(fixture.dispose);
    fixture.auth
      ..status = UserAuthStatus.authenticated
      ..user = const UserAccount(
        id: 'reader',
        username: 'reader',
        displayName: '读者',
        role: 'user',
        status: 'active',
        createdAt: '',
      );
    await _mount(tester, fixture, AppSection.sources);
    expect(find.text('测试书源'), findsOneWidget);
    expect(find.text('粘贴配置'), findsNothing);
    expect(find.text('导入网址'), findsNothing);
    final preference = tester.widget<MiuixSwitchPreference>(
      find.byType(MiuixSwitchPreference),
    );
    expect(preference.enabled, isFalse);
    await tester.tap(find.text('测试书源'));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _mount(
    WidgetTester tester, _Fixture fixture, AppSection section) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  fixture.app.selectSection(section);
  await tester.pumpWidget(UiPlatformScope(
    platform: TargetPlatform.android,
    child: AppScope(
      appState: fixture.app,
      api: fixture.api,
      backend: fixture.backend,
      auth: fixture.auth,
      library: fixture.library,
      sources: fixture.sources,
      tasks: fixture.tasks,
      settings: fixture.settings,
      child: const MobileQingJuanApp(),
    ),
  ));
  await tester.pumpAndSettle();
}

http.Response _json(Object body) =>
    http.Response(jsonEncode(body), 200, headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8'
    });

Map<String, Object> _source(bool enabled) => <String, Object>{
      'id': 'source-1',
      'name': '测试书源',
      'baseUrl': 'https://source.example',
      'description': '测试书源说明',
      'enabled': enabled,
      'supported': true,
      'status': 'ready',
      'statusMessage': '',
      'tags': <String>[],
    };

Map<String, Object> _task(String status) => <String, Object>{
      'id': 'task-1',
      'bookId': 'book-1',
      'taskType': 'download',
      'status': status,
      'totalCount': 2,
      'completedCount': status == 'completed' ? 2 : 0,
      'progress': status == 'completed' ? 100.0 : 0.0,
      'message': '',
    };

class _Fixture {
  _Fixture(this.app, this.api) {
    backend = BackendConnectionManager(api, isConfigured: () => true);
    auth = AuthController.localAdministrator(api);
    library = LibraryController(api)..state = LoadState.ready;
    sources = SourcesController(api)
      ..state = LoadState.ready
      ..sources = <BookSource>[BookSource.fromJson(_source(true))];
    tasks = TasksController(api)
      ..state = LoadState.ready
      ..tasks = <BookTask>[BookTask.fromJson(_task('failed'))];
    settings = SettingsController(api);
  }

  static Future<_Fixture> create(
          Future<http.Response> Function(http.Request) handler) async =>
      _Fixture(
          AppState(await SharedPreferences.getInstance(),
              initialRemoteBackendToken: 'test-token'),
          ApiClient(() => 'https://test.example', client: MockClient(handler)));

  final AppState app;
  final ApiClient api;
  late final BackendConnectionManager backend;
  late final AuthController auth;
  late final LibraryController library;
  late final SourcesController sources;
  late final TasksController tasks;
  late final SettingsController settings;

  void dispose() {
    tasks.dispose();
    sources.dispose();
    library.dispose();
    settings.dispose();
    auth.dispose();
    backend.dispose();
    app.dispose();
    api.close();
  }
}
