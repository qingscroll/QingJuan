import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart' as crypto;

import '../models/account_maintenance.dart';
import '../models/backup.dart';
import '../models/book.dart';
import '../models/book_metadata.dart';
import '../models/book_update.dart';
import '../models/discovery.dart';
import '../models/link_job.dart';
import '../models/manga_workflow.dart';
import '../models/settings.dart';
import '../models/site_plugin.dart';
import '../models/plugin_maintenance.dart';
import '../models/reading_annotation.dart';
import '../models/source.dart';
import '../models/storage.dart';
import '../models/task.dart';
import '../models/translation_quality.dart';
import '../models/user_account.dart';
import 'api_exception.dart';
import 'browser_login_response.dart';
import 'reading_progress_exception.dart';

class ApiClient {
  ApiClient(
    this._baseUrl, {
    String Function()? token,
    String Function()? userToken,
    int Function()? connectionRevision,
    Map<String, String> Function()? deviceHeaders,
    void Function()? onUserSessionExpired,
    http.Client? client,
    Future<void> Function(File backup)? deleteDownloadBackup,
  })  : _token = token ?? (() => ''),
        _userToken = userToken ?? (() => ''),
        _connectionRevision = connectionRevision ?? (() => 0),
        _deviceHeaders = deviceHeaders ?? (() => const <String, String>{}),
        _onUserSessionExpired = onUserSessionExpired,
        _client = client ?? http.Client(),
        _deleteDownloadBackup = deleteDownloadBackup ??
            ((backup) async {
              await backup.delete();
            });

  static const _apiPrefix = '/api/v1';
  final String Function() _baseUrl;
  final String Function() _token;
  final String Function() _userToken;
  final int Function() _connectionRevision;
  final Map<String, String> Function() _deviceHeaders;
  final void Function()? _onUserSessionExpired;
  final http.Client _client;
  final Future<void> Function(File backup) _deleteDownloadBackup;

  Uri _uri(String endpoint, [Map<String, dynamic>? query]) =>
      _uriFor(_baseUrl(), endpoint, query);

