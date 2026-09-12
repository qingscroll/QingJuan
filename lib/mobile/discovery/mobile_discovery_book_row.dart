import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/models/discovery.dart';
import '../mobile_action_button.dart';
import '../mobile_book_cover.dart';

String discoveryBookMetadata(DiscoveryBook book) => [
      book.category,
      book.status,
      book.wordCount,
    ].where((text) => text.isNotEmpty).join(' · ');

class MobileDiscoveryBookRow extends StatelessWidget {
  const MobileDiscoveryBookRow({
    required this.book,
    required this.ranked,
    required this.existing,
    required this.importing,
    required this.onPreview,
    this.onImport,
    super.key,
  });

  final DiscoveryBook book;
  final bool ranked;
  final bool existing;
  final bool importing;
  final VoidCallback onPreview;
  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final secondary = theme.textStyles.footnote1.copyWith(
      color: theme.colors.onBackgroundVariant,
      height: 1.5,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onPreview,
            borderRadius: BorderRadius.circular(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 72,
                  height: 104,
                  child: MobileBookCover(title: book.title, cover: book.cover),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(book.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textStyles.body1.copyWith(
                            color: theme.colors.onBackground,
                            fontWeight: FontWeight.w600,
                            height: 1.45,
                          )),
                      const SizedBox(height: 4),
                      Text(book.author.isEmpty ? '作者暂未提供' : book.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: secondary),
                      if ((ranked && book.rank != null) ||
                          book.score.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                            [
                              if (ranked && book.rank != null)
                                '第 ${book.rank} 名',
                              if (book.score.isNotEmpty) book.score,
                            ].join(' · '),
                            style: secondary.copyWith(
                                color: theme.colors.primary)),
                      ],
                      const SizedBox(height: 6),
                      Text(book.intro.isEmpty ? '站点暂未提供简介' : book.intro,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: secondary),
                      if (discoveryBookMetadata(book).isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(discoveryBookMetadata(book),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: secondary),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              MobileActionButton(
                  key: ValueKey('mobile-discovery-preview-${book.url}'),
                  onPressed: onPreview,
                  child: const Text('查看内容')),
              MobileActionButton(
                key: ValueKey('mobile-discovery-import-${book.url}'),
                tonal: true,
                busy: importing,
                onPressed: onImport,
                icon: existing
                    ? Icons.auto_stories_outlined
                    : Icons.library_add_outlined,
                child: Text(importing
                    ? '正在加入…'
                    : existing
                        ? '打开作品'
                        : '加入书库'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Divider(color: theme.colors.dividerLine),
        ],
      ),
    );
  }
}
