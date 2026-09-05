import 'package:flutter_test/flutter_test.dart';
import 'package:qingjuan/features/manga_translation/editor/manga_text_editor_models.dart';

void main() {
  group('MangaTextEditorProject', () {
    test('locates the requested upstream page and preserves unknown JSON', () {
      final input = <String, dynamic>{
        'document_marker': <String, dynamic>{'keep': true},
        r'C:\other\cover.png': <String, dynamic>{
          'regions': <dynamic>[],
          'page_marker': 'other',
        },
        r'C:\manga\page-0002.png': <String, dynamic>{
          'original_width': 1200,
          'original_height': 1800,
          'page_marker': <String, dynamic>{'keep': 2},
          'regions': <dynamic>[
            <String, dynamic>{
              'order': 7,
              'bbox': <int>[100, 120, 320, 520],
              'source_text': '猫です',
              'text': '猫です',
              'texts': <String>['猫です'],
              'translation': '旧译文',
              'translation_raw': '旧译文',
              'translation_rich': <String, dynamic>{'spans': <dynamic>[]},
              'direction': 'v',
              'region_marker': <String, dynamic>{'keep': 'yes'},
            },
          ],
        },
      };

      final project = MangaTextEditorProject.fromDocument(
        input,
        sourcePath: r'c:/MANGA/page-0002.png',
      );
      final region = project.regions.single;

      expect(project.imageKey, r'C:\manga\page-0002.png');
      expect(project.originalWidth, 1200);
      expect(project.originalHeight, 1800);
      expect(region.order, 7);
      expect(region.bounds?.toProjectList(), <int>[100, 120, 320, 520]);
      expect(region.direction, MangaTextDirection.vertical);

      region
        ..updateSourceText('新原文\n第二行')
        ..updateTranslation('新译文')
        ..updateDirection(MangaTextDirection.horizontal);

      final output = project.toDocument();
      final page = output[r'C:\manga\page-0002.png'] as Map<String, dynamic>;
      final edited = (page['regions'] as List).single as Map<String, dynamic>;
      expect(output['document_marker'], <String, dynamic>{'keep': true});
      expect(page['page_marker'], <String, dynamic>{'keep': 2});
      expect(edited['region_marker'], <String, dynamic>{'keep': 'yes'});
      expect(edited['source_text'], '新原文\n第二行');
      expect(edited['text'], '新原文\n第二行');
      expect(edited['texts'], <String>['新原文\n第二行']);
      expect(edited['translation'], '新译文');
      expect(edited['translation_raw'], '新译文');
      expect(edited, isNot(contains('translation_rich')));
      expect(edited['direction'], 'h');

      // The editor owns a JSON-deep copy and never mutates the caller's map.
      final originalRegion = ((input[r'C:\manga\page-0002.png']
              as Map<String, dynamic>)['regions'] as List)
          .single as Map<String, dynamic>;
      expect(originalRegion['translation'], '旧译文');
      expect(originalRegion, contains('translation_rich'));
    });

    test('can locate a relocated page by its unique file name', () {
      final project = MangaTextEditorProject.fromDocument(
        <String, dynamic>{
          r'D:\old-library\page-0003.jpg': <String, dynamic>{
            'regions': <dynamic>[],
          },
          r'D:\old-library\page-0004.jpg': <String, dynamic>{
            'regions': <dynamic>[],
          },
        },
        sourcePath: r'C:\new-library\page-0004.jpg',
      );

      expect(project.imageKey, r'D:\old-library\page-0004.jpg');
    });

    test('accepts a direct page and derives bounds from upstream lines', () {
      final project = MangaTextEditorProject.fromDocument(
        <String, dynamic>{
          'regions': <dynamic>[
            <String, dynamic>{
              'lines': <dynamic>[
                <dynamic>[
                  <num>[42, 30],
                  <num>[8, 6],
                  <num>[42, 6],
                  <num>[8, 30],
                ],
              ],
              'texts': <String>['猫', 'です'],
              'translation_raw': '是猫',
            },
          ],
          'direct_marker': 42,
        },
      );

      expect(project.imageKey, isNull);
      expect(
          project.regions.single.bounds?.toProjectList(), <int>[8, 6, 42, 30]);
      expect(project.regions.single.sourceText, '猫\nです');
      expect(project.regions.single.translation, '是猫');
      expect(project.toDocument()['direct_marker'], 42);
    });

    test('rejects a document without a page region list', () {
      expect(
        () => MangaTextEditorProject.fromDocument(
          <String, dynamic>{
            'metadata': <String, dynamic>{'version': 1}
          },
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('untranslated detection', () {
    MangaTextEditorRegion regionFor(String source, String translation) {
      return MangaTextEditorProject.fromDocument(
        <String, dynamic>{
          'regions': <dynamic>[
            <String, dynamic>{
              'text': source,
              'translation': translation,
            },
          ],
        },
      ).regions.single;
    }

    test('treats an empty translation as untranslated', () {
      expect(regionFor('ありがとう', '  ').isUntranslated, isTrue);
      expect(regionFor('', '').isUntranslated, isTrue);
    });

    test('treats an effectively unchanged kana source as untranslated', () {
      expect(regionFor('ありがとう！', 'あ り が と う').isUntranslated, isTrue);
      expect(regionFor('ネコです。', 'ネコです').isUntranslated, isTrue);
    });

    test('does not flag translated text or unchanged non-kana text', () {
      expect(regionFor('ありがとう', '谢谢').isUntranslated, isFalse);
      expect(regionFor('HELLO!', 'hello').isUntranslated, isFalse);
      expect(regionFor('猫', '猫').isUntranslated, isFalse);
    });
  });

  group('manual regions', () {
    test('appends a complete region with max order plus one', () {
      final project = MangaTextEditorProject.fromDocument(
        <String, dynamic>{
          'regions': <dynamic>[
            <String, dynamic>{'order': 5, 'text': 'first'},
            <String, dynamic>{'order': 2, 'text': 'second'},
          ],
          'original_width': 100,
          'original_height': 200,
        },
      );

      final added = project.addRegion(
        const MangaTextRegionBounds.fromLTRB(-5, 10, 30, 150),
        sourceText: '',
        translation: '人工补译',
      );

      expect(project.regions.map((region) => region.order), <int>[5, 2, 6]);
      expect(added.order, 6);
      expect(added.direction, MangaTextDirection.vertical);
      expect(added.sourceText, '');
      expect(added.translation, '人工补译');
      expect(added.bounds?.toProjectList(), <int>[0, 10, 30, 150]);

      final raw = added.raw;
      expect(raw['bbox'], <int>[0, 10, 30, 150]);
      expect(raw['body_bbox'], <int>[0, 10, 30, 150]);
      expect(raw['safe_box'], <int>[0, 10, 30, 150]);
      expect(raw['lines'], <dynamic>[
        <dynamic>[
          <int>[0, 10],
          <int>[30, 10],
          <int>[30, 150],
          <int>[0, 150],
        ],
      ]);
      expect(raw['center'], <double>[15, 80]);
      expect(raw['text'], '');
      expect(raw['texts'], isEmpty);
      expect(raw['translation'], '人工补译');
      expect(raw['translation_raw'], '人工补译');
      expect(raw['direction'], 'v');
      expect(raw['font_size'], 22);
      expect(raw['alignment'], 'center');
    });

    test('removes only the selected region without reordering survivors', () {
      final project = MangaTextEditorProject.fromDocument(
        <String, dynamic>{
          'regions': <dynamic>[
            <String, dynamic>{'order': 9, 'text': 'keep'},
            <String, dynamic>{'order': 3, 'text': 'remove'},
            <String, dynamic>{'order': 12, 'text': 'also keep'},
          ],
        },
      );

      final selected = project.regions[1];
      expect(project.removeRegion(selected), isTrue);
      expect(project.removeRegion(selected), isFalse);
      expect(project.regions.map((region) => region.order), <int>[9, 12]);
      expect(
        project.regions.map((region) => region.sourceText),
        <String>['keep', 'also keep'],
      );
    });

    test('rejects a zero-area drag box', () {
      final project = MangaTextEditorProject.fromDocument(
        <String, dynamic>{'regions': <dynamic>[]},
      );

      expect(
        () => project.addRegion(
          const MangaTextRegionBounds.fromLTRB(10, 10, 10, 20),
        ),
        throwsArgumentError,
      );
    });
  });
}
