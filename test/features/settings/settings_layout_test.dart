import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/features/settings/widgets/desktop_settings_workspace.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/models/tts_speech_style.dart';
import 'package:qingjuan/core/models/tts_voice.dart';
import 'package:qingjuan/features/audiobook/tts_voice_service.dart';
import 'package:qingjuan/features/settings/settings_page.dart';
import 'package:qingjuan/shared/responsive.dart';

import '../../helpers/reliability_harness.dart';
import '../../helpers/ui_review_capture.dart';
import '../../helpers/settings_navigation.dart';

class ReviewVoices implements TtsVoiceService {
  @override
  Future<List<TtsVoice>> loadVoices() async => const [
        TtsVoice(
            name: 'Microsoft Xiaoxiao',
            locale: 'zh-CN',
            gender: 'female',
            identifier: 'xiaoxiao'),
      ];
  @override
  Future<void> preview(TtsVoice voice,
      {TtsSpeechStyle style = TtsSpeechStyle.natural}) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  setUpAll(loadUiReviewFonts);
  for (final scenario in [
    (
      name: 'local',
      local: true,
      width: 1440.0,
      scale: 1.0,
      brightness: Brightness.light
    ),
    (
      name: 'remote',
      local: false,
      width: 1440.0,
      scale: 1.0,
      brightness: Brightness.light
    ),
    (
      name: 'narrow-200',
      local: true,
      width: 640.0,
      scale: 2.0,
      brightness: Brightness.light
    ),
    (
      name: 'dark',
      local: true,
      width: 1440.0,
      scale: 1.0,
      brightness: Brightness.dark
    ),
  ]) {
    testWidgets('settings categories remain usable ${scenario.name}',
        (tester) async {
      tester.view.physicalSize = Size(scenario.width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final harness = await ReliabilityHarness.create(
          MockClient((_) async => http.Response('[]', 200)),
          localBackendSupported: scenario.local);
      addTearDown(harness.dispose);
      harness.scope.backend
        ..status = BackendStatus.ready
        ..message = scenario.local ? '本机后端运行正常' : '服务器已连接'
        ..capabilities = {'backups': true};
      final key = GlobalKey();
      await tester.pumpWidget(harness.widget(
          Builder(
              builder: (context) => RepaintBoundary(
                  key: key,
                  child: ColoredBox(
                      color: FluentTheme.of(context).scaffoldBackgroundColor,
                      child: UiPlatformScope(
                          platform: TargetPlatform.windows,
                          child: SettingsPage(voiceService: ReviewVoices()))))),
          textScale: scenario.scale,
          brightness: scenario.brightness));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final category in SettingsCategory.values) {
        await selectSettingsCategory(tester, category);
        expect(tester.takeException(), isNull);
        await captureUi(
            tester, key, 'settings-${scenario.name}-${category.name}');
        if (category == SettingsCategory.application) {
          final about =
              find.byKey(const ValueKey('settings-about-card-button'));
          await tester.ensureVisible(about);
          await tester.pumpAndSettle();
          expect(about.hitTestable(), findsOneWidget);
          expect(find.byKey(const ValueKey('settings-backups-button')),
              scenario.local ? findsOneWidget : findsNothing);
        }
      }
      await selectSettingsCategory(tester, SettingsCategory.translation);
      if (scenario.local) {
        final enabled = find.byKey(const ValueKey('translation-model-enabled'));
        await tester.ensureVisible(enabled);
        await tester.tap(enabled);
        await tester.pumpAndSettle();
        final model = find.byKey(const ValueKey('translation-model-name'));
        await tester.ensureVisible(model);
        await tester.enterText(model, 'unsaved-model');
        expect(tester.widget<TextBox>(model).controller!.text, 'unsaved-model');
        await selectSettingsCategory(tester, SettingsCategory.account);
        await selectSettingsCategory(tester, SettingsCategory.translation);
        expect(tester.widget<TextBox>(model).controller!.text, 'unsaved-model');
        if (scenario.width > 1000) {
          tester.view.physicalSize = const Size(640, 1000);
          await tester.pumpAndSettle();
          expect(
              tester.widget<TextBox>(model).controller!.text, 'unsaved-model');
          tester.view.physicalSize = Size(scenario.width, 1000);
          await tester.pumpAndSettle();
          expect(
              tester.widget<TextBox>(model).controller!.text, 'unsaved-model');
        }
        final save = find.byKey(const ValueKey('save-local-model-settings'));
        await tester.ensureVisible(save);
        await tester.pumpAndSettle();
        expect(save.hitTestable(), findsOneWidget);
      }
      await selectSettingsCategory(tester, SettingsCategory.connection);
      if (scenario.local) {
        await tester.tap(find.byType(ComboBox<BackendConnectionMode>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Linux 远程后端').last);
        await tester.pumpAndSettle();
      }
      final address = find.byKey(const ValueKey('linux-backend-url'));
      await tester.ensureVisible(address);
      await tester.enterText(address, 'https://draft.example.test');
      await selectSettingsCategory(tester, SettingsCategory.appearance);
      await selectSettingsCategory(tester, SettingsCategory.connection);
      expect(tester.widget<TextBox>(address).controller!.text,
          'https://draft.example.test');
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }
}
