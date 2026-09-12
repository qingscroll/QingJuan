import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_startup.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/app/qingjuan_app.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/backend/user_session_store.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:qingjuan/shared/startup_splash.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('one splash covers bootstrap and mounted app initialization',
      (tester) async {
    final bootstrap = Completer<Widget>();
    late VoidCallback ready;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final semantics = tester.ensureSemantics();
    var presses = 0;
    await tester.pumpWidget(AppStartup(bootstrap: (onReady) {
      ready = onReady;
      return bootstrap.future;
    }));
    final logoState = tester.state(find.byType(QingJuanStartupLogo));
    await tester.pump(const Duration(milliseconds: 950));
    expect(find.byType(StartupSplash), findsOneWidget);

    bootstrap.complete(Focus(
      focusNode: focus,
      child: Semantics(
        label: 'private workspace',
        child: GestureDetector(
          key: const ValueKey('workspace'),
          onTap: () => presses += 1,
          child: const ColoredBox(color: Color(0xFF808080)),
        ),
      ),
    ));
    await tester.pump();
    expect(identical(tester.state(find.byType(QingJuanStartupLogo)), logoState),
        isTrue);
    expect(find.bySemanticsLabel('private workspace'), findsNothing);
    expect(focus.canRequestFocus, isFalse);
    await tester.tap(find.byKey(const ValueKey('workspace')),
        warnIfMissed: false);
    expect(presses, 0);

    ready();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(StartupSplash), findsNothing);
    expect(find.bySemanticsLabel('private workspace'), findsOneWidget);
    expect(focus.canRequestFocus, isTrue);
    await tester.tap(find.byKey(const ValueKey('workspace')));
    expect(presses, 1);
    ready();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(StartupSplash), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets('fast startup has a short minimum display before its fade',
      (tester) async {
    await tester.pumpWidget(AppStartup(bootstrap: (onReady) async {
      onReady();
      return const Text('ready');
    }));
    await tester.pump(const Duration(milliseconds: 899));
    expect(find.byType(StartupSplash), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.byType(StartupSplash), findsNothing);
    expect(find.text('ready'), findsOneWidget);
  });

  testWidgets('reduced motion skips the minimum display and exit fade',
      (tester) async {
    late VoidCallback ready;
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: AppStartup(bootstrap: (onReady) async {
        ready = onReady;
        return const Text('ready');
      }),
    ));
    await tester.pump();
    expect(find.byType(StartupSplash), findsOneWidget);
    ready();
    await tester.pump();
    expect(find.byType(StartupSplash), findsNothing);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('bootstrap failure has a working retry without error details',
      (tester) async {
    var attempts = 0;
    await tester.pumpWidget(AppStartup(bootstrap: (onReady) async {
      if (++attempts == 1) throw StateError('private-secret-token');
      onReady();
      return const Text('recovered');
    }));
    await tester.pump();
    expect(find.text('暂时无法启动应用'), findsOneWidget);
    expect(find.textContaining('private-secret-token'), findsNothing);
    final semantics = tester.ensureSemantics();
    await tester.pump();
    expect(
        tester
            .getSemantics(find.bySemanticsLabel('重试'))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue);
    semantics.dispose();
    await tester.tap(find.byKey(const ValueKey('startup-retry')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(attempts, 2);
    expect(find.byType(StartupSplash), findsNothing);
    expect(find.text('recovered'), findsOneWidget);
  });

  testWidgets('slow initialization can reveal the already mounted app',
      (tester) async {
    late VoidCallback ready;
    await tester.pumpWidget(AppStartup(bootstrap: (onReady) async {
      ready = onReady;
      return const Text('workspace');
    }));
    await tester.pump(const Duration(seconds: 8));
    expect(find.text('启动时间较长，仍在准备中'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('startup-continue')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.byType(StartupSplash), findsNothing);
    ready();
    await tester.pump();
    expect(find.byType(StartupSplash), findsNothing);
    expect(find.text('workspace'), findsOneWidget);
  });

  testWidgets('slow bootstrap offers no exit before an app exists',
      (tester) async {
    final bootstrap = Completer<Widget>();
    await tester.pumpWidget(AppStartup(bootstrap: (_) => bootstrap.future));
    await tester.pump(const Duration(seconds: 8));
    expect(find.text('启动时间较长，仍在准备中'), findsOneWidget);
    expect(find.byKey(const ValueKey('startup-continue')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    bootstrap.complete(const Text('late app'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('late initialization completion after disposal is harmless',
      (tester) async {
    late VoidCallback ready;
    await tester.pumpWidget(AppStartup(bootstrap: (onReady) async {
      ready = onReady;
      return const SizedBox.shrink();
    }));
    await tester.pumpWidget(const SizedBox.shrink());
    ready();
    await tester.pump(const Duration(seconds: 9));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows splash keeps drag and close controls available',
      (tester) async {
    final bootstrap = Completer<Widget>();
    final calls = <String>[];
    const channel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(AppStartup(bootstrap: (_) => bootstrap.future));
    await tester.tap(find.byKey(const ValueKey('startup-window-close')));
    await tester.pump();
    expect(calls, <String>['close']);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  for (final fail in <bool>[false, true]) {
    testWidgets(
        '${fail ? 'failed' : 'unconfigured'} backend releases the startup screen into settings',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final appState = AppState(await SharedPreferences.getInstance());
      final api = ApiClient(() => appState.backendUrl,
          client:
              MockClient((_) async => throw StateError('No request needed')));
      final backend = fail
          ? _FailingBackend(api)
          : BackendConnectionManager(api, isConfigured: () => false);
      var completions = 0;
      await tester.pumpWidget(AppStartup(bootstrap: (onReady) async {
        return QingJuanApp.testing(
          appState: appState,
          api: api,
          backend: backend,
          auth: AuthController(api, const _EmptySessionStore(),
              backendUrl: () => appState.backendUrl),
          library: LibraryController(api),
          sources: SourcesController(api),
          tasks: TasksController(api),
          settings: SettingsController(api),
          onInitialized: () {
            completions += 1;
            onReady();
          },
        );
      }));
      await tester.pumpAndSettle();
      expect(completions, 1);
      expect(find.byType(StartupSplash), findsNothing);
      expect(appState.section, AppSection.settings);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

class _FailingBackend extends BackendConnectionManager {
  _FailingBackend(super.api) : super(isConfigured: () => false);

  @override
  Future<void> ensureReady() async =>
      throw StateError('Backend startup failed');
}

class _EmptySessionStore implements UserSessionStore {
  const _EmptySessionStore();

  @override
  Future<void> deleteToken() async {}

  @override
  Future<String?> readToken(String backendUrl) async => null;

  @override
  Future<void> writeToken({
    required String backendUrl,
    required String token,
  }) async {}
}
