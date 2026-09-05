import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../core/models/book.dart';
import 'mobile_action_button.dart';
import 'mobile_book_cover.dart';

class MobileContinueReading extends StatelessWidget {
  const MobileContinueReading(
      {required this.book,
      required this.onRead,
      required this.onDetails,
      super.key});
  final Book book;
  final VoidCallback onRead;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: theme.colors.dividerLine))),
      child:
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Semantics(
            button: true,
            label: '查看${book.title}详情',
            child: GestureDetector(
                onTap: onDetails,
                child: SizedBox(
                    width: 76,
                    height: 108,
                    child: MobileBookCover(
                        title: book.title, cover: book.cover)))),
        const SizedBox(width: 16),
        Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
              Text('继续阅读',
                  style: theme.textStyles.footnote1.copyWith(
                      color: theme.colors.onBackgroundVariant,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              Text(book.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textStyles.subtitle
                      .copyWith(color: theme.colors.onBackground)),
              const SizedBox(height: 4),
              Text(
                  '读到${book.readingPositionLabel}${book.chapterCount > 0 ? ' · 共 ${book.chapterCount} 章' : ''}',
                  style: theme.textStyles.footnote1
                      .copyWith(color: theme.colors.onBackgroundVariant)),
              const SizedBox(height: 8),
              MobileActionButton(
                  onPressed: onRead,
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Flexible(child: Text('接着读')),
                    SizedBox(width: 10),
                    Icon(Icons.arrow_forward_rounded, size: 16),
                  ])),
            ])),
      ]),
    );
  }
}

class MobileLibraryTile extends StatelessWidget {
  const MobileLibraryTile(
      {required this.book,
      required this.selecting,
      required this.selected,
      required this.onOpen,
      required this.onSelect,
      super.key});
  final Book book;
  final bool selecting;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    return Semantics(
      button: true,
      selected: selecting ? selected : null,
      label:
          '${book.title}，${book.kind}，${book.lastReadAt == null ? '尚未阅读' : '读到${book.readingPositionLabel}'}',
      child: MiuixPressable(
        onPressed: onOpen,
        onLongPress: onSelect,
        borderRadius: BorderRadius.circular(10),
        behavior: HitTestBehavior.opaque,
        child: ExcludeSemantics(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
              AspectRatio(
                  aspectRatio: 1 / 1.42,
                  child: Stack(fit: StackFit.expand, children: <Widget>[
                    MobileBookCover(title: book.title, cover: book.cover),
                    if (selecting)
                      Positioned(
                          top: 6,
                          right: 6,
                          child: DecoratedBox(
                              decoration: BoxDecoration(
                                  color: selected
                                      ? theme.colors.primary
                                      : theme.colors.surfaceContainer,
                                  shape: BoxShape.circle),
                              child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: Icon(
                                      selected
                                          ? Icons.check_rounded
                                          : Icons.circle_outlined,
                                      size: 22,
                                      color: selected
                                          ? theme.colors.onPrimary
                                          : theme
                                              .colors.onBackgroundVariant)))),
                  ])),
              const SizedBox(height: 8),
              SizedBox(
                  height: MediaQuery.textScalerOf(context).scale(14) * 2.7,
                  child: Text(book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textStyles.body2.copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                          color: theme.colors.onBackground))),
              const SizedBox(height: 3),
              Text(
                  '${book.kind == '漫画' ? '漫画' : '小说'} · ${book.lastReadAt == null ? '未读' : book.readingPositionLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textStyles.footnote2.copyWith(
                      color: theme.colors.onBackgroundVariant, height: 1.4)),
            ])),
      ),
    );
  }
}
