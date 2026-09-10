import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/models/book_import_source.dart';

void main() {
  test('album number becomes a canonical manga import', () {
    expect(bookImportSourceError(' 00123456 '), isNull);
    expect(bookImportSourcePayload(' 00123456 ', '长小说'), <String, dynamic>{
      'sourceUrl': 'https://18comic.vip/album/123456/',
      'albumId': '123456',
      'bookKind': '漫画',
    });
  });

  test('invalid numbers and non HTTP inputs are rejected', () {
    for (final value in [
      '',
      '0',
      '000',
      '-1',
      '12.3',
      '１２３',
      'file:///tmp/book',
      'abc'
    ]) {
      expect(bookImportSourceError(value), isNotNull, reason: value);
      expect(bookImportSourceError(value, albumOnly: true), isNotNull);
    }
    expect(bookImportSourceError('https://example.com/book/1'), isNull);
    expect(bookImportSourceError('https://example.com/book/1', albumOnly: true),
        isNotNull);
  });

  test('known album links resolve to manga without rewriting other links', () {
    expect(isComic18Source('https://18comic.vip/album/123456/'), isTrue);
    expect(isComic18Source('https://18comic.vip.evil.test/album/123456/'),
        isFalse);
    expect(
        bookImportSourcePayload('https://example.com/book/1', '长小说'),
        <String, dynamic>{
          'sourceUrl': 'https://example.com/book/1',
          'bookKind': '长小说',
        });
  });
}
