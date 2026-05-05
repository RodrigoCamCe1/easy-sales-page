import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/app_config.dart';
import 'auth_api.dart';

class RealtimeSessionApi {
  RealtimeSessionApi({String? baseUrl, HttpClient? httpClient})
      : _baseUrl = (baseUrl ?? backendApiBaseUrl).trim(),
        _httpClient = httpClient ?? HttpClient();

  final String _baseUrl;
  final HttpClient _httpClient;

  /// Solicita un token efímero al backend.
  /// Devuelve null si el backend no está disponible.
  Future<String?> createSession({required String accessToken}) async {
    final token = accessToken.trim();
    if (token.isEmpty) return null;

    try {
      final uri = Uri.parse(_baseUrl).resolve('/api/realtime/session');
      final request = await _httpClient.openUrl('POST', uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $token',
      );
      // Sin body — no enviamos Content-Type para evitar que Fastify
      // intente parsear un JSON vacío y devuelva 400.

      final response = await request.close();
      final raw = await utf8.decodeStream(response);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AuthApiException(
          message: 'Realtime session error (${response.statusCode})',
          statusCode: response.statusCode,
        );
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;

      final ephemeralToken = decoded['ephemeralToken'];
      return ephemeralToken is String && ephemeralToken.isNotEmpty
          ? ephemeralToken
          : null;
    } catch (e) {
      debugPrint('[RealtimeSessionApi] createSession error: $e');
      return null;
    }
  }

  /// Fetches the Groq API key from the backend.
  Future<String?> fetchGroqKey({required String accessToken}) async {
    final token = accessToken.trim();
    if (token.isEmpty) return null;

    try {
      final uri = Uri.parse(_baseUrl).resolve('/api/realtime/groq-key');
      debugPrint('[RealtimeSessionApi] GET $uri');
      final request = await _httpClient
          .openUrl('GET', uri)
          .timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');

      final response = await request.close().timeout(const Duration(seconds: 10));
      final raw = await utf8.decodeStream(response).timeout(const Duration(seconds: 5));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[RealtimeSessionApi] groq-key error (${response.statusCode}): $raw');
        return null;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;

      final apiKey = decoded['apiKey'];
      return apiKey is String && apiKey.isNotEmpty ? apiKey : null;
    } catch (e) {
      debugPrint('[RealtimeSessionApi] fetchGroqKey error: $e');
      return null;
    }
  }
}
