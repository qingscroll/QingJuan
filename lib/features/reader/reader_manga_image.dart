import 'package:fluent_ui/fluent_ui.dart';

import 'reader_theme.dart';

/// Keeps retry and zoom local to the failed page instead of reloading a chapter.
class ReaderMangaImage extends StatefulWidget {
  const ReaderMangaImage({
    required this.url,
    required this.headers,
    required this.pageNumber,
    required this.palette,
    super.key,
  });

  final String url;
  final Map<String, String> headers;
  final int pageNumber;
  final ReaderPalette palette;

  @override
  State<ReaderMangaImage> createState() => _ReaderMangaImageState();
}

class _ReaderMangaImageState extends State<ReaderMangaImage> {
  int _attempt = 0;
  final _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  Future<void> _retry() async {
    await NetworkImage(widget.url, headers: widget.headers).evict();
    if (mounted) setState(() => _attempt++);
  }

  @override
  Widget build(BuildContext context) {
    final placeholder =
        (MediaQuery.sizeOf(context).height * 0.66).clamp(280.0, 620.0);
    return Semantics(
      label: '第 ${widget.pageNumber} 张漫画，双指缩放，双击还原',
      image: true,
      child: GestureDetector(
        onDoubleTap: () => _transform.value = Matrix4.identity(),
        child: InteractiveViewer(
          transformationController: _transform,
          minScale: 1,
          maxScale: 4,
          child: Image.network(
            widget.url,
            key: ValueKey('${widget.url}:$_attempt'),
            headers: widget.headers,
            width: double.infinity,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            loadingBuilder: (context, child, progress) => progress == null
                ? child
                : SizedBox(
                    height: placeholder,
                    child: Center(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      ProgressRing(
                          value: progress.expectedTotalBytes == null
                              ? null
                              : progress.cumulativeBytesLoaded /
                                  progress.expectedTotalBytes! *
                                  100),
                      const SizedBox(height: 12),
                      Text('正在加载第 ${widget.pageNumber} 张',
                          style:
                              TextStyle(color: widget.palette.secondaryText)),
                    ])),
                  ),
            errorBuilder: (_, __, ___) => Container(
              height: placeholder,
              color: widget.palette.controlFill,
              alignment: Alignment.center,
              padding: const EdgeInsets.all(20),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(FluentIcons.photo_error,
                    color: widget.palette.secondaryText, size: 28),
                const SizedBox(height: 12),
                Text('第 ${widget.pageNumber} 张图片未能加载',
                    style: TextStyle(color: widget.palette.text)),
                const SizedBox(height: 8),
                Text('检查连接后重新加载此图。',
                    style: TextStyle(color: widget.palette.secondaryText)),
                const SizedBox(height: 16),
                ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Button(
                        style: ButtonStyle(
                          foregroundColor:
                              WidgetStatePropertyAll(widget.palette.accent),
                          backgroundColor:
                              WidgetStatePropertyAll(widget.palette.surface),
                          elevation: const WidgetStatePropertyAll(0),
                          shape: WidgetStatePropertyAll(RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(color: widget.palette.divider))),
                        ),
                        onPressed: _retry,
                        child: const Text('重试图片'))),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
