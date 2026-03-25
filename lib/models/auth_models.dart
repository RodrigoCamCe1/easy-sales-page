class UserPlan {
  const UserPlan({
    this.tier = 'free',
    this.isExpired = false,
    this.expiresAt,
    this.activatedAt,
    this.queryLimit = 10,
    this.queryUsed = 0,
    this.queryResetAt,
    this.voiceMinutesLimit = 0,
    this.voiceMinutesUsed = 0,
    this.maxAgents = 1,
    this.maxDocuments = 5,
  });

  final String tier;
  final bool isExpired;
  final DateTime? expiresAt;
  final DateTime? activatedAt;
  final int queryLimit;
  final int queryUsed;
  final DateTime? queryResetAt;
  final int voiceMinutesLimit;
  final int voiceMinutesUsed;
  final int maxAgents;
  final int maxDocuments;

  bool get isFree => tier == 'free';
  bool get hasVoice => voiceMinutesLimit > 0;
  int get queryRemaining => (queryLimit - queryUsed).clamp(0, queryLimit);
  int get voiceMinutesRemaining => (voiceMinutesLimit - voiceMinutesUsed).clamp(0, voiceMinutesLimit);
  bool get isUnlimitedAgents => maxAgents < 0;
  bool get isUnlimitedDocuments => maxDocuments < 0;

  bool get isExpiringSoon {
    if (expiresAt == null || isFree) return false;
    return expiresAt!.difference(DateTime.now()).inDays <= 7;
  }

  String get tierLabel {
    const labels = {
      'free': 'Gratuito',
      'starter': 'Starter',
      'professional': 'Professional',
      'business': 'Business',
      'enterprise': 'Enterprise',
    };
    return labels[tier] ?? tier;
  }

  factory UserPlan.fromJson(Map<String, dynamic> json) {
    return UserPlan(
      tier: (json['tier'] ?? 'free').toString(),
      isExpired: json['isExpired'] == true,
      expiresAt: json['expiresAt'] != null ? DateTime.tryParse(json['expiresAt'].toString()) : null,
      activatedAt: json['activatedAt'] != null ? DateTime.tryParse(json['activatedAt'].toString()) : null,
      queryLimit: (json['queryLimit'] as num?)?.toInt() ?? 10,
      queryUsed: (json['queryUsed'] as num?)?.toInt() ?? 0,
      queryResetAt: json['queryResetAt'] != null ? DateTime.tryParse(json['queryResetAt'].toString()) : null,
      voiceMinutesLimit: (json['voiceMinutesLimit'] as num?)?.toInt() ?? 0,
      voiceMinutesUsed: (json['voiceMinutesUsed'] as num?)?.toInt() ?? 0,
      maxAgents: (json['maxAgents'] as num?)?.toInt() ?? 1,
      maxDocuments: (json['maxDocuments'] as num?)?.toInt() ?? 5,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'tier': tier,
      'isExpired': isExpired,
      'expiresAt': expiresAt?.toIso8601String(),
      'activatedAt': activatedAt?.toIso8601String(),
      'queryLimit': queryLimit,
      'queryUsed': queryUsed,
      'queryResetAt': queryResetAt?.toIso8601String(),
      'voiceMinutesLimit': voiceMinutesLimit,
      'voiceMinutesUsed': voiceMinutesUsed,
      'maxAgents': maxAgents,
      'maxDocuments': maxDocuments,
    };
  }
}

class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    this.name,
    this.plan = const UserPlan(),
  });

  final String id;
  final String email;
  final String? name;
  final UserPlan plan;

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: (json['id'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      name: json['name']?.toString(),
      plan: json['plan'] != null
          ? UserPlan.fromJson(Map<String, dynamic>.from(json['plan'] as Map))
          : const UserPlan(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'name': name,
      'plan': plan.toJson(),
    };
  }
}

class AuthTokenBundle {
  const AuthTokenBundle({
    required this.accessToken,
    required this.refreshToken,
    required this.accessTokenExpiresIn,
    required this.refreshTokenExpiresAt,
    required this.user,
  });

  final String accessToken;
  final String refreshToken;
  final String accessTokenExpiresIn;
  final String refreshTokenExpiresAt;
  final AuthUser user;

  factory AuthTokenBundle.fromJson(Map<String, dynamic> json) {
    return AuthTokenBundle(
      accessToken: (json['accessToken'] ?? '').toString(),
      refreshToken: (json['refreshToken'] ?? '').toString(),
      accessTokenExpiresIn: (json['accessTokenExpiresIn'] ?? '').toString(),
      refreshTokenExpiresAt: (json['refreshTokenExpiresAt'] ?? '').toString(),
      user: AuthUser.fromJson(
        Map<String, dynamic>.from(json['user'] as Map? ?? const {}),
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'accessTokenExpiresIn': accessTokenExpiresIn,
      'refreshTokenExpiresAt': refreshTokenExpiresAt,
      'user': user.toJson(),
    };
  }
}
