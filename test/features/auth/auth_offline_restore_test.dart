import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/api/api_exception.dart';
import 'package:qingjuan/core/backend/user_session_store.dart';
import 'package:qingjuan/core/models/user_account.dart';
import 'package:qingjuan/features/auth/auth_controller.dart';

void main() {
  for (final code in [null, 503, 401, 403]) {
    test('restore HTTP $code preserves only transient offline credentials',
        () async {
      final api = _AuthApi(code);
      final store = _SessionStore();
      final auth =
          AuthController(api, store, backendUrl: () => 'https://backend.test');
      addTearDown(auth.dispose);
      addTearDown(api.close);
      await auth.initializeForCurrentBackend(multiUser: true);
      final retained = code != 401 && code != 403;
      expect(auth.canAccessWorkspace, isFalse);
      expect(auth.userToken, isEmpty);
      expect(auth.canRestoreOfflineSession, retained);
      expect(store.token != null, retained);
      await auth.logout();
      expect(auth.canRestoreOfflineSession, isFalse);
      expect(store.token, isNull);
    });
  }
}

class _AuthApi extends ApiClient {
  _AuthApi(this.code) : super(() => 'https://backend.test');
  final int? code;
  @override
  Future<UserAccount> fetchUserSession() async =>
      throw ApiException('test failure', statusCode: code);
}

class _SessionStore implements UserSessionStore {
  String? token = 'stored-session';
  @override
  Future<void> deleteToken() async {
    token = null;
  }

  @override
  Future<String?> readToken(String backendUrl) async => token;
  @override
  Future<void> writeToken(
      {required String backendUrl, required String token}) async {
    this.token = token;
  }
}
