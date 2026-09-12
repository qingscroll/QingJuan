import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/core/api/api_client.dart';
import 'package:qingjuan/core/api/api_exception.dart';
import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/models/book_metadata.dart';
import 'package:qingjuan/core/state/load_state.dart';
import 'package:qingjuan/features/library/book_metadata_controller.dart';
import 'package:qingjuan/features/library/library_controller.dart';

void main() {
  late _Api api;
  late LibraryController library;
  late BookMetadataController editor;
  setUp(() {
    api = _Api();
    library = LibraryController(api)..books = [_book('a'), _book('b')];
    editor = BookMetadataController(library, 'a');
  });
  tearDown(() {
    editor.dispose();
    library.dispose();
    api.close();
  });

  test(
      'filters include author and tags and preserve pinned priority across sorting',
      () {
    library.books = [
      _book('b', author: '作者乙', group: '分组', tags: ['奇幻'], state: 'finished'),
      _book('a', author: '作者甲', pinned: true),
      _book('c', group: '分组', tags: ['科幻'])
    ];
    library.setSort(LibrarySort.title);
    expect(library.filteredBooks.map((b) => b.id), ['a', 'b', 'c']);
    library.setQuery('作者乙');
    expect(library.filteredBooks.single.id, 'b');
    library.setQuery('');
    library.setOrganization(group: '分组', tag: '奇幻', readingState: 'finished');
    expect(library.filteredBooks.single.id, 'b');
    library.setOrganization(group: '');
    expect(library.filteredBooks.single.id, 'a');
    library.setOrganization(pinned: true);
    expect(library.filteredBooks.single.id, 'a');
    expect(library.groups, ['分组']);
    expect(library.tags.toSet(), {'奇幻', '科幻'});
    expect(() => library.filteredBooks.add(_book('x')), throwsUnsupportedError);
  });

  test(
      'metadata save wins over stale loads while retaining reader and download fields',
      () async {
    await editor.load();
    final old = Completer<List<Book>>();
    api.loadBooks = () => old.future;
    final loading = library.load();
    expect(await editor.save({'title': '新书名', 'pinned': true}), isTrue);
    old.complete([_book('a')]);
    await loading;
    final changed = library.books.first;
    expect(changed.title, '新书名');
    expect(changed.chapterCount, 18);
    expect(changed.lastReadPageIndex, 4);
    expect(changed.translated, isTrue);
    expect(changed.cover, 'cover.png');
    expect(changed.metadataRevision, 1);
    expect(api.lastPatch, {'title': '新书名', 'pinned': true});
    expect(api.expected, 0);
    expect(library.state, LoadState.ready);
  });

  test('failed save leaves loaded data and permits a revision-aware retry',
      () async {
    await editor.load();
    api.saveMetadata =
        () => Future.error(const ApiException('其他设备已修改', statusCode: 409));
    expect(await editor.save({'title': '草稿'}), isFalse);
    expect(editor.error, contains('其他设备已修改'));
    expect(editor.metadata!.title, '原标题');
    expect(editor.saving, isFalse);
    api.metadata = _metadata(revision: 2);
    await editor.load();
    api.saveMetadata = null;
    expect(await editor.save({'title': '新书名'}), isTrue);
    expect(api.expected, 2);
  });

  test(
      'session switch invalidates editor and ignores old fetch and save replies',
      () async {
    await editor.load();
    final pending = Completer<BookMetadata>();
    api.saveMetadata = () => pending.future;
    final saving = editor.save({'title': '旧账号'});
    library.setOrganization(group: '私有分组', pinned: true);
    library.resetForBackendSwitch();
    expect(editor.invalidated, isTrue);
    expect(editor.metadata, isNull);
    expect(library.hasOrganizationFilters, isFalse);
    pending.complete(_metadata(title: '旧账号'));
    expect(await saving, isFalse);
    expect(library.books, isEmpty);
    await editor.load();
    expect(editor.metadata, isNull);
    expect(await editor.save({'title': '错误重试'}), isFalse);
  });

  test('a delayed fetch cannot reveal metadata after account change', () async {
    final pending = Completer<BookMetadata>();
    api.loadMetadata = () => pending.future;
    final loading = editor.load();
    library.resetForBackendSwitch();
    pending.complete(_metadata());
    await loading;
    expect(editor.metadata, isNull);
    expect(editor.loading, isFalse);
  });

  test(
      'duplicate save is blocked and failed save releases an invalidated spinner',
      () async {
    await editor.load();
    final stale = Completer<List<Book>>();
    api.loadBooks = () => stale.future;
    final loading = library.load();
    final pending = Completer<BookMetadata>();
    api.saveMetadata = () => pending.future;
    final saving = editor.save({'title': '草稿'});
    expect(await editor.save({'title': '重复'}), isFalse);
    pending.completeError(const ApiException('网络失败'));
    expect(await saving, isFalse);
    stale.complete([_book('old')]);
    await loading;
    expect(library.state, LoadState.ready);
    expect(library.books.map((b) => b.id), ['a', 'b']);
  });
}

Book _book(String id,
        {String author = '',
        String? group,
        List<String> tags = const [],
        String state = 'unread',
        bool pinned = false}) =>
    Book(
        id: id,
        title: id,
        author: author,
        sourceUrl: '',
        kind: '长小说',
        language: '中文',
        status: '已下载',
        chapterCount: 18,
        translated: true,
        synopsis: '简介',
        lastReadChapterIndex: 2,
        lastReadPageIndex: 4,
        lastReadPageCount: 10,
        cover: 'cover.png',
        groupName: group,
        tags: tags,
        readingState: state,
        pinned: pinned);
BookMetadata _metadata({String title = '原标题', int revision = 0}) =>
    BookMetadata(
        bookId: 'a',
        title: title,
        author: '',
        synopsis: '简介',
        revision: revision);

class _Api extends ApiClient {
  _Api() : super(() => 'https://example.test');
  BookMetadata metadata = _metadata();
  Future<List<Book>> Function()? loadBooks;
  Future<BookMetadata> Function()? loadMetadata;
  Future<BookMetadata> Function()? saveMetadata;
  JsonMap? lastPatch;
  int? expected;
  @override
  Future<List<Book>> fetchBooks() async =>
      loadBooks != null ? loadBooks!() : [];
  @override
  Future<BookMetadata> fetchBookMetadata(String id) async =>
      loadMetadata != null ? loadMetadata!() : metadata;
  @override
  Future<BookMetadata> updateBookMetadata(String id,
      {required int expectedRevision, required JsonMap changes}) async {
    expected = expectedRevision;
    lastPatch = changes;
    return saveMetadata != null
        ? saveMetadata!()
        : _metadata(title: '新书名', revision: expectedRevision + 1);
  }
}
