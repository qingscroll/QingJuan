import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/backend/backend_url_validator.dart';

void main() {
  test('accepts HTTPS and private-network HTTP backends', () {
    expect(() => validateBackendUrl('https://qingjuan.example.test'),
        returnsNormally);
    expect(
        () => validateBackendUrl('http://192.168.1.8:19453'), returnsNormally);
    expect(() => validateBackendUrl('http://100.100.10.20:19453'),
        returnsNormally);
    expect(() => validateBackendUrl('http://[fd7a:115c:a1e0::1]:19453'),
        returnsNormally);
  });

  test('rejects public HTTP, loopback and credential-bearing URLs', () {
    for (final host in ['fc-example.com', 'fd.example.com']) {
      expect(isPrivateBackendHost(host), isFalse);
      expect(() => validateBackendUrl('http://$host'), throwsFormatException);
    }
    expect(
      () => validateBackendUrl('http://qingjuan.example.test'),
      throwsFormatException,
    );
    expect(
      () => validateBackendUrl('http://127.0.0.1:19453'),
      throwsFormatException,
    );
    expect(
      () => validateBackendUrl('https://localhost:19453'),
      throwsFormatException,
    );
    expect(
      () => validateBackendUrl('https://user@qingjuan.example.test'),
      throwsFormatException,
    );
    expect(
      () => validateBackendUrl('https://qingjuan.example.test?token=secret'),
      throwsFormatException,
    );
  });
}
