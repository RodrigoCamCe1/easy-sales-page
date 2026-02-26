import 'dart:convert';
import 'dart:io';

import '../core/app_config.dart';
import '../models/auth_models.dart';

class AuthApiException implements Exception {
  AuthApiException({
    required this.message,
    this.statusCode,
  });

  final String message;
  final int? statusCode;

  @override
  String toString() {
    if (statusCode == null) return message;
    return '[$statusCode] $message';
  }
}

class AuthApi {
  AuthApi({
    String? baseUrl,
    HttpClient? httpClient,
  })  : _baseUrl = (baseUrl ?? backendApiBaseUrl).trim(),
        _httpClient = httpClient ?? HttpClient();

  final String _baseUrl;
  final HttpClient _httpClient;

  Future<AuthTokenBundle> register({
    required String email,
    required String password,
    String? name,
  }) async {
    final response = await _sendJson(
      method: 'POST',
      path: '/api/auth/register',
      body: {
        'email': email,
        'password': password,
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      },
    );
    return AuthTokenBundle.fromJson(response);
  }

  Future<AuthTokenBundle> login({
    required String email,
    required String password,
  }) async {
    final response = await _sendJson(
      method: 'POST',
      path: '/api/auth/login',
      body: {
        'email': email,
        'password': password,
      },
    );
    return AuthTokenBundle.fromJson(response);
  }

  Future<String?> requestMagicLink({
    required String email,
  }) async {
    final response = await _sendJson(
      method: 'POST',
      path: '/api/auth/magic-link/request',
      body: {'email': email},
    );
    return response['devMagicLink']?.toString();
  }

  Future<AuthTokenBundle> verifyMagicLink({
    required String token,
  }) async {
    final response = await _sendJson(
      method: 'POST',
      path: '/api/auth/magic-link/verify',
      body: {'token': token},
    );
    return AuthTokenBundle.fromJson(response);
  }

  Future<AuthTokenBundle> refresh({
    required String refreshToken,
  }) async {
    final response = await _sendJson(
      method: 'POST',
      path: '/api/auth/refresh',
      body: {'refreshToken': refreshToken},
    );
    return AuthTokenBundle.fromJson(response);
  }

  Future<void> logout({
    required String refreshToken,
  }) async {
    await _sendJson(
      method: 'POST',
      path: '/api/auth/logout',
      body: {'refreshToken': refreshToken},
      allowNoContent: true,
    );
  }

  Future<AuthUser?> me({
    required String accessToken,
  }) async {
    final response = await _sendJson(
      method: 'GET',
      path: '/api/auth/me',
      bearerToken: accessToken,
    );
    final rawUser = response['user'];
    if (rawUser is! Map) return null;
    return AuthUser.fromJson(Map<String, dynamic>.from(rawUser));
  }

  Future<Map<String, dynamic>> _sendJson({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    String? bearerToken,
    bool allowNoContent = false,
  }) async {
    final uri = Uri.parse(_baseUrl).resolve(path);
    final request = await _httpClient.openUrl(method, uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/json; charset=utf-8',
    );
    if (bearerToken != null && bearerToken.trim().isNotEmpty) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${bearerToken.trim()}',
      );
    }

    if (body != null) {
      request.add(utf8.encode(jsonEncode(body)));
    }

    final response = await request.close();
    final raw = await utf8.decodeStream(response);

    if (allowNoContent && response.statusCode == HttpStatus.noContent) {
      return {};
    }

    Map<String, dynamic> decoded = {};
    if (raw.trim().isNotEmpty) {
      final parsed = jsonDecode(raw);
      if (parsed is Map) {
        decoded = Map<String, dynamic>.from(parsed);
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = decoded['error'];
      final message = error is String
          ? error
          : (decoded['message']?.toString() ??
              'Auth API error (${response.statusCode})');
      throw AuthApiException(
        message: message,
        statusCode: response.statusCode,
      );
    }

    return decoded;
  }
}
