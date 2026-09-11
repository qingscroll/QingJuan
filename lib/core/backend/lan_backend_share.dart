import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'backend_connection_link.dart';
import 'backend_url_validator.dart';

class LanAddress {
  const LanAddress(this.name, this.address);
  final String name;
  final String address;
  String get label => '$name · $address';
}

/// An opt-in, authenticated bridge to the fixed Windows loopback backend.
/// It owns its listener and connections; stopping invalidates every issued link.
class LanBackendShare extends ChangeNotifier {
  HttpServer? _server;
  HttpClient? _client;
  BackendConnectionLink? _connection;
  int _generation = 0;
  int _activeRequests = 0;

  BackendConnectionLink? get connection => _connection;
  bool get isSharing => _server != null;

  static Future<List<LanAddress>> discoverAddresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final addresses = <LanAddress>[
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (isPrivateBackendHost(address.address))
            LanAddress(interface.name, address.address),
    ];
    // Prefer physical adapters, while retaining VPN/virtual adapters for selection.
    bool virtual(LanAddress a) => RegExp(
          r'vethernet|virtual|vmware|wsl|docker|tailscale|vpn',
          caseSensitive: false,
        ).hasMatch(a.name);
    addresses.sort((a, b) {
      final order = (virtual(a) ? 1 : 0).compareTo(virtual(b) ? 1 : 0);
      return order != 0 ? order : a.label.compareTo(b.label);
    });
    return addresses;
  }

  Future<BackendConnectionLink> start({
    required String address,
    int port = 19454,
    @visibleForTesting Uri? upstream,
  }) async {
    final ip = InternetAddress.tryParse(address);
    if (ip == null ||
        ip.type != InternetAddressType.IPv4 ||
        !isPrivateBackendHost(address)) {
      throw const FormatException('请选择可用的局域网 IPv4 地址');
    }
    final target = upstream ?? Uri.parse('http://127.0.0.1:19453');
    if (target.scheme != 'http' ||
        target.host != '127.0.0.1' ||
        target.path.isNotEmpty ||
        target.hasQuery ||
        target.hasFragment ||
        target.userInfo.isNotEmpty) {
      throw const FormatException('局域网共享仅支持本机后端');
    }
    final generation = ++_generation;
    await _closeConnections();
    if (generation != _generation) {
      throw StateError('共享已取消，请重新生成二维码');
    }
    final server = await HttpServer.bind(ip, port);
    if (generation != _generation) {
      await server.close(force: true);
      throw StateError('共享已取消，请重新生成二维码');
    }
    final random = Random.secure();
    final token =
        base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)))
            .replaceAll('=', '');
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 5);
    client.findProxy = (_) => 'DIRECT';
    _server = server;
    _client = client;
    _connection = BackendConnectionLink(
        url: 'http://$address:${server.port}', token: token);
    server.idleTimeout = const Duration(seconds: 15);
    server
        .listen((request) => unawaited(_handle(request, client, target, token)),
            onError: (Object _) {
      if (generation == _generation) unawaited(stop());
    });
    notifyListeners();
    return _connection!;
  }

  Future<void> stop() async {
    ++_generation;
    await _closeConnections();
  }

  Future<void> _closeConnections() async {
    final server = _server;
    final client = _client;
    _server = null;
    _client = null;
    _connection = null;
    if (server != null) notifyListeners();
    client?.close(force: true);
    await server?.close(force: true);
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }

  Future<void> _handle(
      HttpRequest request, HttpClient client, Uri target, String token) async {
    final response = request.response;
    var counted = false;
    try {
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      final peer = request.connectionInfo?.remoteAddress;
      if (peer == null || !isPrivateBackendHost(peer.address)) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (!_matches(
          request.headers.value(HttpHeaders.authorizationHeader) ?? '',
          'Bearer $token')) {
        response.statusCode = HttpStatus.unauthorized;
        response.write('{"detail":"连接已失效，请重新扫描 PC 二维码"}');
        return;
      }
      final path = request.uri.path;
      if (!path.startsWith('/api/v1/') ||
          path.contains('\\') ||
          path.split('/').any((part) => part == '..' || part == '.') ||
          !{'GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD'}
              .contains(request.method)) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      if (_activeRequests >= 64) {
        response.statusCode = HttpStatus.serviceUnavailable;
        return;
      }
      _activeRequests++;
      counted = true;
      // Never forward a caller-controlled host, cookie, user session or URL origin.
      final outgoing = await client.openUrl(
          request.method,
          target.replace(
              path: path,
              query: request.uri.hasQuery ? request.uri.query : null));
      outgoing.followRedirects = false;
      for (final header in [
        'content-type',
        'accept',
        'range',
        'if-range',
        'if-none-match',
        'idempotency-key'
      ]) {
        final value = request.headers.value(header);
        if (value != null) outgoing.headers.set(header, value);
      }
      outgoing.headers.set('X-QingJuan-Local-Request', '1');
      outgoing.contentLength = request.contentLength;
      await outgoing.addStream(request).timeout(const Duration(minutes: 2));
      final incoming =
          await outgoing.close().timeout(const Duration(minutes: 2));
      if (incoming.isRedirect) {
        await incoming.drain<void>();
        response.statusCode = HttpStatus.badGateway;
        return;
      }
      response.statusCode = incoming.statusCode;
      for (final header in [
        'content-type',
        'content-disposition',
        'content-range',
        'accept-ranges',
        'etag',
        'last-modified',
        'content-encoding'
      ]) {
        final value = incoming.headers.value(header);
        if (value != null) response.headers.set(header, value);
      }
      if (path == '/api/v1/meta' && incoming.statusCode == 200) {
        final meta = jsonDecode(await utf8.decoder.bind(incoming).join())
            as Map<String, dynamic>;
        if (meta['service'] != 'qingjuan-backend' ||
            meta['apiVersion'] != '1') {
          response.statusCode = HttpStatus.badGateway;
          return;
        }
        meta['capabilities'] = <String, dynamic>{
          ...?meta['capabilities'] as Map<String, dynamic>?,
          'desktopSharing': true,
        };
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(meta));
      } else {
        await response.addStream(incoming).timeout(const Duration(minutes: 2));
      }
    } on Object {
      // Do not expose upstream exceptions, paths or connection secrets to peers.
      try {
        response.statusCode = HttpStatus.badGateway;
      } on StateError {
        // A streamed response may already have sent its headers.
      }
    } finally {
      if (counted) _activeRequests--;
      try {
        await response.close();
      } on Object {
        // The peer can disconnect or the owner can stop sharing mid-request.
      }
    }
  }

  static bool _matches(String actual, String expected) {
    var difference = actual.length ^ expected.length;
    for (var i = 0; i < expected.length; i++) {
      difference |= (i < actual.length ? actual.codeUnitAt(i) : 0) ^
          expected.codeUnitAt(i);
    }
    return difference == 0;
  }
}
