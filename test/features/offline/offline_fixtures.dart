import 'package:qingjuan/core/models/book.dart';
import 'package:qingjuan/core/models/offline_cache.dart';

const offlineIdentity = OfflineIdentity(
    connectionKey: 'credential-fingerprint',
    instanceId: 'instance-one',
    ownerId: 'owner-one',
    displayName: '测试账号',
    versioning: true);
BookDetail offlineDetail() => BookDetail.fromJson({
      'book': {
        'id': 'offline-book',
        'title': '离线测试书',
        'chapterCount': 2,
        'sourceUrl': 'https://source.test/?token=DO_NOT_PERSIST',
        'cover': 'https://source.test/DO_NOT_PERSIST.png'
      },
      'author': '作者',
      'synopsis': '离线简介',
      'totalWords': 100,
      'progress': {'lastChapterIndex': 1, 'lastScrollRatio': 0, 'revision': 0},
      'chapters': [
        for (var i = 1; i <= 2; i++)
          {
            'index': i,
            'title': '第 $i 章',
            'downloaded': true,
            'translated': true,
            'wordCount': 50,
            'imageCount': 0
          }
      ]
    });
ChapterContent offlineContent(
        {int index = 1,
        String mode = 'original',
        String text = '此处是本机保存的正文。',
        List<String> images = const []}) =>
    ChapterContent(
        chapter: Chapter(
            index: index,
            title: '第 $index 章',
            downloaded: true,
            translated: true,
            wordCount: 50,
            imageCount: images.length),
        content: text,
        paragraphs: [text],
        mode: mode,
        translatedAvailable: true,
        imageSources: images,
        pageTranslations: const []);
