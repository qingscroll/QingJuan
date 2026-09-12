import 'book.dart';

class DiscoverySite {
  const DiscoverySite({
    required this.site,
    required this.siteName,
    this.content = 'novel',
    this.homepage = '',
    this.description = '',
    this.requiresLogin = false,
    this.enabled = true,
    this.channelCount = 0,
    this.channels = const [],
  });

  factory DiscoverySite.fromJson(JsonMap json) => DiscoverySite(
        site: _text(json, 'site'),
        siteName: _text(json, 'site_name'),
        content: _text(json, 'content', 'novel'),
        homepage: _text(json, 'homepage'),
        description: _text(json, 'description'),
        requiresLogin: _flag(json, 'requires_login'),
        enabled: _flag(json, 'enabled', true),
        channelCount: _integer(json, 'channel_count'),
        channels: _objects(json['channels'], DiscoveryChannel.fromJson),
      );

  final String site;
  final String siteName;
  final String content;
  final String homepage;
  final String description;
  final bool requiresLogin;
  final bool enabled;
  final int channelCount;
  final List<DiscoveryChannel> channels;
}

class DiscoveryChannel {
  const DiscoveryChannel({
    required this.site,
    required this.key,
    required this.name,
    required this.kind,
    this.group = '',
    this.description = '',
    this.pageable = true,
    this.params = const {},
  });

  factory DiscoveryChannel.fromJson(JsonMap json) => DiscoveryChannel(
        site: _text(json, 'site'),
        key: _text(json, 'key'),
        name: _text(json, 'name'),
        kind: _text(json, 'kind'),
        group: _text(json, 'group'),
        description: _text(json, 'description'),
        pageable: _flag(json, 'pageable', true),
        params: _object(json['params']),
      );

  final String site;
  final String key;
  final String name;
  final String kind;
  final String group;
  final String description;
  final bool pageable;
  final JsonMap params;
}

class DiscoveryBook {
  const DiscoveryBook({
    required this.site,
    this.siteName = '',
    this.channel = '',
    this.channelName = '',
    this.kind = 'rank',
    this.rank,
    this.bookId = '',
    this.title = '',
    this.author = '',
    this.cover = '',
    this.intro = '',
    this.category = '',
    this.status = '',
    this.wordCount = '',
    this.score = '',
    this.url = '',
    this.extra = const {},
  });

  factory DiscoveryBook.fromJson(JsonMap json) => DiscoveryBook(
        site: _text(json, 'site'),
        siteName: _text(json, 'site_name'),
        channel: _text(json, 'channel'),
        channelName: _text(json, 'channel_name'),
        kind: _text(json, 'kind', 'rank'),
        rank: json['rank'] is int ? json['rank'] as int : null,
        bookId: _text(json, 'book_id'),
        title: _text(json, 'title'),
        author: _text(json, 'author'),
        cover: _text(json, 'cover'),
        intro: _text(json, 'intro'),
        category: _text(json, 'category'),
        status: _text(json, 'status'),
        wordCount: _text(json, 'word_count'),
        score: _text(json, 'score'),
        url: _text(json, 'url'),
        extra: _object(json['extra']),
      );

  JsonMap toImportPayload(DiscoverySite source) => {
        'sourceUrl': url,
        'bookKind': source.content == 'comic' ? '漫画' : '长小说',
        'language':
            const {'kakuyomu', 'yanmaga'}.contains(source.site) ? '日文' : '中文',
        'needTranslation': false,
        'title': title,
        'synopsis': intro,
        'cover': cover,
        'sourceId': '',
        'downloadMode': 'on_demand',
      };

  final String site;
  final String siteName;
  final String channel;
  final String channelName;
  final String kind;
  final int? rank;
  final String bookId;
  final String title;
  final String author;
  final String cover;
  final String intro;
  final String category;
  final String status;
  final String wordCount;
  final String score;
  final String url;
  final JsonMap extra;
}

class DiscoveryResult {
  const DiscoveryResult({
    required this.site,
    required this.channel,
    this.siteName = '',
    this.channelName = '',
    this.kind = 'rank',
    this.group = '',
    this.page = 1,
    this.limit = 20,
    this.count = 0,
    this.hasMore = false,
    this.cached = false,
    this.elapsedMs = 0,
    this.error,
    this.items = const [],
  });

  factory DiscoveryResult.fromJson(JsonMap json) => DiscoveryResult(
        site: _text(json, 'site'),
        channel: _text(json, 'channel'),
        siteName: _text(json, 'site_name'),
        channelName: _text(json, 'channel_name'),
        kind: _text(json, 'kind', 'rank'),
        group: _text(json, 'group'),
        page: _integer(json, 'page', 1),
        limit: _integer(json, 'limit', 20),
        count: _integer(json, 'count'),
        hasMore: _flag(json, 'has_more'),
        cached: _flag(json, 'cached'),
        elapsedMs: _integer(json, 'elapsed_ms'),
        error: json['error'] is String ? json['error'] as String : null,
        items: _objects(json['items'], DiscoveryBook.fromJson),
      );

  final String site;
  final String siteName;
  final String channel;
  final String channelName;
  final String kind;
  final String group;
  final int page;
  final int limit;
  final int count;
  final bool hasMore;
  final bool cached;
  final int elapsedMs;
  final String? error;
  final List<DiscoveryBook> items;
}

String _text(JsonMap json, String key, [String fallback = '']) =>
    json[key] is String ? json[key] as String : fallback;

int _integer(JsonMap json, String key, [int fallback = 0]) =>
    json[key] is int ? json[key] as int : fallback;

bool _flag(JsonMap json, String key, [bool fallback = false]) =>
    json[key] is bool ? json[key] as bool : fallback;

JsonMap _object(Object? value) =>
    value is JsonMap ? Map.unmodifiable(value) : const {};

List<T> _objects<T>(Object? value, T Function(JsonMap) parse) => value is List
    ? List.unmodifiable(value.whereType<JsonMap>().map(parse))
    : const [];
