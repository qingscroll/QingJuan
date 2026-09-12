class AccountMaintenance {
  const AccountMaintenance(
      {required this.email,
      required this.emailVerified,
      required this.emailServiceAvailable});

  final String? email;
  final bool emailVerified;
  final bool emailServiceAvailable;

  factory AccountMaintenance.fromJson(Map<String, dynamic> json) =>
      AccountMaintenance(
        email: json['email'] as String?,
        emailVerified: json['emailVerified'] as bool? ?? false,
        emailServiceAvailable: json['emailServiceAvailable'] as bool? ?? false,
      );
}

class AccountSession {
  const AccountSession(
      {required this.id,
      required this.platform,
      required this.createdAt,
      required this.expiresAt,
      required this.lastSeenAt,
      required this.current});

  final String id;
  final String platform;
  final String createdAt;
  final String expiresAt;
  final String lastSeenAt;
  final bool current;

  String get platformLabel => switch (platform) {
        'android' => 'Android 设备',
        'windows' => 'Windows 设备',
        'linux' => 'Linux 设备',
        'macos' => 'macOS 设备',
        'ios' => 'iOS 设备',
        _ => '未知设备',
      };

  factory AccountSession.fromJson(Map<String, dynamic> json) => AccountSession(
        id: json['id'] as String,
        platform: json['platform'] as String? ?? 'other',
        createdAt: json['createdAt'] as String,
        expiresAt: json['expiresAt'] as String,
        lastSeenAt: json['lastSeenAt'] as String,
        current: json['current'] as bool? ?? false,
      );
}

class AccountEmailDispatch {
  const AccountEmailDispatch(
      {required this.resendAfterSeconds,
      required this.expiresInSeconds,
      required this.message});

  final int resendAfterSeconds;
  final int expiresInSeconds;
  final String message;

  factory AccountEmailDispatch.fromJson(Map<String, dynamic> json) =>
      AccountEmailDispatch(
        resendAfterSeconds: json['resendAfterSeconds'] as int? ?? 60,
        expiresInSeconds: json['expiresInSeconds'] as int? ?? 600,
        message: json['message'] as String? ?? '请查看邮箱中的验证码。',
      );
}
