import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/models/settings.dart';
import 'package:qingjuan/features/settings/widgets/translation_model_card.dart';

import '../../helpers/reliability_harness.dart';
import '../../helpers/ui_review_capture.dart';

void main() {
  setUpAll(loadUiReviewFonts);

  testWidgets('disabled local model can be configured and explicitly enabled',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final saved = <Map<String, dynamic>>[];
    var forcedChecks = 0;
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      expect(request.headers['X-QingJuan-Local-Request'], '1');
      if (request.method == 'PUT' && request.url.path == '/api/v1/settings') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        saved.add(body);
        final model = body['translationModel'] as Map<String, dynamic>;
        return http.Response(
            jsonEncode({
              ...body,
              'translationModel': {
                ...model,
                'apiKey': '',
                'apiKeyConfigured': true,
              },
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (request.url.path == '/api/v1/translation-model/check') {
        expect(request.url.queryParameters['force'], 'true');
        forcedChecks++;
        final enabled = saved.last['translationModel']['enabled'] == true;
        return http.Response(
            jsonEncode({
              'enabled': enabled,
              'configured': true,
              'available': enabled,
              'status': enabled ? 'ready' : 'disabled',
              'model': 'configured-model',
              'message': enabled ? '模型可用' : 'Linux 服务端翻译模型未启用',
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      throw StateError('Unexpected request: ${request.url}');
    }), localBackendSupported: true);
    addTearDown(harness.dispose);
    final backend = harness.scope.backend..status = BackendStatus.ready;
    backend.translationModelCheck = TranslationModelCheck.fromJson({
      'status': 'disabled',
      'message': 'Linux 服务端翻译模型未启用',
    });
    final settings = harness.scope.settings;
    final captureKey = GlobalKey();
    await tester.pumpWidget(harness.widget(Builder(builder: (context) {
      return RepaintBoundary(
        key: captureKey,
        child: ColoredBox(
          color: FluentTheme.of(context).scaffoldBackgroundColor,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: AnimatedBuilder(
              animation: Listenable.merge([settings, backend]),
              builder: (context, _) => TranslationModelCard(
                backend: backend,
                settings: settings,
                localConfiguration: true,
                checking: backend.translationModelCheckInProgress,
                onCheck: (force) async {
                  await backend.checkTranslationModel(force: force);
                },
              ),
            ),
          ),
        ),
      );
    })));
    await tester.pumpAndSettle();
    expect(find.textContaining('Linux'), findsNothing);
    final toggle = find.byKey(const ValueKey('translation-model-enabled'));
    expect(tester.widget<ToggleSwitch>(toggle).checked, isFalse);
    final fields = {
      'translation-model-base-url': 'https://models.example.test/v1',
      'translation-model-name': 'configured-model',
      'translation-model-api-key': 'local-test-secret',
    };
    for (final field in fields.entries) {
      final input = find.byKey(ValueKey(field.key));
      expect(tester.widget<TextBox>(input).enabled, isTrue);
      await tester.enterText(input, field.value);
    }
    await captureUi(tester, captureKey, 'local-model-configurable-disabled');
    final save = find.byKey(const ValueKey('save-local-model-settings'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved.single['translationModel']['enabled'], isFalse);
    expect(saved.single['translationModel']['apiKey'], 'local-test-secret');
    expect(forcedChecks, 1);
    await tester.pump(const Duration(seconds: 5));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('翻译模型待保存'), findsOneWidget);
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saved.last['translationModel']['enabled'], isTrue);
    expect(saved.last['translationModel']['apiKeyAction'], 'keep');
    expect(saved.last['translationModel']['model'], 'configured-model');
    expect(forcedChecks, 2);
    expect(find.text('本机翻译模型可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('remote model status never exposes the local editor',
      (tester) async {
    final harness = await ReliabilityHarness.create(
        MockClient((_) async => throw StateError('No request expected')));
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.widget(TranslationModelCard(
      backend: harness.scope.backend,
      settings: harness.scope.settings,
      localConfiguration: false,
      checking: false,
      onCheck: (_) async {},
    )));
    await tester.pumpAndSettle();
    expect(find.byType(TextBox), findsNothing);
    expect(find.text('由 Linux 后端管理界面统一配置'), findsOneWidget);
  });
}
