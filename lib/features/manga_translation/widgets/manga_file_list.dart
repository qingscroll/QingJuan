import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';

import '../manga_translation_models.dart';

class MangaFileList extends StatelessWidget {
  const MangaFileList({
    required this.files,
    required this.removeEnabled,
    required this.onRemove,
    this.editEnabled = true,
    this.onEdit,
    super.key,
  });

  final List<MangaTranslationFile> files;
  final bool removeEnabled;
  final ValueChanged<String> onRemove;
  final bool editEnabled;
  final ValueChanged<MangaTranslationFile>? onEdit;

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const _EmptyFileList();
    return ListView.separated(
      key: const ValueKey('manga-translation-file-list'),
      padding: EdgeInsets.zero,
      itemCount: files.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, index) => _FileRow(
        file: files[index],
        removeEnabled: removeEnabled,
        onRemove: onRemove,
        editEnabled: editEnabled,
        onEdit: onEdit,
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.removeEnabled,
    required this.onRemove,
    required this.editEnabled,
    required this.onEdit,
  });

  final MangaTranslationFile file;
  final bool removeEnabled;
  final ValueChanged<String> onRemove;
  final bool editEnabled;
  final ValueChanged<MangaTranslationFile>? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Container(
      key: ValueKey<String>('manga-file-${file.path}'),
      height: 66,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.resources.subtleFillColorSecondary,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.resources.cardStrokeColorDefault),
      ),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              width: 40,
              height: 40,
              child: Image.file(
                File(file.path),
                fit: BoxFit.cover,
                cacheWidth: 80,
                errorBuilder: (_, __, ___) => ColoredBox(
                  color: theme.resources.controlFillColorSecondary,
                  child: const Icon(FluentIcons.photo2, size: 18),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.bodyStrong,
                ),
                const SizedBox(height: 2),
                Text(
                  file.message.isEmpty ? file.path : file.message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.caption?.copyWith(
                    color: file.status == MangaTranslationFileStatus.failed
                        ? const Color(0xFFC42B1C)
                        : theme.resources.textFillColorSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _StatusBadge(file: file),
          const SizedBox(width: 4),
          if (onEdit != null)
            Tooltip(
              message: file.hasProject ? '编辑识别文本与译文' : '识别后打开文本工作台',
              child: IconButton(
                key: ValueKey<String>('edit-manga-file-${file.path}'),
                icon: const Icon(FluentIcons.edit, size: 13),
                onPressed: editEnabled ? () => onEdit!(file) : null,
              ),
            ),
          Tooltip(
            message: '从列表移除',
            child: IconButton(
              key: ValueKey<String>('remove-manga-file-${file.path}'),
              icon: const Icon(FluentIcons.chrome_close, size: 12),
              onPressed: removeEnabled ? () => onRemove(file.path) : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.file});

  final MangaTranslationFile file;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final (label, color) = switch (file.status) {
      MangaTranslationFileStatus.ready => (
          file.hasProject ? '已翻译' : '未翻译',
          file.hasProject
              ? const Color(0xFF107C10)
              : theme.resources.textFillColorSecondary,
        ),
      MangaTranslationFileStatus.running => (
          '运行中',
          theme.accentColor,
        ),
      MangaTranslationFileStatus.succeeded => (
          '完成',
          const Color(0xFF107C10),
        ),
      MangaTranslationFileStatus.failed => (
          '失败',
          const Color(0xFFC42B1C),
        ),
      MangaTranslationFileStatus.stopped => (
          '已停止',
          const Color(0xFF9D5D00),
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(24),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: theme.typography.caption?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptyFileList extends StatelessWidget {
  const _EmptyFileList();

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return CustomPaint(
      key: const ValueKey('manga-translation-empty-files'),
      painter: _DashedBorderPainter(
        color: theme.resources.cardStrokeColorDefault,
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              FluentIcons.file_image,
              size: 34,
              color: theme.resources.textFillColorSecondary,
            ),
            const SizedBox(height: 10),
            Text('尚未添加图片', style: theme.typography.bodyStrong),
            const SizedBox(height: 4),
            Text(
              '拖放图片或文件夹到此处，也可使用上方按钮添加',
              style: theme.typography.caption?.copyWith(
                color: theme.resources.textFillColorSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const dash = 6.0;
    const gap = 4.0;
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(6),
    );
    final borderPath = Path()..addRRect(rect);
    for (final metric in borderPath.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(
          metric.extractPath(distance, distance + dash),
          paint,
        );
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      color != oldDelegate.color;
}
