import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'annotation_selection.dart';
import 'annotation_highlights.dart';

/// Each page owns one listener. Selection offsets flatten empty WidgetSpan
/// indents, so map them back to the unchanged pagination string before saving.
class ReaderPageSelection extends StatefulWidget {
  const ReaderPageSelection(
      {required this.text,
      required this.enabled,
      required this.onNote,
      required this.child,
      super.key});
  final String text;
  final bool enabled;
  final void Function(String quote, int? offset) onNote;
  final Widget child;

  @override
  State<ReaderPageSelection> createState() => _ReaderPageSelectionState();
}

class _ReaderPageSelectionState extends State<ReaderPageSelection> {
  final _selection = SelectionListenerNotifier();
  String _selected = '';

  @override
  void didUpdateWidget(ReaderPageSelection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _selected = '';
  }

  void _save(SelectableRegionState state) {
    final range = _selection.registered ? _selection.selection.range : null;
    final selected = annotationQuote(_selected);
    final precise = range == null
        ? null
        : pageSelectionAnchor(widget.text, range.startOffset, range.endOffset,
            selectedQuote: selected);
    final offset = precise != null && precise.quote == selected
        ? precise.offset
        : preciseSelectedOffset(widget.text, _selected);
    state.hideToolbar();
    widget.onNote(boundedAnnotationQuote(selected), offset);
  }

  @override
  Widget build(BuildContext context) => SelectionArea(
      onSelectionChanged: (value) => _selected = value?.plainText ?? '',
      contextMenuBuilder: (context, state) =>
          AdaptiveTextSelectionToolbar.buttonItems(
              anchors: state.contextMenuAnchors,
              buttonItems: [
                ...state.contextMenuButtonItems,
                if (widget.enabled && annotationQuote(_selected).isNotEmpty)
                  ContextMenuButtonItem(
                      label: '记笔记', onPressed: () => _save(state)),
              ]),
      child: SelectionListener(
          selectionNotifier: _selection, child: widget.child));

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }
}

({int offset, String quote})? pageSelectionAnchor(
    String text, int base, int extent,
    {String? selectedQuote}) {
  final offsets = <int>[];
  final units = <int>[];
  for (var index = 0; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (unit == 0xe000 || unit == 0xfffc) continue;
    offsets.add(index);
    units.add(unit);
  }
  final visible = String.fromCharCodes(units);
  var start = math.min(base, extent);
  final end = math.max(base, extent);
  if (start < 0 || start == end || end > text.length) return null;
  if (selectedQuote != null) {
    // Across RenderParagraph fragments the range can retain the first
    // fragment's placeholder offset. Only one exact candidate may be accepted.
    final candidates = <int>{
      start,
      if (start >= 0 && start < offsets.length) offsets[start],
    };
    final matches = <int>{
      for (final offset in candidates)
        if (matchAnnotationQuoteAt(text, offset, selectedQuote)
            case final range?)
          range.start,
    };
    return matches.length == 1
        ? (offset: matches.single, quote: selectedQuote)
        : null;
  }
  if (start < 0 || end > visible.length || start == end) return null;
  while (start < end && visible[start].trim().isEmpty) {
    start++;
  }
  if (start == end) return null;
  return (offset: offsets[start], quote: visible.substring(start, end).trim());
}
