import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

import '../../core/models/book.dart';

Future<int?> pickQualityChapter(f.BuildContext context,
    {required List<Chapter> chapters, required bool mobile}) {
  if (chapters.length == 1) return Future.value(chapters.single.index);
  if (mobile) {
    return m.showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => m.SizedBox(
        height: m.MediaQuery.sizeOf(context).height * .7,
        child: m.Column(children: [
          m.ListTile(
              title: const m.Text('选择校对章节'),
              trailing: m.IconButton(
                  tooltip: '关闭',
                  onPressed: () => m.Navigator.pop(context),
                  icon: const m.Icon(m.Icons.close))),
          m.Expanded(child: _ChapterList(chapters: chapters, mobile: true)),
        ]),
      ),
    );
  }
  return f.showDialog<int>(
      context: context,
      builder: (context) => f.ContentDialog(
            title: const f.Text('选择校对章节'),
            content: f.SizedBox(
                height: 360,
                child: _ChapterList(chapters: chapters, mobile: false)),
            actions: [
              f.Button(
                  onPressed: () => f.Navigator.pop(context),
                  child: const f.Text('取消'))
            ],
          ));
}

class _ChapterList extends f.StatelessWidget {
  const _ChapterList({required this.chapters, required this.mobile});
  final List<Chapter> chapters;
  final bool mobile;

  @override
  f.Widget build(f.BuildContext context) {
    if (chapters.isEmpty) {
      return const f.Center(
          child: f.Padding(
              padding: f.EdgeInsets.all(20),
              child: f.Text('请先下载章节原文，再进行译文校对。')));
    }
    return f.ListView.builder(
        itemCount: chapters.length,
        itemBuilder: (context, index) {
          final chapter = chapters[index];
          final title = '${chapter.index}. ${chapter.title}';
          if (mobile) {
            return m.ListTile(
                title: m.Text(title),
                subtitle: m.Text(chapter.translated ? '已有译文' : '尚无译文'),
                onTap: () => m.Navigator.pop(context, chapter.index));
          }
          return f.Padding(
              padding: const f.EdgeInsets.symmetric(vertical: 4),
              child: f.Button(
                  onPressed: () => f.Navigator.pop(context, chapter.index),
                  child: f.Align(
                      alignment: f.Alignment.centerLeft,
                      child: f.Text(title))));
        });
  }
}
