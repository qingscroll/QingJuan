import 'package:fluent_ui/fluent_ui.dart' as f;
import 'package:flutter/material.dart' as m;

import '../../core/models/book.dart';
import '../../mobile/mobile_action_button.dart';
import '../../shared/desktop_subpage.dart';
import '../../shared/responsive.dart';
import '../detail/book_detail_page.dart';
import 'book_preview_controller.dart';

class PreviewFrame extends f.StatelessWidget {
  const PreviewFrame(
      {required this.title,
      required this.child,
      this.maxContentWidth = 1120,
      this.horizontalPadding = 28,
      super.key});
  final String title;
  final f.Widget child;
  final double maxContentWidth;
  final double horizontalPadding;

  @override
  f.Widget build(f.BuildContext context) => usesMobileUi(context)
      ? m.Scaffold(
          appBar: m.AppBar(
              leading: m.IconButton(
                  key: const f.ValueKey('preview-back'),
                  tooltip: '返回',
                  icon: const m.Icon(m.Icons.arrow_back),
                  onPressed: () => f.Navigator.of(context).pop()),
              title: f.Text(title)),
          body: f.SafeArea(top: false, child: child))
      : DesktopSubpage(
          title: title,
          maxContentWidth: maxContentWidth,
          horizontalPadding: horizontalPadding,
          showContentTitle: false,
          backKey: const f.ValueKey('preview-back'),
          child: child,
        );
}

f.Widget previewButton(
    f.BuildContext context, String label, f.VoidCallback? action,
    {bool primary = false, f.Key? key}) {
  if (usesMobileUi(context)) {
    return primary
        ? MobileActionButton(key: key, onPressed: action, child: f.Text(label))
        : m.OutlinedButton(key: key, onPressed: action, child: f.Text(label));
  }
  return primary
      ? f.FilledButton(key: key, onPressed: action, child: f.Text(label))
      : f.Button(key: key, onPressed: action, child: f.Text(label));
}

f.Widget previewMessage(f.BuildContext context, String text,
        {bool error = false}) =>
    f.Padding(
      padding: const f.EdgeInsets.symmetric(vertical: 10),
      child: f.Semantics(
        liveRegion: true,
        child: usesMobileUi(context)
            ? m.Card(
                child: f.Padding(
                    padding: const f.EdgeInsets.all(14), child: f.Text(text)))
            : f.InfoBar(
                title: f.Text(text),
                severity:
                    error ? f.InfoBarSeverity.warning : f.InfoBarSeverity.info),
      ),
    );

f.TextStyle? previewHeading(f.BuildContext context) => usesMobileUi(context)
    ? m.Theme.of(context).textTheme.headlineSmall
    : f.FluentTheme.of(context).typography.title;

f.TextStyle? previewCaption(f.BuildContext context) => usesMobileUi(context)
    ? m.Theme.of(context).textTheme.bodySmall
    : f.FluentTheme.of(context).typography.caption;

f.Widget previewProgress(f.BuildContext context) => usesMobileUi(context)
    ? const m.CircularProgressIndicator()
    : const f.ProgressRing();

class PreviewScrollbar extends f.StatelessWidget {
  const PreviewScrollbar(
      {required this.controller, required this.child, super.key});
  final f.ScrollController controller;
  final f.Widget child;
  @override
  f.Widget build(f.BuildContext context) => usesMobileUi(context)
      ? m.Scrollbar(controller: controller, child: child)
      : f.Scrollbar(controller: controller, child: child);
}

class PreviewLibraryAction extends f.StatefulWidget {
  const PreviewLibraryAction({required this.controller, super.key});
  final BookPreviewController controller;
  @override
  f.State<PreviewLibraryAction> createState() => _PreviewLibraryActionState();
}

class _PreviewLibraryActionState extends f.State<PreviewLibraryAction> {
  bool _opening = false;

  Future<void> _open(Book book) async {
    if (_opening || !widget.controller.isCurrent) return;
    setState(() => _opening = true);
    final platform = UiPlatformScope.of(context);
    final page = UiPlatformScope(
        platform: platform, child: BookDetailPage(bookId: book.id));
    try {
      await f.Navigator.of(context).push<void>(usesMobileUi(context)
          ? m.MaterialPageRoute(builder: (_) => page)
          : f.FluentPageRoute(builder: (_) => page));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  f.Widget build(f.BuildContext context) {
    final controller = widget.controller;
    final book = controller.existingBook;
    return previewButton(
        context,
        controller.importing
            ? '正在加入…'
            : book == null
                ? '加入书架'
                : '打开作品',
        !controller.isCurrent || controller.importing || _opening
            ? null
            : () {
                if (book != null) {
                  _open(book);
                } else {
                  controller.addToLibrary();
                }
              },
        primary: true,
        key: const f.ValueKey('preview-library-action'));
  }
}

class PreviewContextExpired extends f.StatelessWidget {
  const PreviewContextExpired({super.key});
  @override
  f.Widget build(f.BuildContext context) => f.Center(
      child: f.Padding(
          padding: const f.EdgeInsets.all(24),
          child: f.Column(mainAxisSize: f.MainAxisSize.min, children: [
            const f.Text('账号或服务已切换，请返回列表重新打开预览。'),
            const f.SizedBox(height: 16),
            previewButton(context, '返回列表', () => f.Navigator.of(context).pop()),
          ])));
}
