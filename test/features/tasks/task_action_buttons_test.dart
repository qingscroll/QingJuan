import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qingjuan/core/models/task.dart';
import 'package:qingjuan/features/tasks/task_action_buttons.dart';

import '../../helpers/reliability_harness.dart';

void main() {
  testWidgets(
      'pending control disables conflicting actions and displays actionable errors',
      (tester) async {
    final response = Completer<http.Response>();
    var requests = 0;
    final harness = await ReliabilityHarness.create(MockClient((_) {
      requests++;
      return response.future;
    }));
    addTearDown(harness.dispose);
    harness.scope.tasks.tasks = [
      BookTask.fromJson({..._task, 'status': 'running'})
    ];
    await tester.pumpWidget(harness.widget(
        Scaffold(
            body: AnimatedBuilder(
                animation: harness.scope.tasks,
                builder: (_, __) => TaskActionButtons(
                    task: harness.scope.tasks.tasks.single, mobile: true))),
        mobile: true));
    await tester.tap(find.text('暂停'));
    await tester.pump();
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '取消任务'))
            .onPressed,
        isNull);
    await tester.tap(find.text('暂停'));
    expect(requests, 1);
    response.complete(http.Response(jsonEncode({'detail': '任务状态已变化，请刷新'}), 409,
        headers: {'content-type': 'application/json; charset=utf-8'}));
    await tester.pumpAndSettle();
    expect(find.textContaining('任务状态已变化，请刷新'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '暂停'))
            .onPressed,
        isNotNull);
    expect(tester.getSize(find.widgetWithText(TextButton, '暂停')).height,
        greaterThanOrEqualTo(48));
  });

  testWidgets(
      'older backends keep retry available without exposing unsupported controls',
      (tester) async {
    final harness = await ReliabilityHarness.create(
        MockClient((_) async => http.Response('{}', 200)));
    addTearDown(harness.dispose);
    harness.scope.backend.capabilities = {};
    await tester.pumpWidget(
        harness.widget(TaskActionButtons(task: BookTask.fromJson(_task))));
    await tester.pumpAndSettle();
    expect(find.text('重试任务'), findsOneWidget);
    expect(find.text('取消任务'), findsNothing);
    expect(find.text('暂停'), findsNothing);
  });
}

const _task = {
  'id': 'task-1',
  'bookId': 'book-1',
  'taskType': 'download',
  'status': 'failed',
  'totalCount': 10,
  'completedCount': 4,
  'progress': 40,
  'message': '任务进度',
  'attempts': 1,
  'updatedAt': '2026-09-11T12:00:00Z'
};
