import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_exception.dart';

/// Only reads public error fields; validation input may contain credentials.
Map<String, dynamic> decodeBrowserLoginResponse(http.Response response) {
  dynamic payload;
  try {
    payload = jsonDecode(utf8.decode(response.bodyBytes));
  } on FormatException {
    // Proxies can return HTML or invalid UTF-8 instead of an API response.
  }
  if (response.statusCode >= 200 && response.statusCode < 300) {
    if (payload is Map<String, dynamic>) return payload;
    throw const ApiException('登录响应无效，请重试');
  }
  String text(dynamic value) =>
      value is String && value.trim().length <= 300 ? value.trim() : '';
  final detail = payload is Map ? payload['detail'] : null;
  final message = detail is Map ? text(detail['msg']) : text(detail);
  final hint = detail is Map ? text(detail['hint']) : '';
  throw ApiException(
    message.isEmpty
        ? '登录请求失败（HTTP ${response.statusCode}），请稍后重试。'
        : [message, if (hint.isNotEmpty && hint != message) hint].join('\n'),
    statusCode: response.statusCode,
  );
}
