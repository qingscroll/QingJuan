import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/api/api_exception.dart';
import 'package:qingjuan/core/models/backup.dart';

void main() {
  for (final corrupt in [false, true]) {
    test(
        'backup download authenticates POST and preserves old file on corrupt=$corrupt',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('qingjuan-backup-test-');
      addTearDown(() => directory.delete(recursive: true));
      final destination = File('${directory.path}/backup.zip');
      await destination.writeAsBytes([0, 1]);
      const valid = [1, 2, 3, 4];
      final api = ApiClient(() => 'http://127.0.0.1:19453',
          client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/backups/abc/download');
        expect(request.followRedirects, isFalse);
        expect(request.headers['X-QingJuan-Local-Request'], '1');
        return http.Response.bytes(corrupt ? [9] : valid, 200);
      }));
      addTearDown(api.close);
      final operation = api.downloadBackupToFile(
        artifact: BackupArtifact(
            id: 'abc',
            createdAt: '',
            appVersion: '',
            sizeBytes: valid.length,
            sha256: sha256.convert(valid).toString()),
        targetPath: destination.path,
      );
      if (corrupt) {
        await expectLater(operation, throwsA(isA<ApiException>()));
        expect(await destination.readAsBytes(), [0, 1]);
      } else {
        await operation;
        expect(await destination.readAsBytes(), valid);
      }
      expect(await File('${destination.path}.qingjuan-part').exists(), isFalse);
    });
  }
}