  Uri _uriFor(
    String baseUrl,
    String endpoint, [
    Map<String, dynamic>? query,
  ]) {
    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base$_apiPrefix$endpoint').replace(
      queryParameters: query?.map((key, value) => MapEntry(key, '$value')),
    );
  }

  Map<String, String> _headers({
    bool json = false,
    String? token,
    String? userToken,
    bool includeUserToken = true,
  }) {
    final value = (token ?? _token()).trim();
    final userValue =
        includeUserToken ? (userToken ?? _userToken()).trim() : '';
    final headers = <String, String>{
      if (json) 'Content-Type': 'application/json',
      if (userValue.isNotEmpty) 'X-QingJuan-User-Token': userValue,
    };
    if (value.isNotEmpty) {
      headers['Authorization'] = 'Bearer $value';
      headers.addAll(_deviceHeaders());
    } else {
      headers['X-QingJuan-Local-Request'] = '1';
    }
    return headers;
  }

  Future<http.Response> _request(
    String method,
    String endpoint, {
    Object? body,
    Map<String, dynamic>? query,
    bool includeUserToken = true,
    int? attempts,
    String? idempotencyKey,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final baseUrl = _baseUrl();
    final connectionToken = _token().trim();
    final userToken = includeUserToken ? _userToken().trim() : '';
    final connectionRevision = _connectionRevision();
    final uri = _uriFor(baseUrl, endpoint, query);
    final headers = _headers(
      json: body != null,
      token: connectionToken,
      userToken: userToken,
      includeUserToken: includeUserToken,
    );
    final encoded = body == null ? null : jsonEncode(body);
    if (idempotencyKey != null) headers['Idempotency-Key'] = idempotencyKey;
    // A lost response does not mean the server rejected a mutation.
    final maximumAttempts = attempts ?? (method == 'GET' ? 4 : 1);
    Object? lastError;
    for (var attempt = 0; attempt < maximumAttempts; attempt++) {
      try {
        final requestFuture = switch (method) {
          'GET' => _client.get(uri, headers: headers),
          'POST' => _client.post(uri, headers: headers, body: encoded),
          'PUT' => _client.put(uri, headers: headers, body: encoded),
          'PATCH' => _client.patch(uri, headers: headers, body: encoded),
          'DELETE' => _client.delete(uri, headers: headers, body: encoded),
          _ => throw UnsupportedError('Unsupported HTTP method: $method'),
        };
        final response = await requestFuture.timeout(timeout);
        if (includeUserToken &&
            response.statusCode == 401 &&
            userToken.isNotEmpty &&
            _userToken().trim() == userToken &&
            _token().trim() == connectionToken &&
            _baseUrl() == baseUrl &&
            _connectionRevision() == connectionRevision) {
          _onUserSessionExpired?.call();
        }
        return response;
      } on SocketException catch (error) {
        lastError = error;
      } on http.ClientException catch (error) {
        lastError = error;
      } on TimeoutException catch (error) {
        lastError = error;
      }
      if (attempt < maximumAttempts - 1) {
        await Future<void>.delayed(
            Duration(milliseconds: 250 * (1 << attempt)));
      }
    }
    throw ApiException('无法连接青卷后端：${lastError ?? '网络不可用'}');
  }

  dynamic _decode(http.Response response) {
    dynamic payload;
    try {
      payload = response.bodyBytes.isEmpty
          ? null
          : jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      payload = utf8.decode(response.bodyBytes);
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return payload;
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    final rawText = payload is String ? payload.trim().toLowerCase() : '';
    final htmlResponse = contentType.contains('text/html') ||
        rawText.startsWith('<!doctype html') ||
        rawText.startsWith('<html') ||
        rawText.contains('<head>') ||
        rawText.contains('<body>');
    if (htmlResponse ||
        response.statusCode == 502 ||
        response.statusCode == 503 ||
        response.statusCode == 504) {
      throw ApiException(
        '服务器暂时无法完成请求（HTTP ${response.statusCode}），请稍后重试。',
        statusCode: response.statusCode,
      );
    }
    final detail = payload is Map ? payload['detail'] : payload;
    final message = switch (detail) {
      String value when value.trim().isNotEmpty => value,
      List value =>
        value.map((entry) => entry is Map ? entry['msg'] : entry).join('\n'),
      _ => '请求失败（HTTP ${response.statusCode}）',
    };
    throw ApiException(message, statusCode: response.statusCode);
  }

  List<JsonMap> _list(dynamic payload) => (payload as List? ?? const [])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();

  JsonMap _map(dynamic payload) => Map<String, dynamic>.from(payload as Map);

  Future<bool> health() async {
    try {
      final response = await _client
          .get(
              Uri.parse('${_baseUrl().replaceAll(RegExp(r'/+$'), '')}/healthz'))
          .timeout(const Duration(seconds: 2));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<JsonMap> fetchServiceMeta({bool quick = false}) async {
    final payload = _decode(
      await _request(
        'GET',
        '/meta',
        includeUserToken: false,
        attempts: quick ? 1 : 4,
        timeout:
            quick ? const Duration(seconds: 5) : const Duration(minutes: 2),
      ),
    );
    final meta = _map(payload);
    if (meta['service'] != 'qingjuan-backend' || meta['apiVersion'] != '1') {
      throw const ApiException('目标服务不是兼容的青卷后端');
    }
    return meta;
  }

  Future<void> sendDeviceHeartbeat() async {
    _decode(await _request('POST', '/devices/heartbeat'));
  }

  Future<JsonMap> testConnection({
    required String baseUrl,
    required String token,
  }) async {
    final response = await _client
        .get(
          _uriFor(baseUrl, '/meta'),
          headers: _headers(token: token, includeUserToken: false),
        )
        .timeout(const Duration(seconds: 8));
    final meta = _map(_decode(response));
    if (meta['service'] != 'qingjuan-backend' || meta['apiVersion'] != '1') {
      throw const ApiException('目标服务不是兼容的青卷后端');
    }
    return meta;
  }

  Future<UserSession> registerUser({
    required String username,
    required String displayName,
    required String email,
    required String password,
    String? emailCode,
    String? identityBadge,
  }) async {
    final payload = _decode(
      await _request(
        'POST',
        '/auth/register',
        body: <String, dynamic>{
          'username': username,
          'displayName': displayName,
          'email': email,
          'password': password,
          if (emailCode != null && emailCode.isNotEmpty) 'emailCode': emailCode,
          if (identityBadge != null && identityBadge.isNotEmpty)
            'identityBadge': identityBadge,
        },
        includeUserToken: false,
        attempts: 1,
      ),
    );
    return UserSession.fromJson(_map(payload));
  }

  Future<RegistrationPolicy> fetchRegistrationPolicy() async {
    final payload = _decode(
      await _request(
        'GET',
        '/auth/registration-policy',
        includeUserToken: false,
      ),
    );
    return RegistrationPolicy.fromJson(_map(payload));
  }

  Future<void> sendRegistrationEmailCode({required String email}) async {
    _decode(
      await _request(
        'POST',
        '/auth/email-code',
        body: <String, dynamic>{'email': email},
        includeUserToken: false,
        attempts: 1,
      ),
    );
  }

  Future<LoginResult> loginUser({
    required String username,
    required String password,
  }) async {
    final payload = _decode(
      await _request(
        'POST',
        '/auth/login',
        body: <String, dynamic>{
          'username': username,
          'password': password,
        },
        includeUserToken: false,
        attempts: 1,
      ),
    );
    return LoginResult.fromJson(_map(payload));
  }

  Future<UserSession> completeTwoFactorLogin({
    required String challengeToken,
    required String code,
  }) async {
    final payload = _decode(
      await _request(
        'POST',
        '/auth/login/2fa',
        body: <String, dynamic>{
          'challengeToken': challengeToken,
          'code': code,
        },
        includeUserToken: false,
        attempts: 1,
      ),
    );
    return UserSession.fromJson(_map(payload));
  }

  Future<GitHubDeviceFlow> startGitHubDevice({
    required String purpose,
    String? password,
    String? code,
  }) async {
    final payload = _decode(
      await _request(
        'POST',
        '/auth/github/device/start',
        body: <String, dynamic>{
          'purpose': purpose,
          if (password != null) 'password': password,
          if (code != null && code.isNotEmpty) 'code': code,
        },
        includeUserToken: purpose == 'bind',
        attempts: 1,
      ),
    );
    return GitHubDeviceFlow.fromJson(_map(payload), purpose: purpose);
  }

  Future<GitHubDevicePollResult> pollGitHubDevice(
    GitHubDeviceFlow flow,
  ) async {
    final payload = _decode(
      await _request(
        'POST',
        '/auth/github/device/poll',
        body: <String, dynamic>{'flowId': flow.flowId},
        includeUserToken: flow.purpose == 'bind',
        attempts: 1,
        timeout: const Duration(seconds: 20),
      ),
    );
    return GitHubDevicePollResult.fromJson(_map(payload));
  }

  Future<AccountSecurity> fetchAccountSecurity() async {
    final payload = _decode(await _request('GET', '/auth/account/security'));
    return AccountSecurity.fromJson(_map(payload));
  }

  Future<AccountMaintenance> fetchAccountMaintenance() async {
    return AccountMaintenance.fromJson(_map(_decode(
      await _request('GET', '/auth/account/maintenance'),
    )));
  }

  Future<List<AccountSession>> fetchAccountSessions() async {
    final payload =
        _map(_decode(await _request('GET', '/auth/account/sessions')));
    return (payload['sessions'] as List<dynamic>)
        .map((item) => AccountSession.fromJson(_map(item)))
        .toList();
  }

  Future<void> changeAccountPassword({
    required String currentPassword,
    required String newPassword,
    String? code,
  }) async {
    _decode(await _request('POST', '/auth/account/password',
        body: {
          'currentPassword': currentPassword,
          'newPassword': newPassword,
          if (code != null && code.isNotEmpty) 'code': code,
        },
        attempts: 1));
  }

  Future<AccountEmailDispatch> requestAccountEmailVerification({
    required String password,
    String? code,
  }) async {
    return AccountEmailDispatch.fromJson(_map(_decode(await _request(
      'POST',
      '/auth/account/email-verification/request',
      body: {
        'password': password,
        if (code != null && code.isNotEmpty) 'code': code,
      },
      attempts: 1,
    ))));
  }

  Future<void> confirmAccountEmailVerification(
      {required String emailCode}) async {
    _decode(await _request('POST', '/auth/account/email-verification/confirm',
        body: {'emailCode': emailCode}, attempts: 1));
  }

  Future<AccountEmailDispatch> requestPasswordReset(
      {required String email}) async {
    return AccountEmailDispatch.fromJson(_map(_decode(await _request(
      'POST',
      '/auth/password-reset/request',
      body: {'email': email},
      includeUserToken: false,
      attempts: 1,
    ))));
  }

  Future<void> confirmPasswordReset({
    required String email,
    required String emailCode,
    required String newPassword,
    String? code,
  }) async {
    _decode(await _request('POST', '/auth/password-reset/confirm',
        body: {
          'email': email,
          'emailCode': emailCode,
          'newPassword': newPassword,
          if (code != null && code.isNotEmpty) 'code': code,
        },
        includeUserToken: false,
        attempts: 1));
  }

  Future<void> revokeAccountSession(String id) async {
    _decode(await _request(
        'DELETE', '/auth/account/sessions/${Uri.encodeComponent(id)}',
        attempts: 1));
  }

  Future<void> unbindGitHub({
    required String password,
    String? code,
  }) async {
    _decode(
      await _request(
        'POST',
        '/auth/account/github/unbind',
        body: <String, dynamic>{
          'password': password,
          if (code != null && code.isNotEmpty) 'code': code,
        },
        attempts: 1,
      ),
    );
  }

  Future<TwoFactorSetup> setupTwoFactor({required String password}) async {
    final payload = _decode(
      await _request(
        'POST',
        '/auth/account/2fa/setup',
        body: <String, dynamic>{'password': password},
        attempts: 1,
      ),
    );
    return TwoFactorSetup.fromJson(_map(payload));
  }

  Future<RecoveryCodes> enableTwoFactor({
    required String setupId,
    required String code,
  }) async {
    final payload = _decode(
      await _request(
        'POST',
        '/auth/account/2fa/enable',
        body: <String, dynamic>{'setupId': setupId, 'code': code},
        attempts: 1,
      ),
    );
    return RecoveryCodes.fromJson(_map(payload));
  }

  Future<void> disableTwoFactor({
    required String password,
    required String code,
  }) async {
    _decode(
      await _request(
        'POST',
        '/auth/account/2fa/disable',
        body: <String, dynamic>{'password': password, 'code': code},
        attempts: 1,
      ),
    );
  }

  Future<RecoveryCodes> regenerateTwoFactorRecoveryCodes({
    required String password,
    required String code,
  }) async {
    final payload = _decode(
      await _request(
        'POST',
        '/auth/account/2fa/recovery-codes',
        body: <String, dynamic>{'password': password, 'code': code},
        attempts: 1,
      ),
    );
    return RecoveryCodes.fromJson(_map(payload));
  }

  Future<UserAccount> fetchUserSession() async {
    final payload = _decode(await _request('GET', '/auth/session'));
    return UserAccount.fromJson(_map(payload));
  }

  Future<void> logoutUser() async {
    _decode(await _request('POST', '/auth/logout'));
  }

  Future<TranslationModelCheck> checkTranslationModel({
    bool force = false,
  }) async {
    final payload = _decode(
      await _request(
        'POST',
        '/translation-model/check',
        query: <String, dynamic>{'force': force},
      ),
    );
    return TranslationModelCheck.fromJson(_map(payload));
  }

  Future<List<Book>> fetchBooks() async {
    final payload = _decode(await _request('GET', '/books'));
    return _list(payload).map(Book.fromJson).toList();
  }

  Future<List<BookUpdate>> fetchBookUpdates() async =>
      _list(_decode(await _request('GET', '/book-updates')))
          .map(BookUpdate.fromJson)
          .toList();

  Future<BookUpdate> fetchBookUpdate(String id) async =>
      BookUpdate.fromJson(_map(_decode(
          await _request('GET', '/books/${Uri.encodeComponent(id)}/updates'))));

  Future<BookUpdate> configureBookUpdates(String id,
          {required int expectedRevision,
          bool? enabled,
          required int intervalHours,
          required bool autoDownload}) async =>
      BookUpdate.fromJson(_map(_decode(await _request(
          'PUT', '/books/${Uri.encodeComponent(id)}/updates',
          attempts: 1,
          body: {
            'expectedRevision': expectedRevision,
            if (enabled != null) 'enabled': enabled,
            'intervalHours': intervalHours,
            'autoDownload': autoDownload
          }))));

  Future<BookUpdate> checkBookUpdates(String id) async =>
      BookUpdate.fromJson(_map(_decode(await _request(
          'POST', '/books/${Uri.encodeComponent(id)}/updates/check',
          attempts: 1))));

  Future<BookUpdate> acknowledgeBookUpdates(String id,
          {required int throughChapterIndex}) async =>
      BookUpdate.fromJson(_map(_decode(await _request(
          'POST', '/books/${Uri.encodeComponent(id)}/updates/ack',
          attempts: 1, body: {'throughChapterIndex': throughChapterIndex}))));

  Future<BookGlossary> fetchBookGlossary(String bookId) async =>
      BookGlossary.fromJson(_map(_decode(await _request(
          'GET', '/books/${Uri.encodeComponent(bookId)}/glossary'))));

  Future<BookGlossary> saveBookGlossary(String bookId,
          {required int expectedRevision,
          required List<GlossaryEntry> entries}) async =>
      BookGlossary.fromJson(_map(_decode(await _request(
          'PUT', '/books/${Uri.encodeComponent(bookId)}/glossary',
          attempts: 1,
          body: {
            'expectedRevision': expectedRevision,
            'entries': entries.map((entry) => entry.toJson()).toList()
          }))));

  String _qualityPath(String bookId, int chapterIndex) =>
      '/books/${Uri.encodeComponent(bookId)}/translation/chapters/$chapterIndex';

  Future<ChapterTranslation> fetchChapterTranslation(
          String bookId, int chapterIndex) async =>
      ChapterTranslation.fromJson(_map(
          _decode(await _request('GET', _qualityPath(bookId, chapterIndex)))));

  Future<ChapterTranslation> saveChapterTranslation(ChapterTranslation expected,
          {required String text}) async =>
      ChapterTranslation.fromJson(_map(_decode(await _request(
          'PUT', _qualityPath(expected.bookId, expected.chapterIndex),
          attempts: 1, body: {...expected.casJson, 'text': text}))));

  Future<TranslationRevision> fetchTranslationRevision(
          String bookId, int chapterIndex, String historyId) async =>
      TranslationRevision.fromJson(_map(_decode(await _request('GET',
          '${_qualityPath(bookId, chapterIndex)}/history/${Uri.encodeComponent(historyId)}'))));

  Future<ChapterTranslation> restoreTranslationRevision(
          ChapterTranslation expected,
          {required String historyId}) async =>
      ChapterTranslation.fromJson(_map(_decode(await _request('POST',
          '${_qualityPath(expected.bookId, expected.chapterIndex)}/restore',
          attempts: 1, body: {...expected.casJson, 'historyId': historyId}))));

  Future<TranslationSuggestion> retranslateSelection(
          ChapterTranslation expected,
          {required String operationId,
          required int sourceStart,
          required int sourceEnd}) async =>
      TranslationSuggestion.fromJson(_map(_decode(await _request('POST',
          '${_qualityPath(expected.bookId, expected.chapterIndex)}/retranslate',
          attempts: 1,
          timeout: const Duration(seconds: 70),
          body: {
            ...expected.casJson,
            'operationId': operationId,
            'sourceStart': sourceStart,
            'sourceEnd': sourceEnd
          }))));

  Future<List<TranslationUsage>> fetchTranslationUsage(String bookId) async =>
      _list(_decode(await _request('GET',
              '/books/${Uri.encodeComponent(bookId)}/translation/usage')))
          .map(TranslationUsage.fromJson)
          .toList();

  Future<List<ReadingAnnotation>> fetchAnnotations(String bookId,
          {int limit = 50,
          int offset = 0,
          String? kind,
          int? chapterIndex,
          String? mode}) async =>
      _list(_decode(await _request(
              'GET', '/books/${Uri.encodeComponent(bookId)}/annotations',
              query: {
            'limit': limit,
            'offset': offset,
            if (kind != null) 'kind': kind,
            if (chapterIndex != null) 'chapterIndex': chapterIndex,
            if (mode != null) 'mode': mode,
          })))
          .map(ReadingAnnotation.fromJson)
          .toList();

  Future<ReadingAnnotation> createAnnotation(String bookId,
          {required String clientKey,
          required String kind,
          required String label,
          required String quote,
          required String note,
          required AnnotationPosition position}) async =>
      ReadingAnnotation.fromJson(_map(_decode(await _request(
          'POST', '/books/${Uri.encodeComponent(bookId)}/annotations',
          attempts: 1,
          body: {
            'clientKey': clientKey,
            'kind': kind,
            'label': label,
            'quote': quote,
            'note': note,
            'position': position.toJson(),
          }))));

  Future<ReadingAnnotation> updateAnnotation(String bookId, String annotationId,
          {required int expectedRevision, required JsonMap changes}) async =>
      ReadingAnnotation.fromJson(_map(_decode(await _request('PATCH',
          '/books/${Uri.encodeComponent(bookId)}/annotations/${Uri.encodeComponent(annotationId)}',
          attempts: 1,
          body: {...changes, 'expectedRevision': expectedRevision}))));

  Future<void> deleteAnnotation(String bookId, String annotationId,
      {required int expectedRevision}) async {
    _decode(await _request('DELETE',
        '/books/${Uri.encodeComponent(bookId)}/annotations/${Uri.encodeComponent(annotationId)}',
        attempts: 1, query: {'expectedRevision': expectedRevision}));
  }

  Future<CachedTextResults> searchCachedText(String bookId,
          {required String query,
          String mode = 'original',
          int? chapterIndex,
          String? cursor,
          int limit = 50}) async =>
      CachedTextResults.fromJson(_map(_decode(await _request(
          'POST', '/books/${Uri.encodeComponent(bookId)}/search-text',
          attempts: 1,
          body: {
            'query': query,
            'mode': mode,
            'limit': limit,
            if (chapterIndex != null) 'chapterIndex': chapterIndex,
            if (cursor != null) 'cursor': cursor,
          }))));

  Future<BookDetail> fetchBookDetail(String bookId) async {
    final payload = _decode(await _request('GET', '/books/$bookId'));
    return BookDetail.fromJson(_map(payload));
  }

  Future<BookStorageReport> fetchBookStorage(String bookId) async =>
      BookStorageReport.fromJson(_map(_decode(await _request(
          'GET', '/books/${Uri.encodeComponent(bookId)}/storage'))));

  Future<StorageCleanupPreview> previewBookStorageCleanup(
          String bookId) async =>
      StorageCleanupPreview.fromJson(_map(_decode(await _request('POST',
          '/books/${Uri.encodeComponent(bookId)}/storage/cleanup-preview',
          attempts: 1,
          body: {
            'categories': ['exports']
          }))));

  Future<StorageCleanupResult> cleanupBookStorage(
          StorageCleanupPreview preview) async =>
      StorageCleanupResult.fromJson(_map(_decode(await _request('POST',
          '/books/${Uri.encodeComponent(preview.bookId)}/storage/cleanup',
          attempts: 1,
          timeout: const Duration(seconds: 60),
          body: {
            'cleanupId': preview.cleanupId,
            'confirmationToken': preview.confirmationToken,
          }))));

  Future<BookMetadata> fetchBookMetadata(String bookId) async =>
      BookMetadata.fromJson(_map(_decode(await _request(
          'GET', '/books/${Uri.encodeComponent(bookId)}/metadata'))));

  Future<BookMetadata> updateBookMetadata(String bookId,
          {required int expectedRevision, required JsonMap changes}) async =>
      BookMetadata.fromJson(_map(_decode(await _request(
        'PATCH',
        '/books/${Uri.encodeComponent(bookId)}/metadata',
        attempts: 1,
        body: <String, dynamic>{
          ...changes,
          'expectedRevision': expectedRevision
        },
      ))));

  Future<ChapterContent> fetchChapter(
    String bookId,
    int chapterIndex, {
    String mode = 'translated',
    bool prefetch = false,
  }) async {
    final payload = _decode(
      await _request('GET', '/books/$bookId/chapters/$chapterIndex',
          query: <String, dynamic>{
            'mode': mode,
            if (prefetch) 'prefetch': 'true',
          }),
    );
    final chapter = ChapterContent.fromJson(_map(payload));
    final normalizedImages = chapter.imageSources.map(resolveUrl).toList();
    return ChapterContent(
      chapter: chapter.chapter,
      content: chapter.content,
      paragraphs: chapter.paragraphs,
      mode: chapter.mode,
      translatedAvailable: chapter.translatedAvailable,
      imageSources: normalizedImages,
      pageTranslations: chapter.pageTranslations,
    );
  }

  Future<BookPreview> previewBook(JsonMap payload) async {
    final response =
        _decode(await _request('POST', '/books/preview', body: payload));
    return BookPreview.fromJson(_map(response));
  }

  Future<ChapterContent> previewChapter(JsonMap book, int chapterIndex,
      {String? expectedChapterUrl}) async {
    if (chapterIndex < 1) {
      throw const ApiException('试读章节序号无效');
    }
    final response =
        _decode(await _request('POST', '/books/preview/chapter', body: {
      'book': book,
      'chapterIndex': chapterIndex,
      if (expectedChapterUrl != null && expectedChapterUrl.isNotEmpty)
        'expectedChapterUrl': expectedChapterUrl,
    }));
    final chapter = ChapterContent.fromJson(_map(response));
    return ChapterContent(
      chapter: chapter.chapter,
      content: chapter.content,
      paragraphs: chapter.paragraphs,
      mode: 'original',
      translatedAvailable: false,
      imageSources: chapter.imageSources.map((source) {
        // Preview assets may be API-root relative or use the usual API-relative
        // book asset path. Credentials remain governed by headersForUrl.
        if (source.startsWith('$_apiPrefix/')) {
          return '${_baseUrl().replaceAll(RegExp(r'/+$'), '')}$source';
        }
        return resolveUrl(source);
      }).toList(growable: false),
      pageTranslations: const [],
    );
  }

  Future<LinkJob> startLinkJob(String mode, JsonMap payload,
      {String? idempotencyKey}) async {
    final operationKey = idempotencyKey ?? createOperationKey();
    final response = _decode(
      await _request(
        'POST',
        '/books/link-jobs',
        body: <String, dynamic>{'mode': mode, 'payload': payload},
        idempotencyKey: operationKey,
      ),
    );
    return LinkJob.fromJson(_map(response));
  }

  static String createOperationKey() {
    final random = math.Random.secure();
    return List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<LinkJob> fetchLinkJob(String jobId) async {
    final response = _decode(await _request('GET', '/books/link-jobs/$jobId'));
    return LinkJob.fromJson(_map(response));
  }

  Future<Book> importBook(JsonMap payload) async {
    final response =
        _decode(await _request('POST', '/books/import', body: payload));
    return Book.fromJson(_map(response));
  }

  Future<Book> importLocalBook({
    required String filePath,
    required String kind,
    required String language,
    required bool translate,
    String? title,
    String textEncoding = 'auto',
    void Function(int sentBytes, int totalBytes)? onProgress,
  }) async {
    final multipart = http.MultipartRequest('POST', _uri('/books/import-local'))
      ..headers.addAll(_headers())
      ..fields['bookKind'] = kind
      ..fields['language'] = language
      ..fields['needTranslation'] = '$translate'
      ..fields['textEncoding'] = textEncoding;
    if (title != null && title.trim().isNotEmpty) {
      multipart.fields['title'] = title.trim();
    }
    multipart.files.add(
      await http.MultipartFile.fromPath('file', filePath),
    );
    final totalBytes = multipart.contentLength;
    final body = multipart.finalize();
    final request = http.StreamedRequest('POST', multipart.url)
      ..headers.addAll(multipart.headers);
    final responseFuture =
        _client.send(request).timeout(const Duration(minutes: 30));
    var sentBytes = 0;
    await for (final chunk in body) {
      request.sink.add(chunk);
      sentBytes += chunk.length;
      onProgress?.call(sentBytes, totalBytes);
    }
    await request.sink.close();
    final streamed = await responseFuture;
    final response = await http.Response.fromStream(streamed);
    return Book.fromJson(_map(_decode(response)));
  }

  Future<MangaWorkflowResult> runImageWorkflow({
    required String filePath,
    required String mode,
    String language = '中文',
    String title = '',
    Object? project,
    Object? companion,
    String? translatedFilePath,
    int upscaleFactor = 2,
    Future<void>? abortTrigger,
  }) async {
    final multipart = http.AbortableMultipartRequest(
      'POST',
      _uri('/images/workflow'),
      abortTrigger: abortTrigger,
    )
      ..headers.addAll(_headers())
      ..fields['mode'] = mode
      ..fields['language'] = language
      ..fields['title'] = title
      ..fields['upscaleFactor'] = '$upscaleFactor'
      ..files.add(await http.MultipartFile.fromPath('file', filePath));
    if (project != null) {
      multipart.fields['project'] = jsonEncode(project);
    }
    if (companion != null) {
      multipart.fields['companion'] = jsonEncode(companion);
    }
    if (translatedFilePath != null && translatedFilePath.trim().isNotEmpty) {
      multipart.files.add(
        await http.MultipartFile.fromPath(
          'translatedFile',
          translatedFilePath,
        ),
      );
    }
    final streamed =
        await _client.send(multipart).timeout(const Duration(minutes: 30));
    final response = await http.Response.fromStream(streamed);
    return MangaWorkflowResult.fromJson(_map(_decode(response)));
  }

  Future<void> saveMangaBookshelfTranslation({
    required String bookId,
    required int chapterIndex,
    required String targetLanguage,
    required List<Map<String, dynamic>> pages,
  }) async {
    final orderedPages =
        pages.map((page) => Map<String, dynamic>.from(page)).toList()
          ..sort(
            (left, right) => ((left['pageNumber'] as num?)?.toInt() ?? 0)
                .compareTo((right['pageNumber'] as num?)?.toInt() ?? 0),
          );
    _decode(
      await _request(
        'POST',
        '/books/$bookId/chapters/$chapterIndex/manga-translation',
        body: <String, dynamic>{
          'targetLanguage': targetLanguage,
          'pages': orderedPages,
        },
        timeout: const Duration(minutes: 10),
      ),
    );
  }

  Future<void> deleteBook(String bookId) async {
    _decode(await _request('DELETE', '/books/$bookId'));
  }

  /// A guard captures an account and backend without exposing its credentials.
  bool Function() captureContextGuard() {
    final base = _baseUrl();
    final token = _token();
    final user = _userToken();
    final revision = _connectionRevision();
    return () =>
        base == _baseUrl() &&
        token == _token() &&
        user == _userToken() &&
        revision == _connectionRevision();
  }

  Future<void> saveProgress(
    String bookId,
    int chapterIndex,
    double ratio, {
    String anchorType = 'top',
    int anchorIndex = 0,
    double anchorOffsetRatio = 0,
    int? pageIndex,
    int? pageCount,
    String? layoutKey,
    String? contentMode,
    int? characterOffset,
  }) async {
    _decode(
      await _request(
        'PUT',
        '/books/$bookId/progress',
        timeout: const Duration(seconds: 8),
        body: <String, dynamic>{
          'chapterIndex': chapterIndex,
          'scrollRatio': ratio,
          'anchorType': anchorType,
          'anchorIndex': anchorIndex,
          'anchorOffsetRatio': anchorOffsetRatio,
          if (pageIndex != null) 'pageIndex': pageIndex,
          if (pageCount != null) 'pageCount': pageCount,
          if (layoutKey != null) 'layoutKey': layoutKey,
          if (contentMode != null) 'contentMode': contentMode,
          if (characterOffset != null) 'characterOffset': characterOffset,
        },
      ),
    );
  }

  Future<ReadingProgress> fetchReadingProgress(String bookId) async {
    return ReadingProgress.fromJson(_map(_decode(await _request(
      'GET',
      '/books/${Uri.encodeComponent(bookId)}/progress',
    ))));
  }

  Future<ReadingProgress> saveVersionedProgress(
    String bookId,
    ReadingProgress progress, {
    required int expectedRevision,
    required String operationId,
  }) async {
    final response = await _request(
        'PUT', '/books/${Uri.encodeComponent(bookId)}/progress',
        timeout: const Duration(seconds: 8),
        attempts: 1,
        body: {
          'chapterIndex': progress.chapterIndex,
          'scrollRatio': progress.scrollRatio,
          'anchorType': progress.anchorType,
          'anchorIndex': progress.anchorIndex,
          'anchorOffsetRatio': progress.anchorOffsetRatio,
          if (progress.pageIndex != null) 'pageIndex': progress.pageIndex,
          if (progress.pageCount != null) 'pageCount': progress.pageCount,
          if (progress.layoutKey != null) 'layoutKey': progress.layoutKey,
          if (progress.contentMode != null) 'contentMode': progress.contentMode,
          if (progress.characterOffset != null)
            'characterOffset': progress.characterOffset,
          'expectedRevision': expectedRevision,
          'operationId': operationId,
        });
    if (response.statusCode == 409) {
      dynamic payload;
      try {
        payload = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        // A proxy may return a non-JSON conflict; use the common error mapping.
      }
      final detail = payload is Map ? payload['detail'] : null;
      if (detail is Map &&
          detail['current'] is Map &&
          detail['code'] is String) {
        throw ReadingProgressConflict(
          current: ReadingProgress.fromJson(_map(detail['current'])),
          code: detail['code'] as String,
          message: detail['message'] as String? ?? '阅读进度同步冲突',
        );
      }
    }
    return ReadingProgress.fromJson(_map(_decode(response)));
  }

  Future<List<DiscoverySite>> fetchDiscoverySites() async {
    final payload = _map(_decode(await _request('GET', '/discovery/sites')));
    return List.unmodifiable(
      _list(payload['sites']).map(DiscoverySite.fromJson),
    );
  }

  Future<DiscoveryResult> fetchDiscoveryChannel(
    String site,
    String channel, {
    int page = 1,
    int limit = 20,
    bool refresh = false,
  }) async {
    final siteId = Uri.encodeComponent(site);
    final channelId = Uri.encodeComponent(channel);
    final payload = _decode(await _request(
      'GET',
      '/discovery/sites/$siteId/channels/$channelId',
      query: {'page': page, 'limit': limit, 'refresh': refresh},
      timeout: const Duration(seconds: 60),
      attempts: 1,
    ));
    return DiscoveryResult.fromJson(_map(payload));
  }

  Future<List<BookSource>> fetchSources() async {
    final payload = _decode(await _request('GET', '/sources'));
    return _list(payload).map(BookSource.fromJson).toList();
  }

  Future<List<SitePlugin>> fetchSitePlugins() async {
    final payload = _decode(await _request('GET', '/plugins'));
    return _list(payload).map(SitePlugin.fromJson).toList();
  }

  Future<PluginMaintenanceReport> fetchPluginMaintenance(
          String pluginId) async =>
      PluginMaintenanceReport.fromJson(_map(_decode(await _request(
          'GET', '/plugins/${Uri.encodeComponent(pluginId)}/maintenance'))));

  Future<PluginMaintenanceReport> checkPluginMaintenance(
          String pluginId) async =>
      PluginMaintenanceReport.fromJson(_map(_decode(await _request(
          'POST', '/plugins/${Uri.encodeComponent(pluginId)}/check',
          attempts: 1))));

  Future<SitePlugin> rollbackSitePlugin(String pluginId,
          {required String expectedVersion,
          required String expectedSha256}) async =>
      SitePlugin.fromJson(_map(_decode(await _request(
        'POST',
        '/plugins/${Uri.encodeComponent(pluginId)}/rollback',
        attempts: 1,
        body: <String, dynamic>{
          'expectedVersion': expectedVersion,
          'expectedSha256': expectedSha256
        },
      ))));

  Future<JsonMap> _uploadPluginPackage(
      String operation, List<int> bytes, String filename,
      {bool replace = false}) async {
    if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
      throw const ApiException('插件包不能为空且不能超过 2 MiB');
    }
    final request = http.MultipartRequest('POST', _uri('/plugins/$operation'))
      ..headers.addAll(_headers())
      ..followRedirects = false
      ..fields['replace'] = '$replace'
      ..files
          .add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed =
        await _client.send(request).timeout(const Duration(seconds: 60));
    return _map(_decode(await http.Response.fromStream(streamed)
        .timeout(const Duration(seconds: 60))));
  }

  Future<SitePluginPackageInspection> inspectSitePluginPackage(
          List<int> bytes, String filename) async =>
      SitePluginPackageInspection.fromJson(
          await _uploadPluginPackage('inspect', bytes, filename));

  Future<SitePlugin> importSitePluginPackage(List<int> bytes, String filename,
          {bool replace = false}) async =>
      SitePlugin.fromJson(await _uploadPluginPackage('import', bytes, filename,
          replace: replace));

  Future<void> uninstallSitePlugin(String pluginId) async {
    _decode(
        await _request('DELETE', '/plugins/${Uri.encodeComponent(pluginId)}'));
  }

  Future<List<SourceSearchResult>> searchInstalledPlugins(
      String keyword) async {
    final payload = _decode(await _request(
      'POST',
      '/plugins/search',
      body: <String, dynamic>{'keyword': keyword, 'limit': 60},
      timeout: const Duration(seconds: 60),
    ));
    return _list(payload).map(SourceSearchResult.fromJson).toList();
  }

  Future<SitePlugin> saveSitePluginEnabled(
      String pluginId, bool enabled) async {
    final payload = _decode(
      await _request(
        'PUT',
        '/plugins/${Uri.encodeComponent(pluginId)}',
        body: <String, dynamic>{'enabled': enabled},
      ),
    );
    return SitePlugin.fromJson(_map(payload));
  }

  Future<SitePluginAccount> fetchSitePluginAccount(String pluginId) async {
    final encodedId = Uri.encodeComponent(pluginId);
    final payload =
        _decode(await _request('GET', '/plugins/$encodedId/account'));
    return SitePluginAccount.fromJson(_map(payload));
  }

  Future<SitePluginLoginQrCode> startSitePluginLogin(String pluginId) async {
    final encodedId = Uri.encodeComponent(pluginId);
    final payload = _decode(
      await _request('POST', '/plugins/$encodedId/account/login-qrcode'),
    );
    return SitePluginLoginQrCode.fromJson(_map(payload));
  }

  Future<SitePluginBrowserLogin> startSitePluginBrowserLogin(
      String pluginId) async {
    final current = captureContextGuard();
    final base = _baseUrl().replaceAll(RegExp(r'/+$'), '');
    final encoded = Uri.encodeComponent(pluginId);
    final payload = decodeBrowserLoginResponse(await _request(
      'POST',
      '/plugins/$encoded/account/login-browser',
      timeout: const Duration(seconds: 20),
    ));
    if (!current()) throw const ApiException('后端或账号已切换，请重新登录');
    final token = payload['browserToken'] as String? ?? '';
    final flowId = payload['flowId'] as String? ?? '';
    final expiry = DateTime.tryParse(payload['expiresAt'] as String? ?? '');
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token) ||
        flowId.isEmpty ||
        expiry == null) {
      throw const ApiException('登录响应无效，请重试');
    }
    return SitePluginBrowserLogin(
      flowId: flowId,
      verificationUri:
          Uri.parse('$base/site-login/$encoded').replace(fragment: token),
      expiresAt: expiry,
    );
  }

  Future<SitePluginLoginPoll> pollSitePluginBrowserLogin(
      String pluginId, String flowId) async {
    final plugin = Uri.encodeComponent(pluginId);
    final flow = Uri.encodeComponent(flowId);
    return SitePluginLoginPoll.fromJson(
        decodeBrowserLoginResponse(await _request(
      'GET',
      '/plugins/$plugin/account/login-browser/$flow',
      attempts: 1,
      timeout: const Duration(seconds: 20),
    )));
  }

  Future<void> cancelSitePluginBrowserLogin(
      String pluginId, String flowId) async {
    final plugin = Uri.encodeComponent(pluginId);
    final flow = Uri.encodeComponent(flowId);
    final response = await _request(
      'DELETE',
      '/plugins/$plugin/account/login-browser/$flow',
      timeout: const Duration(seconds: 20),
    );
    if (response.statusCode != 204) decodeBrowserLoginResponse(response);
  }

  Future<SitePluginLoginPoll> pollSitePluginLogin(
    String pluginId,
    String flowId,
  ) async {
    final encodedId = Uri.encodeComponent(pluginId);
    final encodedFlowId = Uri.encodeComponent(flowId);
    final payload = _decode(
      await _request(
        'GET',
        '/plugins/$encodedId/account/login-qrcode/$encodedFlowId',
      ),
    );
    return SitePluginLoginPoll.fromJson(_map(payload));
  }

  Future<SitePluginAccount> logoutSitePluginAccount(String pluginId) async {
    final encodedId = Uri.encodeComponent(pluginId);
    final payload =
        _decode(await _request('DELETE', '/plugins/$encodedId/account'));
    return SitePluginAccount.fromJson(_map(payload));
  }

  Future<SitePluginAccount> loginSitePluginWithCookies(
    String pluginId,
    String cookies,
  ) async {
    final encodedId = Uri.encodeComponent(pluginId);
    final payload = _decode(
      await _request(
        'POST',
        '/plugins/$encodedId/account/login-cookies',
        body: <String, dynamic>{'cookies': cookies},
      ),
    );
    return SitePluginAccount.fromJson(_map(payload));
  }

  Future<SitePluginBookshelfImportJob> startSitePluginBookshelfImport(
    String pluginId,
  ) async {
    final encodedId = Uri.encodeComponent(pluginId);
    final payload = _decode(
      await _request('POST', '/plugins/$encodedId/bookshelf/import-jobs'),
    );
    return SitePluginBookshelfImportJob.fromJson(_map(payload));
  }

  Future<SitePluginBookshelfImportJob> fetchSitePluginBookshelfImport(
    String pluginId,
    String jobId,
  ) async {
    final encodedId = Uri.encodeComponent(pluginId);
    final encodedJobId = Uri.encodeComponent(jobId);
    final payload = _decode(
      await _request(
        'GET',
        '/plugins/$encodedId/bookshelf/import-jobs/$encodedJobId',
      ),
    );
    return SitePluginBookshelfImportJob.fromJson(_map(payload));
  }

  Future<BookSource> saveSourceEnabled(String sourceId, bool enabled) async {
    final payload = _decode(
      await _request(
        'PUT',
        '/sources/${Uri.encodeComponent(sourceId)}/enabled',
        body: <String, dynamic>{'enabled': enabled},
      ),
    );
    return BookSource.fromJson(_map(payload));
  }

  Future<List<SourceSearchResult>> searchSources(String keyword,
      {List<String>? sourceIds}) async {
    final payload = _decode(
      await _request(
        'POST',
        '/sources/search',
        body: <String, dynamic>{
          'keyword': keyword,
          'sourceIds': sourceIds,
          'limit': 60
        },
      ),
    );
    return _list(payload).map(SourceSearchResult.fromJson).toList();
  }

  Future<List<SourceSearchResult>> searchBuiltinSite(
    String keyword, {
    required String sourceId,
    required String sourceName,
    required String sourceLanguage,
    int limit = 20,
  }) async {
    final payload = _decode(
      await _request(
        'POST',
        '/builtin-sites/search',
        body: <String, dynamic>{
          'sourceId': sourceId,
          'keyword': keyword,
          'limit': limit,
        },
      ),
    );
    return _list(payload).map((item) {
      final result = _map(item);
      return SourceSearchResult.fromJson(<String, dynamic>{
        ...result,
        'sourceId': sourceId,
        'sourceName': result['providerName'] as String? ?? sourceName,
        'sourceLanguage': sourceLanguage,
      });
    }).toList();
  }

  Future<SourceImportResult> importSourcesFromUrl(String url) async {
    final payload = _decode(await _request('POST', '/sources/import-url',
        body: <String, dynamic>{'url': url}));
    return SourceImportResult.fromJson(_map(payload));
  }

  Future<SourceImportResult> importSourcesFromText(String content) async {
    final payload = _decode(await _request('POST', '/sources/import-text',
        body: <String, dynamic>{'content': content}));
    return SourceImportResult.fromJson(_map(payload));
  }

  Future<List<BookTask>> fetchTasks() async {
    final payload = _decode(await _request('GET', '/tasks'));
    return _list(payload).map(BookTask.fromJson).toList();
  }

  Future<List<TaskPageResult>> fetchTaskPageResults(
    String taskId, {
    int after = 0,
  }) async {
    final payload = _decode(
      await _request('GET', '/tasks/$taskId/page-results?after=$after'),
    );
    return _list(payload).map(TaskPageResult.fromJson).toList();
  }

  Future<BookTask> enqueueTask(
      String bookId, String action, List<int> chapters) async {
    final payload = _decode(
      await _request(
        'POST',
        '/books/$bookId/chapters/$action',
        body: <String, dynamic>{'chapterIndexes': chapters},
      ),
    );
    return BookTask.fromJson(_map(payload));
  }

  Future<JsonMap> exportChapter({
    required String bookId,
    required int chapterIndex,
    required String format,
    required String targetPath,
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    final payload = _decode(
      await _request(
        'POST',
        '/books/$bookId/chapters/$chapterIndex/export',
        body: <String, dynamic>{
          'format': format,
        },
      ),
    );
    final result = _map(payload);
    await _downloadArtifact(result, targetPath, onProgress: onProgress);
    return <String, dynamic>{...result, 'localFilePath': targetPath};
  }

  Future<JsonMap> exportBook({
    required String bookId,
    required List<int> chapterIndexes,
    required String format,
    required String targetPath,
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    final payload = _decode(
      await _request(
        'POST',
        '/books/$bookId/export',
        body: <String, dynamic>{
          'format': format,
          'chapterIndexes': chapterIndexes,
        },
      ),
    );
    final result = _map(payload);
    await _downloadArtifact(result, targetPath, onProgress: onProgress);
    return <String, dynamic>{...result, 'localFilePath': targetPath};
  }

  Future<BookTask> retryTask(String taskId) async {
    final payload = _decode(await _request('POST', '/tasks/$taskId/retry'));
    return BookTask.fromJson(_map(payload));
  }

  Future<BookTask> controlTask(String taskId, String action) async {
    if (!const ['pause', 'resume', 'cancel'].contains(action)) {
      throw const ApiException('不支持的任务操作');
    }
    final payload =
        _decode(await _request('POST', '/tasks/$taskId/control/$action'));
    return BookTask.fromJson(_map(payload));
  }

  Future<List<LinkJob>> fetchLinkJobs(
      {int offset = 0, bool activeOnly = false}) async {
    final payload = _decode(await _request('GET', '/link-jobs', query: {
      'limit': 50,
      'offset': offset,
      if (activeOnly) 'activeOnly': true
    }));
    return _list(payload).map(LinkJob.fromJson).toList();
  }

  Future<LinkJob> retryLinkJob(String jobId) async {
    final payload = _decode(await _request('POST', '/link-jobs/$jobId/retry'));
    return LinkJob.fromJson(_map(payload));
  }

  Future<TranslationSettings> fetchSettings() async {
    final payload = _decode(await _request('GET', '/settings'));
    return TranslationSettings.fromJson(_map(payload));
  }

  Future<TranslationSettings> saveSettings(TranslationSettings settings) async {
    final payload =
        _decode(await _request('PUT', '/settings', body: settings.toJson()));
    return TranslationSettings.fromJson(_map(payload));
  }

  String resolveUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty ||
        trimmed.startsWith('http://') ||
        trimmed.startsWith('https://')) {
      return trimmed;
    }
    return '${_baseUrl().replaceAll(RegExp(r'/+$'), '')}$_apiPrefix/${trimmed.replaceFirst(RegExp(r'^/+'), '')}';
  }

  Map<String, String> headersForUrl(String value) {
    final resolved = Uri.parse(resolveUrl(value));
    final backendBase = _baseUrl().replaceAll(RegExp(r'/+$'), '');
    final backend = Uri.parse(backendBase);
    final apiRoot = Uri.parse('$backendBase$_apiPrefix/');
    final sameOrigin = resolved.scheme == backend.scheme &&
        resolved.host == backend.host &&
        resolved.port == backend.port &&
        resolved.path.startsWith(apiRoot.path);
    return sameOrigin ? _headers() : const <String, String>{};
  }

  Future<List<int>> fetchOfflineImage(String url,
      {int maximumBytes = 16 * 1024 * 1024}) async {
    if (maximumBytes <= 0 || maximumBytes > 64 * 1024 * 1024) {
      throw const ApiException('离线图片大小限制无效');
    }
    final current = captureContextGuard();
    final backend = Uri.parse(_baseUrl().replaceAll(RegExp(r'/+$'), ''));
    final root = Uri.parse('$backend$_apiPrefix/books/');
    final uri = Uri.tryParse(resolveUrl(url));
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.scheme != backend.scheme ||
        uri.host != backend.host ||
        uri.port != backend.port ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.path.startsWith(root.path)) {
      throw const ApiException('仅可保存当前后端的书籍图片');
    }
    final tail = uri.path.substring(root.path.length).split('/');
    if (tail.length < 3 ||
        tail[1] != 'assets' ||
        uri.pathSegments.any((part) =>
            part.isEmpty ||
            part == '.' ||
            part == '..' ||
            part.contains('\\') ||
            part.contains('/'))) {
      throw const ApiException('离线图片路径无效');
    }
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers.addAll(_headers());
    final watch = Stopwatch()..start();
    StreamIterator<List<int>>? iterator;
    try {
      final response =
          await _client.send(request).timeout(const Duration(seconds: 20));
      iterator = StreamIterator(response.stream);
      if (!current()) throw const ApiException('连接已切换，图片保存已停止');
      if (response.statusCode != 200) {
        if (response.statusCode == 401 && _userToken().isNotEmpty) {
          _onUserSessionExpired?.call();
        }
        throw ApiException('无法获取离线图片，请确认登录和章节下载状态',
            statusCode: response.statusCode);
      }
      if ((response.contentLength ?? 0) > maximumBytes) {
        throw const ApiException('单张图片超过离线缓存大小限制');
      }
      final bytes = BytesBuilder(copy: false);
      while (true) {
        final remaining = const Duration(seconds: 60) - watch.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('offline image timeout');
        }
        if (!await iterator.moveNext().timeout(remaining)) break;
        if (!current()) throw const ApiException('连接已切换，图片保存已停止');
        if (bytes.length + iterator.current.length > maximumBytes) {
          throw const ApiException('单张图片超过离线缓存大小限制');
        }
        bytes.add(iterator.current);
      }
      if (!current()) throw const ApiException('连接已切换，图片保存已停止');
      if (bytes.isEmpty ||
          (response.contentLength != null &&
              response.contentLength != bytes.length)) {
        throw const ApiException('图片下载不完整，请重试');
      }
      return bytes.takeBytes();
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException('离线图片下载失败，请检查连接后重试');
    } finally {
      await iterator?.cancel();
    }
  }

  Future<List<BackupArtifact>> fetchBackups() async {
    return _list(_decode(await _request('GET', '/backups')))
        .map(BackupArtifact.fromJson)
        .toList();
  }

  Future<BackupArtifact> createBackup() async {
    return BackupArtifact.fromJson(_map(_decode(await _request(
      'POST',
      '/backups',
      body: {'acknowledgeSensitiveData': true},
      attempts: 1,
      timeout: const Duration(minutes: 30),
    ))));
  }

  Future<BackupInspection> inspectBackup({required String filePath}) async {
    final request = http.MultipartRequest('POST', _uri('/backups/inspect'))
      ..headers.addAll(_headers())
      ..fields['mode'] = 'replace'
      ..followRedirects = false;
    request.files.add(await http.MultipartFile.fromPath('file', filePath));
    final streamed =
        await _client.send(request).timeout(const Duration(minutes: 30));
    return BackupInspection.fromJson(
        _map(_decode(await http.Response.fromStream(streamed))));
  }

  Future<void> restoreBackup(BackupInspection inspection) async {
    _decode(await _request('POST', '/backups/restore',
        body: {
          'restoreId': inspection.restoreId,
          'confirmationToken': inspection.confirmationToken,
        },
        attempts: 1,
        timeout: const Duration(minutes: 30)));
  }

  Future<void> downloadBackupToFile({
    required BackupArtifact artifact,
    required String targetPath,
  }) async {
    await downloadUrlToFile(
      '/backups/${Uri.encodeComponent(artifact.id)}/download',
      targetPath,
      method: 'POST',
      expectedSha256: artifact.sha256,
    );
  }

  Future<void> downloadUrlToFile(
    String sourceUrl,
    String targetPath, {
    void Function(int receivedBytes, int totalBytes)? onProgress,
    Future<void>? abortTrigger,
    String method = 'GET',
    String? expectedSha256,
  }) async {
    if (method != 'GET' && method != 'POST') {
      throw ArgumentError.value(method, 'method');
    }
    final resolvedUrl = resolveUrl(sourceUrl);
    if (resolvedUrl.isEmpty) {
      throw const ApiException('下载地址为空');
    }
    final target = File(targetPath);
    final temporary = File('$targetPath.qingjuan-part');
    final backup = File('$targetPath.qingjuan-backup');
    await temporary.parent.create(recursive: true);
    if (!await target.exists() && await backup.exists()) {
      await backup.rename(target.path);
    } else if (await target.exists() && await backup.exists()) {
      await _tryDeleteDownloadBackup(backup);
    }
    try {
      final request = http.AbortableRequest(
        method,
        Uri.parse(resolvedUrl),
        abortTrigger: abortTrigger,
      )..headers.addAll(headersForUrl(sourceUrl));
      if (method == 'POST') request.followRedirects = false;
      final response =
          await _client.send(request).timeout(const Duration(minutes: 5));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final decoded = await http.Response.fromStream(response);
        _decode(decoded);
      }
      final sink = temporary.openWrite();
      final totalBytes = response.contentLength ?? 0;
      var receivedBytes = 0;
      try {
        await for (final chunk
            in response.stream.timeout(const Duration(minutes: 5))) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          onProgress?.call(receivedBytes, totalBytes);
        }
      } finally {
        await sink.close();
      }

      if (expectedSha256 != null) {
        final actual =
            (await crypto.sha256.bind(temporary.openRead()).first).toString();
        if (actual != expectedSha256.toLowerCase()) {
          throw const ApiException('备份校验失败，原文件已保留，请重新下载');
        }
      }

      if (await backup.exists()) await _deleteDownloadBackup(backup);
      var movedExisting = false;
      try {
        if (await target.exists()) {
          await target.rename(backup.path);
          movedExisting = true;
        }
        await temporary.rename(target.path);
        if (movedExisting && await backup.exists()) {
          await _tryDeleteDownloadBackup(backup);
        }
      } catch (_) {
        if (movedExisting && await backup.exists() && !await target.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<void> _tryDeleteDownloadBackup(File backup) async {
    try {
      await _deleteDownloadBackup(backup);
    } on FileSystemException {
      // The target is already complete. Keep the backup for crash recovery
      // instead of reporting a successful download as failed.
    }
  }

  Future<void> _downloadArtifact(
    JsonMap artifact,
    String targetPath, {
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    final downloadUrl = artifact['downloadUrl'] as String? ?? '';
    if (downloadUrl.isEmpty) {
      throw const ApiException('后端未返回导出下载地址');
    }
    await downloadUrlToFile(
      downloadUrl,
      targetPath,
      onProgress: onProgress,
    );
  }

  void close() => _client.close();
}
