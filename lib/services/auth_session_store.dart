import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/auth_models.dart';

class StoredAuthSession {
  const StoredAuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.refreshTokenExpiresAt,
    this.accessTokenExpiresAt,
    this.user,
  });

  final String accessToken;
  final String refreshToken;
  final String refreshTokenExpiresAt;
  final String? accessTokenExpiresAt;
  final AuthUser? user;
}

class AuthSessionStore {
  AuthSessionStore._();

  static final AuthSessionStore instance = AuthSessionStore._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    // useDataProtectionKeyChain: false → use the legacy file-based Keychain.
    // The data-protection keychain requires proper code signing / entitlements
    // and silently fails in unsigned `flutter run` dev builds, which prevented
    // the auth session from persisting across subwindows.
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );

  static const String _accessTokenKey = 'auth_access_token';
  static const String _refreshTokenKey = 'auth_refresh_token';
  static const String _refreshTokenExpiresAtKey = 'auth_refresh_token_expires_at';
  static const String _accessTokenExpiresAtKey = 'auth_access_token_expires_at';
  static const String _userJsonKey = 'auth_user_json';
  StoredAuthSession? _cachedSession;

  Future<void> saveSession({
    required String accessToken,
    required String refreshToken,
    required String refreshTokenExpiresAt,
    required String accessTokenExpiresAt,
    required AuthUser user,
  }) async {
    final snapshot = StoredAuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      refreshTokenExpiresAt: refreshTokenExpiresAt,
      accessTokenExpiresAt: accessTokenExpiresAt,
      user: user,
    );
    _cachedSession = snapshot;

    try {
      await _storage.write(key: _accessTokenKey, value: accessToken);
      await _storage.write(key: _refreshTokenKey, value: refreshToken);
      await _storage.write(
        key: _refreshTokenExpiresAtKey,
        value: refreshTokenExpiresAt,
      );
      await _storage.write(
        key: _accessTokenExpiresAtKey,
        value: accessTokenExpiresAt,
      );
      await _storage.write(
        key: _userJsonKey,
        value: jsonEncode(user.toJson()),
      );
    } catch (_) {
      // Windows secure storage can fail while DPAPI file is locked/corrupted.
      // Keep in-memory session to avoid crashing flows.
    }
  }

  Future<StoredAuthSession?> readSession() async {
    if (_cachedSession != null) return _cachedSession;

    String? accessToken;
    String? refreshToken;
    String? refreshTokenExpiresAt;
    String? accessTokenExpiresAt;
    String? userJson;

    try {
      accessToken = await _storage.read(key: _accessTokenKey);
      refreshToken = await _storage.read(key: _refreshTokenKey);
      refreshTokenExpiresAt =
          await _storage.read(key: _refreshTokenExpiresAtKey);
      accessTokenExpiresAt =
          await _storage.read(key: _accessTokenExpiresAtKey);
      userJson = await _storage.read(key: _userJsonKey);
    } catch (_) {
      return null;
    }

    AuthUser? user;
    if (userJson != null && userJson.trim().isNotEmpty) {
      try {
        final parsed = jsonDecode(userJson);
        if (parsed is Map) {
          user = AuthUser.fromJson(Map<String, dynamic>.from(parsed));
        }
      } catch (_) {}
    }

    if (accessToken == null ||
        refreshToken == null ||
        refreshTokenExpiresAt == null ||
        accessToken.trim().isEmpty ||
        refreshToken.trim().isEmpty ||
        refreshTokenExpiresAt.trim().isEmpty) {
      return null;
    }

    final session = StoredAuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      refreshTokenExpiresAt: refreshTokenExpiresAt,
      accessTokenExpiresAt: accessTokenExpiresAt,
      user: user,
    );
    _cachedSession = session;
    return session;
  }

  Future<void> clearSession() async {
    _cachedSession = null;
    try {
      await _storage.delete(key: _accessTokenKey);
      await _storage.delete(key: _refreshTokenKey);
      await _storage.delete(key: _refreshTokenExpiresAtKey);
      await _storage.delete(key: _accessTokenExpiresAtKey);
      await _storage.delete(key: _userJsonKey);
    } catch (_) {
      // Ignore storage cleanup errors on Windows lock races.
    }
  }
}
