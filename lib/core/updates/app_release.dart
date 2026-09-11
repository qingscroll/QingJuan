import '../app_metadata.dart';

/// Only stable major.minor.patch releases are eligible for automatic updates.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch);

  factory AppVersion.parse(String value) {
    final match = RegExp(r'^[vV]?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$')
        .firstMatch(value.trim());
    if (match == null) throw const FormatException('无法识别版本号');
    return AppVersion(
        int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
  }

  final int major;
  final int minor;
  final int patch;

  @override
  int compareTo(AppVersion other) {
    for (final pair in <(int, int)>[
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final result = pair.$1.compareTo(pair.$2);
      if (result != 0) return result;
    }
    return 0;
  }

  @override
  String toString() => '$major.$minor.$patch';
}

class ReleaseAsset {
  const ReleaseAsset(
      {required this.name, required this.url, required this.size});
  final String name;
  final Uri url;
  final int size;
}

class AppRelease {
  const AppRelease(
      {required this.version,
      required this.notes,
      required this.pageUrl,
      this.asset,
      this.checksum});
  final AppVersion version;
  final String notes;
  final Uri pageUrl;
  final ReleaseAsset? asset;
  final ReleaseAsset? checksum;

  static AppRelease? fromJson(Map<String, dynamic> json,
      {required bool windows}) {
    if (json['draft'] != false || json['prerelease'] != false) return null;
    final tag = json['tag_name'] as String;
    final version = AppVersion.parse(tag);
    final page = trustedReleaseUri(json['html_url'] as String);
    if (page.path != '/$officialGitHubRepository/releases/tag/$tag') {
      throw const FormatException('发布页面与版本不匹配');
    }
    final name =
        'QingJuan-v$version-${windows ? 'windows-x64-setup.exe' : 'android.apk'}';
    ReleaseAsset? findAsset(String expected) {
      for (final value in json['assets'] as List? ?? const []) {
        final item = value as Map<String, dynamic>;
        if (item['name'] != expected || item['state'] != 'uploaded') continue;
        final url = trustedReleaseUri(item['browser_download_url'] as String);
        if (url.path !=
            '/$officialGitHubRepository/releases/download/$tag/$expected') {
          throw const FormatException('更新文件与发布版本不匹配');
        }
        final size = item['size'] as int;
        if (size <= 0 || size > 2 * 1024 * 1024 * 1024) {
          throw const FormatException('更新文件大小无效');
        }
        return ReleaseAsset(name: expected, url: url, size: size);
      }
      return null;
    }

    return AppRelease(
        version: version,
        notes: json['body'] as String? ?? '',
        pageUrl: page,
        asset: findAsset(name),
        checksum: findAsset('$name.sha256'));
  }
}

Uri trustedReleaseUri(String value) {
  final uri = Uri.parse(value);
  if (uri.scheme != 'https' ||
      uri.host != 'github.com' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      uri.hasQuery ||
      uri.hasFragment ||
      !uri.path.startsWith('/$officialGitHubRepository/releases/')) {
    throw const FormatException('更新地址不属于青卷官方发布源');
  }
  return uri;
}
