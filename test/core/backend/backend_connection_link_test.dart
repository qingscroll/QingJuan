import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/backend/backend_connection_link.dart';

void main() {
  test(
      'connection link round trips LAN and proxy paths without exposing a query',
      () {
    for (final url in [
      'http://192.168.1.20:19454',
      'https://books.example/proxy'
    ]) {
      final link = BackendConnectionLink(url: url, token: 'test+/=&?#密钥');
      final encoded = link.encode();
      final decoded = BackendConnectionLink.parse(encoded);
      expect(decoded.url, url);
      expect(decoded.token, link.token);
      expect(Uri.parse(encoded).hasQuery, isFalse);
    }
  });

  test('unrelated, ambiguous, oversized and unsafe links are rejected', () {
    final invalid = [
      'https://example.com',
      'qingjuan://other#v=1&url=x&token=y',
      'qingjuan://connect?v=1&url=x&token=y',
      'qingjuan://connect#v=2&url=https%3A%2F%2Fexample.com&token=x',
      'qingjuan://connect#v=1&url=https%3A%2F%2Fexample.com&token=x&token=y',
      'qingjuan://connect#v=1&url=https%3A%2F%2Fexample.com&token=',
      'qingjuan://connect#v=1&url=https%3A%2F%2Fexample.com&token=x%0Ay',
      'x' * 8193,
      for (final url in [
        'http://127.0.0.1:19453',
        'http://0.0.0.0',
        'http://8.8.8.8',
        'https://user:password@example.com',
        'https://example.com?apiKey=secret',
        'file:///tmp/data'
      ])
        'qingjuan://connect#${Uri(queryParameters: {
              'v': '1',
              'url': url,
              'token': 'x'
            }).query}',
    ];
    for (final value in invalid) {
      expect(() => BackendConnectionLink.parse(value), throwsFormatException);
    }
  });
}
