import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;

import '../app/app_scope.dart';

/// Real artwork with a deterministic fallback when a book has no cover.
class MobileBookCover extends StatelessWidget {
  const MobileBookCover(
      {required this.title, this.cover, this.borderRadius = 10, super.key});

  final String title;
  final String? cover;
  final double borderRadius;

  static const _paperColors = <Color>[
    Color(0xFFDDDCCB),
    Color(0xFFE8D9C7),
    Color(0xFFD6DEDF),
    Color(0xFFE6D2CD),
    Color(0xFFE2DFC9),
  ];

  @override
  Widget build(BuildContext context) {
    final dark = (MiuixTheme.maybeOf(context)?.brightness ??
            fluent.FluentTheme.maybeOf(context)?.brightness ??
            Theme.of(context).brightness) ==
        Brightness.dark;
    final url = cover?.trim();
    final api = url?.isNotEmpty == true
        ? context.dependOnInheritedWidgetOfExactType<AppScope>()?.api
        : null;
    final seed = title.runes.fold<int>(0, (value, rune) => value + rune);
    final paper = _paperColors[seed % _paperColors.length];
    final background =
        dark ? Color.lerp(paper, const Color(0xFF252220), .77)! : paper;
    final ink = dark ? paper : Color.lerp(paper, const Color(0xFF40362C), .75)!;
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            background,
            Color.lerp(background, dark ? Colors.black : Colors.white, .12)!
          ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Container(
              width: 12,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: <Color>[
                  ink.withValues(alpha: .07),
                  ink.withValues(alpha: 0),
                ]),
                border: Border(
                  right: BorderSide(color: ink.withValues(alpha: .08)),
                ),
              ),
            ),
          ),
          Positioned.fill(
            bottom: 26,
            child: LayoutBuilder(builder: (context, constraints) {
              final compact = constraints.maxWidth < 90;
              return Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: compact ? 12 : 18, vertical: 12),
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: RichText(
                      textScaler: TextScaler.noScaling,
                      maxLines: compact ? 3 : 4,
                      overflow: TextOverflow.ellipsis,
                      text: TextSpan(
                          text: title.trim().isEmpty ? '未命名作品' : title.trim(),
                          style: DefaultTextStyle.of(context).style.copyWith(
                              color: ink.withValues(alpha: .88),
                              fontSize: compact ? 13 : 17,
                              fontWeight: FontWeight.w600,
                              height: 1.45,
                              letterSpacing: 1.1)),
                    )),
              );
            }),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                      width: 20, height: 1, color: ink.withValues(alpha: .24)),
                  const SizedBox(height: 5),
                  Text(
                    '青卷',
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      fontSize: 8,
                      height: 1.8,
                      letterSpacing: 3,
                      color: ink.withValues(alpha: .62),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: LayoutBuilder(builder: (context, constraints) {
          final density = MediaQuery.devicePixelRatioOf(context);
          final width = constraints.maxWidth.isFinite
              ? (constraints.maxWidth * density).ceil().clamp(64, 900)
              : 360;
          return ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: url == null || url.isEmpty
                ? placeholder
                : Image.network(
                    api?.resolveUrl(url) ?? url,
                    headers: api?.headersForUrl(url),
                    cacheWidth: width,
                    color: dark ? const Color(0xDDFFFFFF) : null,
                    colorBlendMode: dark ? BlendMode.modulate : null,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                    loadingBuilder: (_, child, progress) =>
                        progress == null ? child : placeholder,
                    errorBuilder: (_, __, ___) => placeholder,
                  ),
          );
        }),
      ),
    );
  }
}
