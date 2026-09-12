import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/app/app_scope.dart';
import 'package:qingjuan/app/app_state.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/backend/backend_connection_manager.dart';
import 'package:qingjuan/core/models/settings.dart';
import 'package:qingjuan/core/models/tts_speech_style.dart';
import 'package:qingjuan/core/models/tts_voice.dart';
import 'package:qingjuan/features/audiobook/tts_voice_service.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';
import 'package:qingjuan/features/backups/backups_dialog.dart';
import 'package:qingjuan/features/library/library_controller.dart';
import 'package:qingjuan/features/settings/settings_controller.dart';
import 'package:qingjuan/features/settings/settings_page.dart';
import 'package:qingjuan/features/settings/widgets/desktop_settings_workspace.dart';
import '../../helpers/settings_navigation.dart';
import 'package:qingjuan/features/sources/sources_controller.dart';
import 'package:qingjuan/features/tasks/tasks_controller.dart';
import 'package:qingjuan/shared/responsive.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Voices implements TtsVoiceService {
  @override
  Future<List<TtsVoice>> loadVoices() async => [];
  @override
  Future<void> dispose() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> preview(TtsVoice voice,
      {TtsSpeechStyle style = TtsSpeechStyle.natural}) async {}
}

void main() {
  for (final configuration in [(true, true), (true, false), (false, true)]) {
    testWidgets(
        'settings backup entry respects local mode and capability $configuration',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final state = AppState(await SharedPreferences.getInstance(),
          localBackendSupported: configuration.$1);
      final requested = <String>[];
      final api =
          ApiClient(() => state.backendUrl, client: MockClient((request) async {
        requested.add(request.url.path);
        return http.Response.bytes(
            utf8.encode(jsonEncode(request.url.path.endsWith('/settings')
                ? TranslationSettings.defaults().toJson()
                : [])),
            200,
            headers: {'Content-Type': 'application/json'});
      }));
      final backend = BackendConnectionManager(api, isConfigured: () => false)
        ..status = BackendStatus.ready
        ..capabilities = {'backups': configuration.$2};
      final auth = AuthController.localAdministrator(api);
      final library = LibraryController(api);
      final tasks = TasksController(api);
      final sources = SourcesController(api);
      final settings = SettingsController(api);
      addTearDown(() async {
        library.dispose();
        tasks.dispose();
        sources.dispose();
        settings.dispose();
        auth.dispose();
        await backend.dispose();
        api.close();
        state.dispose();
      });
      await tester.pumpWidget(FluentApp(
          home: UiPlatformScope(
        platform: TargetPlatform.windows,
        child: AppScope(
            appState: state,
            api: api,
            backend: backend,
            auth: auth,
            library: library,
            sources: sources,
            tasks: tasks,
            settings: settings,
            child: SettingsPage(voiceService: _Voices())),
      )));
      await tester.pumpAndSettle();
      await selectSettingsCategory(tester, SettingsCategory.application);
      final entry = find.byKey(const ValueKey('settings-backups-button'));
      if (configuration.$1 && configuration.$2) {
        expect(entry, findsOneWidget);
        await tester.ensureVisible(entry);
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(find.text('本机备份与恢复'), findsOneWidget);
        expect(requested, contains('/api/v1/backups'));
        final dialog = tester.widget<BackupsDialog>(find.byType(BackupsDialog));
        await dialog.onRestored();
        await tester.pumpAndSettle();
        expect(
            requested,
            containsAll([
              '/api/v1/books',
              '/api/v1/tasks',
              '/api/v1/sources',
              '/api/v1/plugins',
              '/api/v1/settings'
            ]));
      } else {
        expect(entry, findsNothing);
        expect(requested, isEmpty);
      }
    });
  }
}
