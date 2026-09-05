import 'dart:convert';
import 'dart:math' as math;

enum MangaTextDirection {
  horizontal('h'),
  vertical('v');

  const MangaTextDirection(this.projectValue);

  final String projectValue;

  static MangaTextDirection fromProjectValue(
    Object? value, {
    MangaTextDirection fallback = MangaTextDirection.horizontal,
  }) {
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    if (normalized == 'v' ||
        normalized == 'vr' ||
        normalized.startsWith('vertical')) {
      return MangaTextDirection.vertical;
    }
    if (normalized == 'h' ||
        normalized == 'hr' ||
        normalized.startsWith('horizontal')) {
      return MangaTextDirection.horizontal;
    }
    return fallback;
  }
}

class MangaTextRegionBounds {
  const MangaTextRegionBounds({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  const MangaTextRegionBounds.fromLTRB(
    this.left,
    this.top,
    this.right,
    this.bottom,
  );

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  MangaTextRegionBounds normalized({
    int? imageWidth,
    int? imageHeight,
  }) {
    var normalizedLeft = math.min(left, right);
    var normalizedTop = math.min(top, bottom);
    var normalizedRight = math.max(left, right);
    var normalizedBottom = math.max(top, bottom);

    if (imageWidth != null && imageWidth > 0) {
      normalizedLeft = normalizedLeft.clamp(0.0, imageWidth.toDouble());
      normalizedRight = normalizedRight.clamp(0.0, imageWidth.toDouble());
    }
    if (imageHeight != null && imageHeight > 0) {
      normalizedTop = normalizedTop.clamp(0.0, imageHeight.toDouble());
      normalizedBottom = normalizedBottom.clamp(0.0, imageHeight.toDouble());
    }

    return MangaTextRegionBounds.fromLTRB(
      normalizedLeft,
      normalizedTop,
      normalizedRight,
      normalizedBottom,
    );
  }

  List<int> toProjectList() {
    final value = normalized();
    return <int>[
      value.left.floor(),
      value.top.floor(),
      value.right.ceil(),
      value.bottom.ceil(),
    ];
  }

  static MangaTextRegionBounds? fromProjectValue(Object? value) {
    if (value is! List || value.length < 4) {
      return null;
    }
    final coordinates = value
        .take(4)
        .map((item) => item is num ? item.toDouble() : double.tryParse('$item'))
        .toList(growable: false);
    if (coordinates.any((coordinate) => coordinate == null)) {
      return null;
    }
    return MangaTextRegionBounds.fromLTRB(
      coordinates[0]!,
      coordinates[1]!,
      coordinates[2]!,
      coordinates[3]!,
    ).normalized();
  }
}

class MangaTextEditorRegion {
  MangaTextEditorRegion._(this._raw, {required this.fallbackOrder});

  final Map<String, dynamic> _raw;
  final int fallbackOrder;

  Map<String, dynamic> get raw => _raw;

  int get order => _positiveInt(_raw['order']) ?? fallbackOrder;

  MangaTextRegionBounds? get bounds {
    for (final key in const <String>['bbox', 'body_bbox', 'safe_box']) {
      final parsed = MangaTextRegionBounds.fromProjectValue(_raw[key]);
      if (parsed != null) {
        return parsed;
      }
    }
    return _boundsFromLines(_raw['lines']);
  }

  MangaTextRegionBounds? get bbox => bounds;

  String get sourceText {
    for (final key in const <String>['source_text', 'text']) {
      final text = _stringValue(_raw[key]);
      if (text.isNotEmpty) {
        return text.replaceAll('[BR]', '\n');
      }
    }
    final texts = _raw['texts'];
    if (texts is List) {
      return texts
          .map(_stringValue)
          .where((text) => text.isNotEmpty)
          .join('\n')
          .replaceAll('[BR]', '\n');
    }
    return '';
  }

  String get translation {
    final translated = _stringValue(_raw['translation']);
    if (translated.isNotEmpty) {
      return translated.replaceAll('[BR]', '\n');
    }
    return _stringValue(_raw['translation_raw']).replaceAll('[BR]', '\n');
  }

  MangaTextDirection get direction {
    final regionBounds = bounds;
    final fallback =
        regionBounds != null && regionBounds.height > regionBounds.width * 1.15
            ? MangaTextDirection.vertical
            : MangaTextDirection.horizontal;
    return MangaTextDirection.fromProjectValue(
      _raw['direction'] ?? _raw['source_direction'],
      fallback: fallback,
    );
  }

  bool get isUntranslated {
    final translated = translation.trim();
    if (translated.isEmpty) {
      return true;
    }
    final source = sourceText.trim();
    return _containsJapaneseKana(source) &&
        _effectiveTextKey(source) == _effectiveTextKey(translated) &&
        _effectiveTextKey(source).isNotEmpty;
  }

  void updateSourceText(String value) {
    if (_raw.containsKey('source_text')) {
      _raw['source_text'] = value;
    }
    _raw['text'] = value;
    _raw['texts'] = value.isEmpty ? <String>[] : <String>[value];
  }

  void updateTranslation(String value) {
    _raw['translation'] = value;
    _raw['translation_raw'] = value;
    _raw.remove('translation_rich');
  }

  void updateDirection(MangaTextDirection value) {
    _raw['direction'] = value.projectValue;
  }
}

class MangaTextEditorProject {
  MangaTextEditorProject._({
    required Map<String, dynamic> document,
    required Map<String, dynamic> page,
    required this.imageKey,
  })  : _document = document,
        _page = page;

  factory MangaTextEditorProject.fromDocument(
    Map<String, dynamic> document, {
    String? sourcePath,
  }) {
    final copied = _deepCopyMap(document);
    final located = _locatePage(copied, sourcePath: sourcePath);
    return MangaTextEditorProject._(
      document: copied,
      page: located.page,
      imageKey: located.imageKey,
    );
  }

  final Map<String, dynamic> _document;
  final Map<String, dynamic> _page;

  /// Null when the supplied JSON is already a direct page object.
  final String? imageKey;

  Map<String, dynamic> get page => _page;

  int? get originalWidth => _positiveInt(_page['original_width']);
  int? get originalHeight => _positiveInt(_page['original_height']);

  List<MangaTextEditorRegion> get regions {
    final rawRegions = _rawRegions;
    final result = <MangaTextEditorRegion>[];
    for (var index = 0; index < rawRegions.length; index += 1) {
      final value = rawRegions[index];
      if (value is Map<String, dynamic>) {
        result.add(
          MangaTextEditorRegion._(value, fallbackOrder: index + 1),
        );
      } else if (value is Map) {
        final normalized = <String, dynamic>{
          for (final entry in value.entries) '${entry.key}': entry.value,
        };
        rawRegions[index] = normalized;
        result.add(
          MangaTextEditorRegion._(normalized, fallbackOrder: index + 1),
        );
      }
    }
    return result;
  }

  int get untranslatedCount =>
      regions.where((region) => region.isUntranslated).length;

  Map<String, dynamic> toDocument() => _deepCopyMap(_document);

  MangaTextEditorRegion addRegion(
    MangaTextRegionBounds bounds, {
    String sourceText = '',
    String translation = '',
    MangaTextDirection? direction,
  }) {
    final normalized = bounds.normalized(
      imageWidth: originalWidth,
      imageHeight: originalHeight,
    );
    final projectBounds = normalized.toProjectList();
    if (projectBounds[2] <= projectBounds[0] ||
        projectBounds[3] <= projectBounds[1]) {
      throw ArgumentError.value(bounds, 'bounds', '文字区域必须具有正宽高');
    }

    var maximumOrder = 0;
    for (final region in regions) {
      maximumOrder = math.max(maximumOrder, region.order);
    }
    final resolvedDirection = direction ??
        (normalized.height > normalized.width * 1.15
            ? MangaTextDirection.vertical
            : MangaTextDirection.horizontal);
    final fontSize = math.max(
      8,
      math.min(
          128, (math.min(normalized.width, normalized.height) * .72).round()),
    );
    final left = projectBounds[0];
    final top = projectBounds[1];
    final right = projectBounds[2];
    final bottom = projectBounds[3];
    final raw = <String, dynamic>{
      'order': maximumOrder + 1,
      'bbox': List<int>.from(projectBounds),
      'body_bbox': List<int>.from(projectBounds),
      'safe_box': List<int>.from(projectBounds),
      'lines': <List<List<int>>>[
        <List<int>>[
          <int>[left, top],
          <int>[right, top],
          <int>[right, bottom],
          <int>[left, bottom],
        ],
      ],
      'center': <double>[
        (left + right) / 2,
        (top + bottom) / 2,
      ],
      'source_text': sourceText,
      'text': sourceText,
      'texts': sourceText.isEmpty ? <String>[] : <String>[sourceText],
      'translation': translation,
      'translation_raw': translation,
      'direction': resolvedDirection.projectValue,
      'font_size': fontSize,
      'alignment': 'center',
    };
    _rawRegions.add(raw);
    return MangaTextEditorRegion._(
      raw,
      fallbackOrder: _rawRegions.length,
    );
  }

  bool removeRegion(MangaTextEditorRegion region) {
    final rawRegions = _rawRegions;
    final index =
        rawRegions.indexWhere((value) => identical(value, region._raw));
    if (index < 0) {
      return false;
    }
    rawRegions.removeAt(index);
    return true;
  }

  List<dynamic> get _rawRegions {
    final existing = _page['regions'];
    if (existing is List) {
      return existing;
    }
    final created = <dynamic>[];
    _page['regions'] = created;
    return created;
  }
}

class _LocatedProjectPage {
  const _LocatedProjectPage({required this.imageKey, required this.page});

  final String? imageKey;
  final Map<String, dynamic> page;
}

_LocatedProjectPage _locatePage(
  Map<String, dynamic> document, {
  String? sourcePath,
}) {
  if (document['regions'] is List) {
    return _LocatedProjectPage(imageKey: null, page: document);
  }

  final candidates = <MapEntry<String, Map<String, dynamic>>>[];
  for (final entry in document.entries) {
    final value = entry.value;
    if (value is Map<String, dynamic> && value['regions'] is List) {
      candidates.add(MapEntry<String, Map<String, dynamic>>(entry.key, value));
    } else if (value is Map && value['regions'] is List) {
      final normalized = <String, dynamic>{
        for (final child in value.entries) '${child.key}': child.value,
      };
      document[entry.key] = normalized;
      candidates.add(
        MapEntry<String, Map<String, dynamic>>(entry.key, normalized),
      );
    }
  }

  if (candidates.isEmpty) {
    throw const FormatException('漫画工程中没有包含 regions 的页面');
  }

  if (sourcePath != null && sourcePath.trim().isNotEmpty) {
    final target = _canonicalPath(sourcePath);
    for (final candidate in candidates) {
      if (_canonicalPath(candidate.key) == target) {
        return _LocatedProjectPage(
          imageKey: candidate.key,
          page: candidate.value,
        );
      }
    }

    final targetName = _pathName(target);
    final sameName = candidates
        .where((candidate) =>
            _pathName(_canonicalPath(candidate.key)) == targetName)
        .toList(growable: false);
    if (sameName.length == 1) {
      return _LocatedProjectPage(
        imageKey: sameName.single.key,
        page: sameName.single.value,
      );
    }
  }

  return _LocatedProjectPage(
    imageKey: candidates.first.key,
    page: candidates.first.value,
  );
}

Map<String, dynamic> _deepCopyMap(Map<String, dynamic> value) {
  final decoded = jsonDecode(jsonEncode(value));
  if (decoded is! Map) {
    throw const FormatException('漫画工程必须是 JSON 对象');
  }
  return <String, dynamic>{
    for (final entry in decoded.entries) '${entry.key}': entry.value,
  };
}

MangaTextRegionBounds? _boundsFromLines(Object? value) {
  if (value is! List) {
    return null;
  }
  final points = <List<num>>[];

  void visit(Object? item) {
    if (item is! List) {
      return;
    }
    if (item.length >= 2 && item[0] is num && item[1] is num) {
      points.add(<num>[item[0] as num, item[1] as num]);
      return;
    }
    for (final child in item) {
      visit(child);
    }
  }

  visit(value);
  if (points.isEmpty) {
    return null;
  }
  return MangaTextRegionBounds.fromLTRB(
    points.map((point) => point[0]).reduce(math.min).toDouble(),
    points.map((point) => point[1]).reduce(math.min).toDouble(),
    points.map((point) => point[0]).reduce(math.max).toDouble(),
    points.map((point) => point[1]).reduce(math.max).toDouble(),
  );
}

String _stringValue(Object? value) => value?.toString().trim() ?? '';

int? _positiveInt(Object? value) {
  final parsed = value is num ? value.toInt() : int.tryParse('$value');
  return parsed != null && parsed > 0 ? parsed : null;
}

bool _containsJapaneseKana(String value) =>
    RegExp(r'[\u3040-\u30ff\u31f0-\u31ff]').hasMatch(value);

String _effectiveTextKey(String value) {
  final result = StringBuffer();
  for (var rune in value.toLowerCase().runes) {
    if (rune >= 0xff10 && rune <= 0xff19) {
      rune -= 0xfee0;
    } else if (rune >= 0xff21 && rune <= 0xff3a) {
      rune -= 0xfee0;
    } else if (rune >= 0xff41 && rune <= 0xff5a) {
      rune -= 0xfee0;
    }
    final isAsciiAlphaNumeric =
        (rune >= 0x30 && rune <= 0x39) || (rune >= 0x61 && rune <= 0x7a);
    final isHiragana = rune >= 0x3041 && rune <= 0x309f;
    final isKatakana = (rune >= 0x30a1 && rune <= 0x30fa) ||
        (rune >= 0x31f0 && rune <= 0x31ff);
    final isCjk = (rune >= 0x3400 && rune <= 0x4dbf) ||
        (rune >= 0x4e00 && rune <= 0x9fff);
    if (isAsciiAlphaNumeric || isHiragana || isKatakana || isCjk) {
      result.writeCharCode(rune);
    }
  }
  return result.toString();
}

String _canonicalPath(String value) => value
    .trim()
    .replaceAll('\\', '/')
    .replaceAll(RegExp('/+'), '/')
    .toLowerCase();

String _pathName(String value) {
  final index = value.lastIndexOf('/');
  return index < 0 ? value : value.substring(index + 1);
}
