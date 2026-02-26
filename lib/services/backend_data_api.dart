import 'dart:convert';
import 'dart:io';

import '../core/app_config.dart';
import 'auth_api.dart';

class BackendDataApi {
  BackendDataApi({
    String? baseUrl,
    HttpClient? httpClient,
  })  : _baseUrl = (baseUrl ?? backendApiBaseUrl).trim(),
        _httpClient = httpClient ?? HttpClient();

  final String _baseUrl;
  final HttpClient _httpClient;

  Future<Map<String, dynamic>?> getAgentsConfig({
    required String accessToken,
  }) async {
    final response = await _sendJson(
      method: 'GET',
      path: '/api/data/agents-config',
      accessToken: accessToken,
    );
    final raw = response['config'];
    if (raw is! Map) return null;
    return Map<String, dynamic>.from(raw);
  }

  Future<void> putAgentsConfig({
    required String accessToken,
    required Map<String, dynamic> config,
  }) async {
    await _sendJson(
      method: 'PUT',
      path: '/api/data/agents-config',
      accessToken: accessToken,
      body: {'config': config},
    );
  }

  Future<List<Map<String, dynamic>>> getConversations({
    required String accessToken,
  }) async {
    final response = await _sendJson(
      method: 'GET',
      path: '/api/data/conversations',
      accessToken: accessToken,
    );
    final raw = response['conversations'];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<void> putConversations({
    required String accessToken,
    required List<Map<String, dynamic>> conversations,
  }) async {
    await _sendJson(
      method: 'PUT',
      path: '/api/data/conversations',
      accessToken: accessToken,
      body: {'conversations': conversations},
    );
  }

  Future<void> addConversation({
    required String accessToken,
    required Map<String, dynamic> conversation,
  }) async {
    await _sendJson(
      method: 'POST',
      path: '/api/data/conversations/add',
      accessToken: accessToken,
      body: {'conversation': conversation},
    );
  }

  Future<Map<String, dynamic>> _sendJson({
    required String method,
    required String path,
    required String accessToken,
    Map<String, dynamic>? body,
  }) async {
    final token = accessToken.trim();
    if (token.isEmpty) {
      throw AuthApiException(message: 'Missing access token');
    }

    final uri = Uri.parse(_baseUrl).resolve(path);
    final request = await _httpClient.openUrl(method, uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/json; charset=utf-8',
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');

    if (body != null) {
      request.add(utf8.encode(jsonEncode(body)));
    }

    final response = await request.close();
    final raw = await utf8.decodeStream(response);
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
              'Data API error (${response.statusCode})');
      throw AuthApiException(message: message, statusCode: response.statusCode);
    }

    return decoded;
  }
}
