import 'package:fluent_ui/fluent_ui.dart';

import '../../core/models/discovery.dart';
import '../../shared/app_surface.dart';

class DiscoveryBookCard extends StatelessWidget {
  const DiscoveryBookCard({
    required this.book,
    required this.onImport,
    required this.onPreview,
    this.inLibrary = false,
    this.importing = false,
    super.key,
  });

  final DiscoveryBook book;
  final VoidCallback? onImport;
  final VoidCallback? onPreview;
  final bool inLibrary;
  final bool importing;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final metadata = [book.author, book.category, book.status, book.wordCount]
        .where((value) => value.isNotEmpty)
        .join(' · ');
    return AppSurface(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _previewTarget(
              SizedBox(width: 88, height: 124, child: _Cover(book: book))),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _previewTarget(Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${book.kind == 'rank' && book.rank != null ? '${book.rank}. ' : ''}${book.title}',
                      style: theme.typography.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (metadata.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 6),
                      Text(metadata,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.typography.caption?.copyWith(
                              color: theme.resources.textFillColorSecondary)),
                    ],
                    if (book.intro.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(book.intro,
                          maxLines: 3, overflow: TextOverflow.ellipsis),
                    ],
                  ],
                )),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    FilledButton(
                      key: ValueKey('discovery-preview-${book.bookId}'),
                      onPressed: onPreview,
                      child: const Text('查看内容'),
                    ),
                    Button(
                      key: ValueKey('discovery-import-${book.bookId}'),
                      onPressed: onImport,
                      child: Text(importing
                          ? '正在加入书架…'
                          : inLibrary
                              ? '打开书籍'
                              : '加入书架'),
                    ),
                    if (book.score.isNotEmpty)
                      Text(book.score,
                          style: TextStyle(color: theme.accentColor)),
                    if (book.url.isEmpty) const Text('站点未提供作品链接'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewTarget(Widget child) => HoverButton(
        onPressed: onPreview,
        cursor: SystemMouseCursors.click,
        builder: (context, states) =>
            FocusBorder(focused: states.isFocused, child: child),
      );
}

class _Cover extends StatelessWidget {
  const _Cover({required this.book});
  final DiscoveryBook book;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final placeholder = ColoredBox(
      color: theme.accentColor.withAlpha(22),
      child: Center(
          child: Icon(FluentIcons.book_answers,
              size: 30, color: theme.accentColor)),
    );
    final uri = Uri.tryParse(book.cover);
    final valid = uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: valid
          ? Image.network(
              book.cover,
              fit: BoxFit.cover,
              cacheWidth: (88 * MediaQuery.devicePixelRatioOf(context)).round(),
              semanticLabel: '${book.title}封面',
              loadingBuilder: (_, child, progress) =>
                  progress == null ? child : placeholder,
              errorBuilder: (_, error, stackTrace) => placeholder,
            )
          : placeholder,
    );
  }
}
