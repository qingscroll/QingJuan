import 'dart:io';

void validateBackendUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
    throw const FormatException('FastAPI 地址格式无效');
  }
  if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
    throw const FormatException('FastAPI 地址不能包含账号、查询参数或片段');
  }
  if (_isLoopbackOrUnspecifiedHost(uri.host)) {
    throw const FormatException('客户端不能使用回环或未指定地址');
  }
  if (uri.scheme == 'https') return;
  if (uri.scheme == 'http' && isPrivateBackendHost(uri.host)) return;
  throw const FormatException('Linux 后端必须使用 HTTPS；私有网络 IP 可使用 HTTP');
}

bool _isLoopbackOrUnspecifiedHost(String host) {
  final normalized = host.toLowerCase();
  if (normalized == 'localhost' ||
      normalized == '::1' ||
      normalized == '::' ||
      normalized == '0.0.0.0') {
    return true;
  }
  final parts = normalized.split('.').map(int.tryParse).toList();
  return parts.length == 4 && parts[0] == 127;
}

bool isPrivateBackendHost(String host) {
  final normalized = host.toLowerCase();
  final address = InternetAddress.tryParse(normalized);
  if (address == null) return false;
  if (address.type == InternetAddressType.IPv6) {
    final bytes = address.rawAddress;
    return (bytes[0] & 0xfe) == 0xfc ||
        (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80);
  }
  final parts = normalized.split('.').map(int.tryParse).toList();
  if (parts.length != 4 ||
      parts.any((part) => part == null || part < 0 || part > 255)) {
    return false;
  }
  final first = parts[0]!;
  final second = parts[1]!;
  return first == 10 ||
      (first == 192 && second == 168) ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 100 && second >= 64 && second <= 127);
}
