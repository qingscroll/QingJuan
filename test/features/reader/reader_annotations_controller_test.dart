import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/features/reader/reader_annotations_controller.dart';

import '../../helpers/reliability_harness.dart';
import 'annotation_highlights_test.dart' show highlightJson;
import 'annotations_controller_test.dart' show response;

void main() {
  const text = '\ue000😀needle 正文。';
  test(
      'reloaded chapter content invalidates old ranges and ignores its late response',
      () async {
    final stale = Completer<http.Response>();
    var calls = 0;
    final harness = await ReliabilityHarness.create(MockClient((_) async {
      calls++;
      if (calls == 2) return stale.future;
      return response([highlightJson(text, 'needle', 3)]);
    }));
    addTearDown(harness.dispose);
    final controller =
        ReaderAnnotationsController(harness.scope.library, 'book');
    addTearDown(controller.dispose);
    await controller.load(1, 'original', text);
    expect(controller.ranges(1, 'original'), isNotEmpty);
    final pending = controller.load(1, 'original', '$text appended');
    expect(controller.ranges(1, 'original'), isEmpty);
    await controller.load(1, 'original', 'replacement $text');
    stale.complete(response([highlightJson('$text appended', 'needle', 3)]));
    await pending;
    expect(controller.ranges(1, 'original'), isEmpty);
    expect(calls, 3);
  });
  test('chapter-scoped pagination loads notes older than 50 and deduplicates',
      () async {
    final requests = <http.Request>[];
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      requests.add(request);
      final offset = int.parse(request.url.queryParameters['offset']!);
      return response(offset == 0
          ? List.generate(
              50,
              (i) => {
                    ...highlightJson(text, '', 3),
                    'id': 'empty-$i',
                  })
          : [highlightJson(text, 'needle', 3)]);
    }));
    addTearDown(harness.dispose);
    final controller =
        ReaderAnnotationsController(harness.scope.library, 'book');
    addTearDown(controller.dispose);
    await controller.load(1, 'original', text);
    expect(controller.ranges(1, 'original').single.start, 3);
    expect(requests.map((r) => r.url.queryParameters['offset']), ['0', '50']);
    expect(requests.first.url.queryParameters, {
      'limit': '50',
      'offset': '0',
      'chapterIndex': '1',
      'mode': 'original',
      'kind': 'note'
    });
    await controller.load(1, 'original', text);
    expect(requests.length, 2);
  });

  test(
      'refresh removes deleted lines and stale loads cannot resurrect them or cross accounts',
      () async {
    final stale = Completer<http.Response>();
    var calls = 0;
    final harness = await ReliabilityHarness.create(MockClient((request) async {
      calls++;
      if (calls == 1) return stale.future;
      return response([]);
    }));
    addTearDown(harness.dispose);
    final controller =
        ReaderAnnotationsController(harness.scope.library, 'book');
    addTearDown(controller.dispose);
    final pending = controller.load(1, 'original', text);
    controller.clear();
    await controller.load(1, 'original', text);
    stale.complete(response([highlightJson(text, 'needle', 3)]));
    await pending;
    expect(controller.ranges(1, 'original'), isEmpty);
    harness.scope.library.resetForBackendSwitch();
    await controller.load(1, 'original', text);
    expect(calls, 2);
  });
}
