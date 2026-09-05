import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class ReaderScrollAnchor {
  const ReaderScrollAnchor(this.chapterIndex, this.itemIndex, this.offsetRatio,
      {this.characterOffset});
  final int chapterIndex;
  final int itemIndex;
  final double offsetRatio;

  /// UTF-16 offset in the normalized paragraph, measured from the rendered text.
  final int? characterOffset;
}

/// Tracks only mounted items in the lazy reader; positions are chapter-local.
class ReaderScrollPositionTracker {
  final Map<(int, int), GlobalKey> _keys = {};

  Widget track(int chapter, int item, Widget child) => KeyedSubtree(
      key: _keys.putIfAbsent((chapter, item), GlobalKey.new), child: child);

  RenderBox? _box(GlobalKey key) {
    final render = key.currentContext?.findRenderObject();
    return render is RenderBox && render.attached && render.hasSize
        ? render
        : null;
  }

  double _top(RenderBox box) {
    final viewport = RenderAbstractViewport.maybeOf(box);
    return viewport is RenderBox
        ? (viewport as RenderBox).localToGlobal(Offset.zero).dy
        : 0;
  }

  RenderEditable? _text(RenderObject render) {
    if (render is RenderEditable) return render;
    RenderEditable? result;
    render.visitChildren((child) => result ??= _text(child));
    return result;
  }

  ReaderScrollAnchor? capture() {
    final items = <({int chapter, int index, RenderBox box, double y})>[];
    for (final entry in _keys.entries) {
      final box = _box(entry.value);
      if (box == null) continue;
      final y = box.localToGlobal(Offset.zero).dy - _top(box);
      if (y + box.size.height > 0) {
        items.add((chapter: entry.key.$1, index: entry.key.$2, box: box, y: y));
      }
    }
    if (items.isEmpty) return null;
    items.sort((a, b) => a.y.compareTo(b.y));
    final first = items.first;
    final text = first.index < 0 ? null : _text(first.box);
    int? characterOffset;
    if (text != null) {
      final origin = text.localToGlobal(Offset.zero);
      final point = Offset(
          origin.dx +
              (text.textDirection == TextDirection.rtl ? text.size.width : 0),
          math.max(origin.dy, _top(first.box)) + .01);
      final position = text.getPositionForPoint(point);
      characterOffset = text.getLineAtOffset(position).start;
    }
    return ReaderScrollAnchor(
        first.chapter,
        first.index,
        first.box.size.height <= 0
            ? 0
            : (-first.y / first.box.size.height).clamp(0.0, 1.0),
        characterOffset: characterOffset);
  }

  Future<void> restore(ScrollController controller, ReaderScrollAnchor anchor,
      {required bool Function() isCurrent}) async {
    if (anchor.itemIndex < 0) {
      if (controller.hasClients) controller.jumpTo(0);
      return;
    }
    // A distant variable-height item may not be laid out yet. Seek towards its
    // index using mounted neighbours, then align its actual measured rectangle.
    for (var attempt = 0;
        attempt < 40 && isCurrent() && controller.hasClients;
        attempt++) {
      final key = _keys[(anchor.chapterIndex, anchor.itemIndex)];
      final target = key == null ? null : _box(key);
      if (target != null) {
        final text = anchor.characterOffset == null ? null : _text(target);
        final targetY = text == null
            ? target.localToGlobal(Offset.zero).dy +
                target.size.height * anchor.offsetRatio
            : text
                .localToGlobal(text
                    .getLocalRectForCaret(TextPosition(
                        offset: anchor.characterOffset!
                            .clamp(0, text.text?.toPlainText().length ?? 0)))
                    .topLeft)
                .dy;
        final delta = targetY - _top(target);
        final offset = (controller.offset + delta)
            .clamp(0.0, controller.position.maxScrollExtent);
        controller.jumpTo(offset);
        await WidgetsBinding.instance.endOfFrame;
        if (delta.abs() < .5 || (controller.offset - offset).abs() > .5) return;
        // Re-measure once after the lazy list updates its extent estimate.
        if (attempt > 0 && target.size.height > 0) return;
        continue;
      }
      final mounted = _keys.entries
          .where((entry) =>
              entry.key.$1 == anchor.chapterIndex &&
              entry.key.$2 >= 0 &&
              _box(entry.value) != null)
          .toList();
      if (mounted.isEmpty) return;
      mounted.sort((a, b) => (a.key.$2 - anchor.itemIndex)
          .abs()
          .compareTo((b.key.$2 - anchor.itemIndex).abs()));
      final nearest = mounted.first;
      final box = _box(nearest.value)!;
      final average = mounted.fold<double>(
              0, (sum, entry) => sum + _box(entry.value)!.size.height) /
          mounted.length;
      final delta = box.localToGlobal(Offset.zero).dy -
          _top(box) +
          (anchor.itemIndex - nearest.key.$2) * math.max(1, average);
      final next = (controller.offset + delta)
          .clamp(0.0, controller.position.maxScrollExtent);
      if ((next - controller.offset).abs() < .5) return;
      controller.jumpTo(next);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  void clear() => _keys.clear();
}
