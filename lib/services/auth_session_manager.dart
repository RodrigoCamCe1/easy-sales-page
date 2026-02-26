import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/auth_models.dart';
import 'auth_api.dart';
import 'auth_session_store.dart';

class AuthSessionManager {
  AuthSessionManager._();

  static final AuthSessionManager instance = AuthSessionManager._();

  final AuthApi _api = AuthApi();
  final ValueNotifier<AuthUser?> currentUser = ValueNotifier<AuthUser?>(null);

  String? _accessToken;
  String? _refreshToken;
  String? _accessTokenExpiresAt;
  String? _refreshTokenExpiresAt;
  Timer? _autoRefreshTimer;
  Future<bool>? _refreshInFlight;

  String? get accessToken => _accessToken;
  String? get refreshToken => _refreshToken;
  AuthUser? get currentUserValue => currentUser.value;
  bool get isAuthenticated =>
      _accessToken != null &&
      _accessToken!.trim().isNotEmpty &&
      currentUser.value != null;

  Future<void> bootstrap() async {
    final stored = await AuthSessionStore.instance.readSession();
    if (stored == null) {
      await clearLocalSession();
      return;
    }

    _accessToken = stored.accessToken;
    _refreshToken = stored.refreshToken;
    _accessTokenExpiresAt = stored.accessTokenExpiresAt;
    _refreshTokenExpiresAt = stored.refreshTokenExpiresAt;
    currentUser.value = stored.user;

    if (_isExpired(stored.refreshTokenExpiresAt)) {
      await clearLocalSession();
      return;
    }

    if (stored.user == null) {
      final loaded = await _loadUserOrRefresh();
      if (!loaded) {
        await clearLocalSession();
      }
      return;
    }

    if (_isExpired(_accessTokenExpiresAt, skew: const Duration(seconds: 30))) {
      await refreshWithStoredToken();
      return;
    }

    _scheduleAutoRefresh();
    unawaited(_refreshProfileInBackground());
  }

  Future<bool> _loadUserOrRefresh() async {
    final accessToken = _accessToken;
    if (accessToken == null || accessToken.trim().isEmpty) {
      return refreshWithStoredToken();
    }

    try {
      final me = await _api.me(accessToken: accessToken);
      if (me != null) {
        currentUser.value = me;
        _scheduleAutoRefresh();
        await _persistCurrentSnapshot();
        return true;
      }
    } on AuthApiException catch (error) {
      if (error.statusCode == 401) {
        return refreshWithStoredToken();
      }
      return false;
    }
    return refreshWithStoredToken();
  }

  Future<void> _refreshProfileInBackground() async {
    final accessToken = _accessToken;
    if (accessToken == null || accessToken.trim().isEmpty) return;
    try {
      final me = await _api.me(accessToken: accessToken);
      if (me == null) return;
      currentUser.value = me;
      await _persistCurrentSnapshot();
    } catch (_) {}
  }

  Future<AuthTokenBundle> login({
    required String email,
    required String password,
  }) async {
    final bundle = await _api.login(email: email, password: password);
    await _applyBundle(bundle);
    return bundle;
  }

  Future<AuthTokenBundle> register({
    required String email,
    required String password,
    String? name,
  }) async {
    final bundle = await _api.register(
      email: email,
      password: password,
      name: name,
    );
    await _applyBundle(bundle);
    return bundle;
  }

  Future<String?> requestMagicLink({
    required String email,
  }) {
    return _api.requestMagicLink(email: email);
  }

  Future<AuthTokenBundle> verifyMagicLink({
    required String token,
  }) async {
    final bundle = await _api.verifyMagicLink(token: token);
    await _applyBundle(bundle);
    return bundle;
  }

  Future<bool> refreshWithStoredToken() async {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;

    _refreshInFlight = _refreshWithStoredTokenInternal();
    final result = await _refreshInFlight!;
    _refreshInFlight = null;
    return result;
  }

