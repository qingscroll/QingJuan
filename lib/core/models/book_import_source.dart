/// The number shortcut always means a JM album, never a chapter/photo ID.
String? comic18AlbumId(String input) {
  final value = input.trim();
  if (!RegExp(r'^[0-9]+$').hasMatch(value)) return null;
  final id = value.replaceFirst(RegExp(r'^0+'), '');
  return id.isEmpty ? null : id;
}

bool isComic18Source(String input) {
  if (comic18AlbumId(input) != null) return true;
  final uri = Uri.tryParse(input.trim());
  if (uri == null || !const ['http', 'https'].contains(uri.scheme)) {
    return false;
  }
  final host = uri.host.toLowerCase();
  return (host == '18comic.vip' || host.endsWith('.18comic.vip')) &&
      RegExp(r'^/(album|photo)/[0-9]+(?:/[^/?#]*)?/?$').hasMatch(uri.path);
}

String? bookImportSourceError(String? input, {bool albumOnly = false}) {
  final value = input?.trim() ?? '';
  if (comic18AlbumId(value) != null) return null;
  if (albumOnly) return '请输入有效的禁漫本子号（正整数）';
  final uri = Uri.tryParse(value);
  if (uri != null &&
      const ['http', 'https'].contains(uri.scheme) &&
      uri.host.isNotEmpty) {
    return null;
  }
  return '请输入完整的 HTTP 或 HTTPS 作品地址，或禁漫本子号（正整数）';
}

Map<String, dynamic> bookImportSourcePayload(String input, String bookKind) {
  final id = comic18AlbumId(input);
  return <String, dynamic>{
    'sourceUrl': id == null ? input.trim() : 'https://18comic.vip/album/$id/',
    if (id != null) 'albumId': id,
    'bookKind': isComic18Source(input) ? '漫画' : bookKind,
  };
}
