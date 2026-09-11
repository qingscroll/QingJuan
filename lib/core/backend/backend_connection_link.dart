import 'backend_url_validator.dart';

/// Versioned connection information; account sessions are never shared.
class BackendConnectionLink {
  const BackendConnectionLink({required this.url, required this.token});

  final String url;
  final String token;

  String encode() {
    _validate(url, token);
    return Uri(
      scheme: 'qingjuan',
      host: 'connect',
      fragment:
          Uri(queryParameters: {'v': '1', 'url': url, 'token': token}).query,
    ).toString();
  }

  factory BackendConnectionLink.parse(String value) {
    // Reject unrelated QR codes and ambiguous fields before making any request.
    if (value.length > 8192) throw const FormatException('连接链接过长');
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'qingjuan' ||
        uri.host != 'connect' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        !uri.hasFragment) {
      throw const FormatException('请扫描青卷设置中生成的连接二维码');
    }
    final fields = Uri.splitQueryString(uri.fragment);
    final allFields = Uri(query: uri.fragment).queryParametersAll;
    if (fields.length != 3 ||
        fields['v'] != '1' ||
        allFields.values.any((values) => values.length != 1)) {
      throw const FormatException('连接链接版本或格式不受支持');
    }
    final url = (fields['url'] ?? '').trim().replaceAll(RegExp(r'/+$'), '');
    final token = fields['token'] ?? '';
    _validate(url, token);
    return BackendConnectionLink(url: url, token: token);
  }

  static void _validate(String url, String token) {
    validateBackendUrl(url);
    if (url.length > 2048 ||
        token.isEmpty ||
        token.length > 1024 ||
        token.contains(RegExp(r'\s|[\x00-\x1f\x7f]'))) {
      throw const FormatException('连接链接中的地址或密钥无效');
    }
  }
}