  Future<bool> _refreshWithStoredTokenInternal() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null || refreshToken.trim().isEmpty) {
      await clearLocalSession();
      return false;
    }

    if (_isExpired(_refreshTokenExpiresAt, skew: const Duration(seconds: 30))) {
      await clearLocalSession();
      return false;
    }

    try {
      final bundle = await _api.refresh(refreshToken: refreshToken);
      await _applyBundle(bundle);
      return true;
    } catch (_) {
      await clearLocalSession();
      return false;
    }
  }

  Future<void> logout() async {
    final refreshToken = _refreshToken;
    if (refreshToken != null && refreshToken.trim().isNotEmpty) {
      try {
        await _api.logout(refreshToken: refreshToken);
      } catch (_) {}
    }
    await clearLocalSession();
  }

  Future<void> clearLocalSession() async {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
    _accessToken = null;
    _refreshToken = null;
    _accessTokenExpiresAt = null;
    _refreshTokenExpiresAt = null;
    currentUser.value = null;
    await AuthSessionStore.instance.clearSession();
  }

  Future<void> _applyBundle(AuthTokenBundle bundle) async {
    _autoRefreshTimer?.cancel();
    _accessToken = bundle.accessToken;
    _refreshToken = bundle.refreshToken;
    _accessTokenExpiresAt =
        _calculateAccessTokenExpiresAt(bundle.accessTokenExpiresIn)
            .toIso8601String();
    _refreshTokenExpiresAt = bundle.refreshTokenExpiresAt;
    currentUser.value = bundle.user;

    await AuthSessionStore.instance.saveSession(
      accessToken: bundle.accessToken,
      refreshToken: bundle.refreshToken,
      refreshTokenExpiresAt: bundle.refreshTokenExpiresAt,
      accessTokenExpiresAt: _accessTokenExpiresAt!,
      user: bundle.user,
    );
    _scheduleAutoRefresh();
  }

  Future<void> _persistCurrentSnapshot() async {
    final accessToken = _accessToken;
    final refreshToken = _refreshToken;
    final refreshTokenExpiresAt = _refreshTokenExpiresAt;
    final accessTokenExpiresAt = _accessTokenExpiresAt;
    final user = currentUser.value;
    if (accessToken == null ||
        refreshToken == null ||
        refreshTokenExpiresAt == null ||
        accessTokenExpiresAt == null ||
        user == null) {
      return;
    }
    await AuthSessionStore.instance.saveSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      refreshTokenExpiresAt: refreshTokenExpiresAt,
      accessTokenExpiresAt: accessTokenExpiresAt,
      user: user,
    );
  }

  DateTime _calculateAccessTokenExpiresAt(String ttl) {
    final raw = ttl.trim().toLowerCase();
    final match = RegExp(r'^(\d+)([smhd])$').firstMatch(raw);
    if (match == null) {
      return DateTime.now().add(const Duration(minutes: 15));
    }
    final amount = int.tryParse(match.group(1) ?? '') ?? 15;
    final unit = match.group(2) ?? 'm';
    final duration = switch (unit) {
      's' => Duration(seconds: amount),
      'm' => Duration(minutes: amount),
      'h' => Duration(hours: amount),
      'd' => Duration(days: amount),
      _ => const Duration(minutes: 15),
    };
    return DateTime.now().add(duration);
  }

  bool _isExpired(String? isoDate, {Duration skew = Duration.zero}) {
    if (isoDate == null || isoDate.trim().isEmpty) return true;
    final parsed = DateTime.tryParse(isoDate);
    if (parsed == null) return true;
    return DateTime.now().add(skew).isAfter(parsed.toLocal());
  }

  void _scheduleAutoRefresh() {
    _autoRefreshTimer?.cancel();
    final expiresAtIso = _accessTokenExpiresAt;
    if (expiresAtIso == null || expiresAtIso.trim().isEmpty) return;

    final expiresAt = DateTime.tryParse(expiresAtIso);
    if (expiresAt == null) return;

    final refreshAt = expiresAt.toLocal().subtract(const Duration(minutes: 1));
    final delay = refreshAt.difference(DateTime.now());
    if (delay <= Duration.zero) {
      unawaited(refreshWithStoredToken());
      return;
    }

    _autoRefreshTimer = Timer(delay, () {
      unawaited(refreshWithStoredToken());
    });
  }
}
