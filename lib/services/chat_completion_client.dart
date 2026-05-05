import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Lightweight client for OpenAI Chat Completions API (GPT-4o-mini).
/// Streams responses via SSE for progressive display.
class ChatCompletionClient {
  ChatCompletionClient({
    required this.apiKey,
    this.model = 'llama-3.3-70b-versatile',
    this.baseUrl = 'https://api.groq.com/openai/v1/chat/completions',
    this.maxTokens = 3000,
    this.onLog,
    this.onError,
  });

  final String apiKey;
  final String model;
  final String baseUrl;
  final int maxTokens;
  final void Function(String)? onLog;

  /// Called when API returns non-200 or network error.
  /// Receives user-friendly error message (e.g. "Límite de Groq alcanzado").
  final void Function(String userMessage)? onError;

  HttpClient _httpClient = HttpClient();
  bool _closed = false;

  /// Conversation history for context.
  final List<Map<String, String>> _history = [];

  /// Max messages to keep in history (system + last N turns).
  static const int _maxHistoryMessages = 20;

  /// Sets the system prompt. Clears previous history.
  void setSystemPrompt(String prompt) {
    _history.clear();
    if (prompt.trim().isNotEmpty) {
      _history.add({'role': 'system', 'content': prompt.trim()});
    }
  }

  /// Updates only the system prompt without clearing conversation history.
  void updateSystemPrompt(String prompt) {
    _history.removeWhere((m) => m['role'] == 'system');
    if (prompt.trim().isNotEmpty) {
      _history.insert(0, {'role': 'system', 'content': prompt.trim()});
    }
  }

  /// Adds a user message (transcription) and streams the assistant response.
  /// [onDelta] is called for each text chunk as it arrives.
  /// [onComplete] is called when the full response is done.
  /// Returns the full response text.
  Future<String> sendMessage({
    required String userMessage,
    required void Function(String delta) onDelta,
    VoidCallback? onComplete,
  }) async {
    _history.add({'role': 'user', 'content': userMessage});
    _trimHistory();

    final fullResponse = StringBuffer();

    try {
      if (_closed) {
        _httpClient = HttpClient();
        _closed = false;
      }
      final request = await _httpClient.postUrl(Uri.parse(baseUrl));
      request.headers.set('Authorization', 'Bearer $apiKey');
      request.headers.set('Content-Type', 'application/json');

      final body = jsonEncode({
        'model': model,
        'messages': _history,
        'max_tokens': maxTokens,
        'stream': true,
      });

      request.contentLength = utf8.encode(body).length;
      request.add(utf8.encode(body));

      final response = await request.close().timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final errorBody = await response.transform(utf8.decoder).join();
        _log('ChatCompletion error ${response.statusCode}: $errorBody');
        onError?.call(_friendlyError(response.statusCode, errorBody));
        onComplete?.call();
        return '';
      }

      // Parse SSE stream. LineSplitter buffers partial lines across chunk
      // boundaries — without it, a JSON payload split across two TCP chunks
      // gets silently dropped (the second half has no "data: " prefix), which
      // shows up as missing characters mid-word, e.g. "la pobreza" → "laobreza".
      final stream = response
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in stream) {
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data == '[DONE]') break;

        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final choices = json['choices'] as List?;
          if (choices == null || choices.isEmpty) continue;

          final delta = choices[0]['delta'] as Map<String, dynamic>?;
          if (delta == null) continue;

          final content = delta['content'] as String?;
          if (content != null && content.isNotEmpty) {
            fullResponse.write(content);
            onDelta(content);
          }
        } catch (_) {
          // Skip malformed SSE lines
        }
      }

      final responseText = fullResponse.toString();

      // Add assistant response to history
      if (responseText.isNotEmpty) {
        _history.add({'role': 'assistant', 'content': responseText});
      }

      onComplete?.call();
      return responseText;
    } catch (e) {
      _log('ChatCompletion error: $e');
      onError?.call(_friendlyNetworkError(e));
      onComplete?.call();
      return '';
    }
  }

  String _friendlyError(int status, String body) {
    switch (status) {
      case 429:
        return 'Límite de Groq alcanzado (rate limit). Espera unos segundos.';
      case 401:
        return 'Clave Groq inválida o expirada.';
      case 503:
      case 502:
        return 'Groq sobrecargado (cluster). Reintenta en breve.';
      case 500:
        return 'Error interno de Groq. Reintenta.';
      default:
        return 'Error Groq $status. Revisa logs.';
    }
  }

  String _friendlyNetworkError(Object e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('timeout')) return 'Timeout en Groq. Reintenta.';
    if (msg.contains('socket') || msg.contains('connection')) {
      return 'Sin conexión a Groq. Verifica internet.';
    }
    return 'Error de red Groq. Revisa logs.';
  }

  void _trimHistory() {
    // Keep system message + last N messages
    if (_history.length <= _maxHistoryMessages) return;
    final system = _history.where((m) => m['role'] == 'system').toList();
    final rest = _history.where((m) => m['role'] != 'system').toList();
    final trimmed = rest.sublist(rest.length - (_maxHistoryMessages - system.length));
    _history
      ..clear()
      ..addAll(system)
      ..addAll(trimmed);
  }

  void clearHistory() {
    final system = _history.where((m) => m['role'] == 'system').toList();
    _history
      ..clear()
      ..addAll(system);
  }

  void _log(String msg) {
    debugPrint(msg);
    onLog?.call(msg);
  }

  void close() {
    _closed = true;
    _httpClient.close();
  }
}
