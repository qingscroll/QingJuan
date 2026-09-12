import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/models/discovery.dart';

void main() {
  test('site metadata and channel defaults match the discovery contract', () {
    final site = DiscoverySite.fromJson({
      'site': 'sample',
      'site_name': '示例站点',
      'content': 'comic',
      'requires_login': true,
      'enabled': false,
      'channel_count': 1,
      'channels': [
        {
          'site': 'sample',
          'key': 'monthly',
          'name': '月票榜',
          'kind': 'rank',
          'group': '男频',
          'params': {'period': 'month'},
        },
      ],
    });
    expect(site.siteName, '示例站点');
    expect(site.content, 'comic');
    expect(site.requiresLogin, isTrue);
    expect(site.enabled, isFalse);
    expect(site.channels.single.kind, 'rank');
    expect(site.channels.single.group, '男频');
    expect(site.channels.single.pageable, isTrue);
    expect(site.channels.single.params, {'period': 'month'});
    expect(() => site.channels.clear(), throwsUnsupportedError);
  });

  test('results preserve ordering, scores and errors without inventing rank',
      () {
    final result = DiscoveryResult.fromJson({
      'site': 'sample',
      'channel': 'home',
      'kind': 'recommend',
      'has_more': true,
      'cached': true,
      'elapsed_ms': 42,
      'error': '部分内容暂不可用',
      'items': [
        {
          'site': 'sample',
          'title': '作品一',
          'rank': null,
          'word_count': '12万字',
          'score': '982票',
          'book_id': 'book-one',
          'url': 'https://example.com/book/one',
        },
        {'site': 'sample', 'title': '作品二', 'rank': 2},
      ],
    });
    expect(result.page, 1);
    expect(result.limit, 20);
    expect(result.kind, 'recommend');
    expect(result.hasMore, isTrue);
    expect(result.cached, isTrue);
    expect(result.elapsedMs, 42);
    expect(result.error, '部分内容暂不可用');
    expect(result.items.map((book) => book.title), ['作品一', '作品二']);
    expect(result.items.first.rank, isNull);
    expect(result.items.last.rank, 2);
    expect(result.items.first.wordCount, '12万字');
    expect(result.items.first.score, '982票');
    expect(() => result.items.clear(), throwsUnsupportedError);
  });

  test('malformed optional fields fall back to safe typed defaults', () {
    final result = DiscoveryResult.fromJson({
      'site': 'sample',
      'channel': 'home',
      'items': ['bad', null],
      'page': 'invalid',
      'error': {'detail': 'internal'},
      'has_more': 'true',
    });
    expect(result.page, 1);
    expect(result.hasMore, isFalse);
    expect(result.items, isEmpty);
    expect(result.error, isNull);
    final book =
        DiscoveryBook.fromJson({'site': 'sample', 'rank': '4', 'cover': false});
    expect(book.rank, isNull);
    expect(book.cover, isEmpty);
  });

  test(
      'import reuses normalized URL payload with correct work type and language',
      () {
    const book = DiscoveryBook(
        site: 'yanmaga',
        title: '漫画',
        intro: '简介',
        url: 'https://yanmaga.jp/comics/example');
    final payload = book.toImportPayload(const DiscoverySite(
        site: 'yanmaga', siteName: 'Yanmaga', content: 'comic'));
    expect(payload, {
      'sourceUrl': 'https://yanmaga.jp/comics/example',
      'bookKind': '漫画',
      'language': '日文',
      'needTranslation': false,
      'title': '漫画',
      'synopsis': '简介',
      'cover': '',
      'sourceId': '',
      'downloadMode': 'on_demand',
    });
    expect(
        book.toImportPayload(const DiscoverySite(
            site: 'yoyomanga', siteName: 'YY漫画', content: 'comic'))['language'],
        '中文');
    expect(
        book.toImportPayload(
            const DiscoverySite(site: 'qidian', siteName: '起点'))['bookKind'],
        '长小说');
  });
}
