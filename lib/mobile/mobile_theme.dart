import 'package:flutter/widgets.dart';
import 'package:flutter_miuix/miuix.dart';

const qjMobilePrimary = Color(0xFF3377F6);

MiuixColors qjMobileLightColors() => lightColorScheme().copy(
      primary: qjMobilePrimary,
      background: const Color(0xFFF6F8FC),
      surface: const Color(0xFFF9FBFE),
      surfaceContainer: const Color(0xFFFFFFFF),
      onBackground: const Color(0xFF171C24),
      onSurface: const Color(0xFF171C24),
      onBackgroundVariant: const Color(0xFF626C7B),
      outline: const Color(0xFFE2E8F2),
      dividerLine: const Color(0xFFE9EEF5),
    );

MiuixColors qjMobileDarkColors() => darkColorScheme().copy(
      primary: const Color(0xFF6E9FFF),
      background: const Color(0xFF11141A),
      surface: const Color(0xFF161A21),
      surfaceContainer: const Color(0xFF1D222B),
      onBackground: const Color(0xFFF2F5F9),
      onSurface: const Color(0xFFF2F5F9),
      onBackgroundVariant: const Color(0xFFA4AEBB),
      outline: const Color(0xFF333B48),
      dividerLine: const Color(0xFF2A313C),
    );
