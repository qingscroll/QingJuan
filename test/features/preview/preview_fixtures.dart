import 'dart:convert';
import 'package:http/http.dart' as http;

const previewPayload = <String, dynamic>{
  'sourceUrl': 'https://books.example.test/mist',
  'sourceId': 'source-one',
  'title': '雾海书简',
  'bookKind': '长小说',
  'language': '英语',
  'needTranslation': false,
};
const previewSynopsis = '沿海小城的旧书店收到一封来自三十年前的信。年轻的修书师循着书页上的批注，'
    '寻找一座已从地图上消失的灯塔。潮汐、航海日志与陌生人的来访，让一段被遗忘的旅程重新展开。';
const previewMetadata = <String, dynamic>{
  'title': '雾海书简',
  'author': '林间 · 远行',
  'synopsis': previewSynopsis,
  'bookKind': '长小说',
  'chapterCount': 3,
  'sourceStatus': 'ongoing',
  'sourceStatusEvidence': 'source metadata',
  'chapters': [
    {'title': '潮汐带来的信', 'url': 'https://books.example.test/mist/1'},
    {'title': '旧书页里的航线', 'url': 'https://books.example.test/mist/2'},
    {
      'title': '灯塔以北',
      'url': 'https://books.example.test/mist/3',
      'accessRestricted': true
    },
  ],
};
const importedPreviewBook = <String, dynamic>{
  'id': 'imported-mist',
  'title': '雾海书简',
  'sourceUrl': 'https://books.example.test/mist',
  'bookKind': '长小说',
  'language': '英语',
  'chapterCount': 3,
};

Map<String, dynamic> previewContent(int index,
        {List<String> images = const []}) =>
    {
      'bookId': '',
      'chapter': {
        'index': index,
        'title': index == 1 ? '潮汐带来的信' : '旧书页里的航线',
        'downloaded': false,
        'translated': false,
        'imageCount': images.length
      },
      'content': images.isEmpty ? '潮水退去，信封静静躺在旧书店的门前。' : '',
      'paragraphs': images.isEmpty
          ? ['潮水退去，信封静静躺在旧书店的门前。', '她翻开航海日志，发现第一页的日期停留在三十年前。远处的灯塔仍在雾里若隐若现。']
          : [],
      'mode': 'original',
      'translatedAvailable': false,
      'imageSources': images,
      'pageTranslations': [],
    };

Map<String, dynamic> completedPreviewImport() => {
      'id': 'preview-import',
      'mode': 'import',
      'status': 'completed',
      'progress': 100,
      'book': importedPreviewBook,
    };

http.Response previewJson(Object value, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(value)), status,
        headers: {'content-type': 'application/json'});
