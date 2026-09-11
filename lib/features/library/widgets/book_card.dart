import 'package:fluent_ui/fluent_ui.dart';

import '../../../app/app_scope.dart';
import '../../../core/models/book.dart';
import '../../../shared/app_surface.dart';
import '../../../shared/motion.dart';
import '../../../shared/responsive.dart';

class BookCard extends StatelessWidget {
  const BookCard({required this.book, required this.onOpen, super.key});

  final Book book;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    if (usesMobileUi(context)) {
      return _CompactBookCard(book: book, onOpen: onOpen);
    }
    return _WideBookCard(book: book, onOpen: onOpen);
  }
}

class _CompactBookCard extends StatelessWidget {
  const _CompactBookCard({required this.book, required this.onOpen});

  final Book book;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final progress = book.chapterCount <= 0
        ? 0.0
        : (book.lastReadChapterIndex / book.chapterCount * 100)
            .clamp(0, 100)
            .toDouble();
    return Semantics(
      button: true,
      label: '${book.title}，读到${book.readingPositionLabel}',
      child: HoverButton(
        onPressed: onOpen,
        builder: (context, states) => AnimatedOpacity(
          duration: QjMotion.duration(context, QjMotionSpeed.faster),
          curve: QjMotion.enterCurve,
          opacity: states.isPressed ? 0.78 : 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: BookCover(
                  book: book,
                  borderRadius: 12,
                  showShadow: true,
                ),
              ),
              const SizedBox(height: 9),
              Tooltip(
                message: book.title,
                child: Text(
                  book.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.body?.copyWith(
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                book.chapterCount <= 0
                    ? book.kind
                    : '${book.lastReadChapterIndex}/${book.chapterCount} 章',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.caption?.copyWith(
                  fontSize: 11,
                  color: theme.resources.textFillColorSecondary,
                ),
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: ProgressBar(value: progress, strokeWidth: 3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WideBookCard extends StatelessWidget {
  const _WideBookCard({required this.book, required this.onOpen});

  final Book book;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return AppSurface(
      onPressed: onOpen,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 76,
            height: 112,
            child: BookCover(book: book, borderRadius: 6),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Tooltip(
                  message: book.title,
                  child: Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.body
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${book.kind} · ${book.language}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.caption,
                ),
                const Spacer(),
                Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  children: <Widget>[
                    Text(
                      '上次读到${book.readingPositionLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.caption?.copyWith(
                        color: theme.resources.textFillColorSecondary,
                      ),
                    ),
                    Text(
                      '${book.chapterCount} 章${book.translated ? ' · 已翻译' : ''}',
                      style: theme.typography.caption?.copyWith(
                        color: book.translated
                            ? theme.accentColor
                                .defaultBrushFor(theme.brightness)
                            : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ProgressBar(
                    strokeWidth: 3,
                    value: book.chapterCount <= 0
                        ? 0
                        : (book.lastReadChapterIndex / book.chapterCount * 100)
                            .clamp(0, 100),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class BookCover extends StatelessWidget {
  const BookCover({
    required this.book,
    this.borderRadius = 10,
    this.showShadow = false,
    super.key,
  });

  final Book book;
  final double borderRadius;
  final bool showShadow;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final api = AppScope.of(context).api;
    final cover = book.cover?.trim();
    final placeholder = ColoredBox(
      color: theme.accentColor.withAlpha(
        theme.brightness == Brightness.dark ? 58 : 28,
      ),
      child: Center(
        child: Icon(
          FluentIcons.reading_mode,
          size: 28,
          color: theme.accentColor.defaultBrushFor(theme.brightness),
        ),
      ),
    );
    final image = LayoutBuilder(
      builder: (context, constraints) {
        final ratio = MediaQuery.devicePixelRatioOf(context);
        final cacheWidth = constraints.maxWidth.isFinite
            ? (constraints.maxWidth * ratio).round()
            : null;
        final cacheHeight = constraints.maxHeight.isFinite
            ? (constraints.maxHeight * ratio).round()
            : null;
        return cover == null || cover.isEmpty
            ? placeholder
            : Image.network(
                api.resolveUrl(cover),
                headers: api.headersForUrl(cover),
                fit: BoxFit.cover,
                width: double.infinity,
                height: double.infinity,
                cacheWidth: cacheWidth,
                cacheHeight: cacheHeight,
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : placeholder,
                errorBuilder: (_, __, ___) => placeholder,
              );
      },
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: showShadow
            ? <BoxShadow>[
                BoxShadow(
                  color: const Color(0xFF101828).withAlpha(
                    theme.brightness == Brightness.dark ? 44 : 22,
                  ),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: image,
      ),
    );
  }
}
