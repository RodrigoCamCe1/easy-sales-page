import 'dart:convert';
import 'dart:io';

import '../core/app_config.dart';
import '../models/agent_profile.dart';
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

  // ─── Document endpoints (RAG) ─────────────────────────────

  Future<AttachedFileRef> uploadDocument({
    required String accessToken,
    required String agentId,
    required String filePath,
  }) async {
    final token = accessToken.trim();
    if (token.isEmpty) {
      throw AuthApiException(message: 'Missing access token');
    }

    final file = File(filePath);
    final fileName = file.uri.pathSegments.last;
    final bytes = await file.readAsBytes();

    final boundary =
        '----DartFormBoundary${DateTime.now().millisecondsSinceEpoch}';
    final uri =
        Uri.parse(_baseUrl).resolve('/api/data/documents/upload');
    final request = await _httpClient.openUrl('POST', uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'multipart/form-data; boundary=$boundary',
    );
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');

    final body = <int>[];
    // agentId field
    body.addAll(utf8.encode('--$boundary\r\n'));
    body.addAll(utf8.encode(
        'Content-Disposition: form-data; name="agentId"\r\n\r\n'));
    body.addAll(utf8.encode('$agentId\r\n'));
    // file field
    body.addAll(utf8.encode('--$boundary\r\n'));
    body.addAll(utf8.encode(
        'Content-Disposition: form-data; name="file"; filename="$fileName"\r\n'));
    body.addAll(
        utf8.encode('Content-Type: application/octet-stream\r\n\r\n'));
    body.addAll(bytes);
    body.addAll(utf8.encode('\r\n'));
    body.addAll(utf8.encode('--$boundary--\r\n'));

    request.contentLength = body.length;
    request.add(body);

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
              'Upload error (${response.statusCode})');
      throw AuthApiException(
          message: message, statusCode: response.statusCode);
    }

    return AttachedFileRef(
      id: (decoded['id'] as String? ?? '').trim(),
      fileName: (decoded['fileName'] as String? ?? '').trim(),
      fileType: (decoded['fileType'] as String? ?? '').trim(),
      chunkCount: (decoded['chunkCount'] as int?) ?? 0,
      charCount: (decoded['charCount'] as int?) ?? 0,
    );
  }

  Future<List<AttachedFileRef>> listDocuments({
    required String accessToken,
    required String agentId,
  }) async {
    final response = await _sendJson(
      method: 'GET',
      path: '/api/data/documents?agentId=${Uri.encodeComponent(agentId)}',
      accessToken: accessToken,
    );
    final raw = response['files'];
    if (raw is! List) return [];
    return raw.whereType<Map>().map((item) {
      final m = Map<String, dynamic>.from(item);
      return AttachedFileRef(
        id: (m['id'] as String? ?? '').trim(),
        fileName: (m['fileName'] as String? ?? '').trim(),
        fileType: (m['fileType'] as String? ?? '').trim(),
        chunkCount: (m['chunkCount'] as int?) ?? 0,
        charCount: (m['charCount'] as int?) ?? 0,
      );
    }).toList();
  }

  Future<void> deleteDocument({
    required String accessToken,
    required String fileId,
  }) async {
    await _sendJson(
      method: 'DELETE',
      path: '/api/data/documents/$fileId',
      accessToken: accessToken,
    );
  }

  Future<List<Map<String, dynamic>>> searchDocuments({
    required String accessToken,
    required String agentId,
    required String query,
    int limit = 5,
  }) async {
    final response = await _sendJson(
      method: 'POST',
      path: '/api/data/documents/search',
      accessToken: accessToken,
      body: {'agentId': agentId, 'query': query, 'limit': limit},
    );
    final raw = response['chunks'];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  // ─── Google Calendar ─────────────────────────────────────────

  Future<Map<String, dynamic>> getCalendarStatus({
    required String accessToken,
  }) async {
    return _sendJson(
      method: 'GET',
      path: '/api/calendar/status',
      accessToken: accessToken,
    );
  }

  Future<List<Map<String, dynamic>>> getCalendarEvents({
    required String accessToken,
    String? date,
  }) async {
    final path =
        date != null ? '/api/calendar/events?date=$date' : '/api/calendar/events';
    final response = await _sendJson(
      method: 'GET',
      path: path,
      accessToken: accessToken,
    );
    final raw = response['events'];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<Map<String, dynamic>> createCalendarEvent({
    required String accessToken,
    required Map<String, dynamic> body,
  }) async {
    return _sendJson(
      method: 'POST',
      path: '/api/calendar/events',
      accessToken: accessToken,
      body: body,
    );
  }

  // ─── Internal helper ─────────────────────────────────────────

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
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');

    if (body != null) {
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
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
