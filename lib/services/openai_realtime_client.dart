import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';

class OpenAIRealtimeClient {
  OpenAIRealtimeClient({
    required this.openAIKey,
    required this.model,
    required this.vadSilenceMs,
    required this.onDelta,
    required this.onTranscriptDelta,
    this.onComplete,
    this.showEvents = true,
    String? sessionInstructions,
    this.sourceTag = '',
  }) : _sessionInstructions = sessionInstructions?.trim() ?? '';

  final String openAIKey;
  final String model;
  final int vadSilenceMs;

  /// Texto del asistente (Chat/Sugerencias)
  final void Function(String) onDelta;

  /// Transcripción del audio de entrada (panel Transcripción)
  final void Function(String) onTranscriptDelta;

  final VoidCallback? onComplete;
  final bool showEvents;
  final String sourceTag;

  IOWebSocketChannel? _channel;
  String _sessionInstructions = '';
  int _bufferedAudioBytes = 0;

  // 16kHz * mono * 16-bit * 100ms ~= 3200 bytes.
  static const int _minCommitBytes = 3200;

  // Para evitar dobles completes en un mismo “response”
  bool _completedThisTurn = false;
  String? _assistantStreamMode;
  String? _activeResponseId;
  // ==== TRANSCRIPTS: evitar overlaps (delta vs completed) ====
  final Map<String, String> _userTranscriptAccum = {};

  // =========================
  // TRANSCRIPT: flush por inactividad
  // =========================
  Timer? _transcriptIdleTimer;
  bool _hasOpenTranscript = false; // hay texto “en progreso” que aún no cerró con \n
  final int _transcriptIdleMs = 1100; // 900–1500 recomendado

  void _bumpTranscriptIdleFlush() {
    _hasOpenTranscript = true;

    _transcriptIdleTimer?.cancel();
    _transcriptIdleTimer = Timer(Duration(milliseconds: _transcriptIdleMs), () {
      if (_hasOpenTranscript) {
        onTranscriptDelta('\n'); // cierra “la línea” en la UI
        _hasOpenTranscript = false;
      }
    });
  }

  void _forceCloseTranscriptLine() {
    _transcriptIdleTimer?.cancel();
    _transcriptIdleTimer = null;

    if (_hasOpenTranscript) {
      onTranscriptDelta('\n');
      _hasOpenTranscript = false;
    }
  }

  Future<void> connect() async {
    final uri = Uri.parse('wss://api.openai.com/v1/realtime?model=$model');
    final socket = await WebSocket.connect(
      uri.toString(),
      headers: {
        'Authorization': 'Bearer $openAIKey',
        'OpenAI-Beta': 'realtime=v1',
      },
    );

    _channel = IOWebSocketChannel(socket);

    // IMPORTANTE: setear sesión apenas conecta
    _updateSession();

    _channel?.stream.listen(
      _handleMessage,
      onDone: () {
        debugPrint('OpenAI WS closed');
        _safeCompleteOnce(reason: 'ws_onDone');
      },
      onError: (error) {
        debugPrint('OpenAI WS error: $error');
        _safeCompleteOnce(reason: 'ws_onError');
      },
    );
  }

  void _updateSession() {
    final session = <String, Object?>{
      'turn_detection': {
        'type': 'server_vad',
        'silence_duration_ms': vadSilenceMs,
      },
      // ✅ transcripción entrada: español
      'input_audio_transcription': {
        'model': 'gpt-4o-mini-transcribe',
        'language': 'es',
        'prompt': 'Transcribe únicamente en español (es).',
      },
      if (_sessionInstructions.trim().isNotEmpty)
        'instructions': _sessionInstructions.trim(),
    };

    _channel?.sink.add(jsonEncode({
      'type': 'session.update',
      'session': session,
    }));
  }

  void updateSessionInstructions(String instructions) {
    _sessionInstructions = instructions.trim();
    _updateSession();
  }

  void appendAudio(Uint8List audioChunk) {
    if (audioChunk.isEmpty) return;
    _bufferedAudioBytes += audioChunk.length;
    final encoded = base64Encode(audioChunk);
    if (showEvents) {
      debugPrint('OpenAI[$sourceTag] appendAudio ${audioChunk.length} bytes');
    }
    _channel?.sink.add(jsonEncode({
      'type': 'input_audio_buffer.append',
      'audio': encoded,
    }));
  }

  Future<bool> commitBuffer() async {
    if (_bufferedAudioBytes < _minCommitBytes) {
      if (showEvents) {
        debugPrint(
          'OpenAI[$sourceTag] skip commitBuffer: only $_bufferedAudioBytes bytes buffered',
        );
      }
      return false;
    }
    if (_channel == null) return false;
    if (showEvents) debugPrint('OpenAI[$sourceTag] commitBuffer');
    _channel?.sink.add(jsonEncode({'type': 'input_audio_buffer.commit'}));
    _bufferedAudioBytes = 0;
    return true;
  }

  Future<void> requestResponse({required String instructions}) async {
    if (showEvents) debugPrint('OpenAI[$sourceTag] requestResponse');
    _completedThisTurn = false; // nuevo turno/respuesta
    _assistantStreamMode = null;
    _activeResponseId = null;
    _userTranscriptAccum.clear();

    // Opcional: si hay transcript en progreso, cerralo antes de pedir respuesta
    _forceCloseTranscriptLine();

    _channel?.sink.add(jsonEncode({
      'type': 'response.create',
      'response': {
        'modalities': ['text'],
        'instructions': instructions,
      },
    }));
  }

  Future<void> close() async {
    _transcriptIdleTimer?.cancel();
    _transcriptIdleTimer = null;
    _userTranscriptAccum.clear();
    _bufferedAudioBytes = 0;

    await _channel?.sink.close();
    _channel = null;
  }

  void _handleMessage(dynamic event) {
    if (event is! String) return;

    if (showEvents) {
      debugPrint('OpenAI raw: $event');
    }

    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(event) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = payload['type'] as String?;
    if (type == null) return;

    // =========================
    // 0) ERRORES GLOBALES
    // =========================
    if (type == 'error') {
      final msg = _extractErrorMessage(payload);
      debugPrint('OpenAI[$sourceTag] ERROR: $msg');
      if (_isIgnorableError(payload)) {
        return;
      }
      _safeCompleteOnce(reason: 'type=error');
      return;
    }

    // =========================
    // 1) TRANSCRIPCIÓN (USUARIO)
    // =========================
    if (type == 'conversation.item.input_audio_transcription.delta') {
      final itemId = _getTranscriptItemId(payload);
      final t = _extractTranscriptFromTranscriptionEvent(payload);
      if (t.isEmpty) return;

      final prev = _userTranscriptAccum[itemId] ?? '';
      _userTranscriptAccum[itemId] = prev + t;

      // preview en vivo: SOLO delta
      onTranscriptDelta(t);
      _bumpTranscriptIdleFlush();
      return;
    }

    if (type == 'conversation.item.input_audio_transcription.completed') {
      final itemId = _getTranscriptItemId(payload);
      final finalText = _extractTranscriptFromTranscriptionEvent(payload).trim();
      if (finalText.isEmpty) return;

      final prev = _userTranscriptAccum[itemId] ?? '';
      final diff = _diffTranscript(prev, finalText);

      // manda SOLO lo faltante + salto de línea
      if (diff.isNotEmpty) onTranscriptDelta(diff);
      onTranscriptDelta('\n');

      _transcriptIdleTimer?.cancel();
      _transcriptIdleTimer = null;
      _hasOpenTranscript = false;
      _userTranscriptAccum.remove(itemId);
      return;
    }

    // Algunas variantes (depende del modelo / backend)
    if (type.startsWith('speech_transcript')) {
      final t = _extractAnyText(payload).trim();
      if (t.isNotEmpty) {
        onTranscriptDelta(t);
        _bumpTranscriptIdleFlush();
      }
      return;
    }

    final response = payload['response'];
    if (response is Map) {
      final rid = response['id'];
      if (rid is String && rid.isNotEmpty) {
        _activeResponseId ??= rid;
      }
    }

    // =========================
    // 2) TEXTO DEL ASISTENTE (ELEGIR 1 SOLO STREAM)
    // =========================
    final isOutputText = (type == 'response.output_text.delta' ||
        type == 'response.text.delta' ||
        type == 'response.output_text.done' ||
        type == 'response.text.done');

    if (isOutputText) {
      _assistantStreamMode ??= 'output_text';
      if (_assistantStreamMode != 'output_text') return;

      final delta = _extractAnyText(payload);
      if (delta.isNotEmpty) onDelta(delta);

      if (type.endsWith('.done')) {
        _safeCompleteOnce(reason: type);
      }
      return;
    }

    final isOutputItem = (type == 'response.output_item.added' ||
        type == 'response.output_item.delta' ||
        type == 'response.output_item.done');

    if (isOutputItem) {
      final delta = _extractAssistantDeltaFromOutputItem(payload);

      if (delta.trim().isEmpty) {
        if (type == 'response.output_item.done') {
          _safeCompleteOnce(reason: type);
        }
        return;
      }

      _assistantStreamMode ??= 'output_item';
      if (_assistantStreamMode != 'output_item') return;

      onDelta(delta);

      if (type == 'response.output_item.done') {
        _safeCompleteOnce(reason: type);
      }
      return;
    }

    if (type == 'response.delta') {
      _assistantStreamMode ??= 'response_delta';
      if (_assistantStreamMode != 'response_delta') return;

      final delta = _extractAssistantDeltaFromResponseDelta(payload);
      if (delta.trim().isNotEmpty) onDelta(delta);
      return;
    }

    if (type == 'response.audio_transcript.delta' ||
        type == 'response.audio_transcript.done') {
      _assistantStreamMode ??= 'audio_transcript';
      if (_assistantStreamMode != 'audio_transcript') return;

      final delta = _extractAnyText(payload);
      if (delta.trim().isNotEmpty) onDelta(delta);

      if (type.endsWith('.done')) {
        _safeCompleteOnce(reason: type);
      }
      return;
    }

    // =========================
    // 3) FIN DE RESPUESTA
    // =========================
    if (type == 'response.done' ||
        type == 'response.completed' ||
        type == 'response.failed' ||
        type == 'response.cancelled' ||
        type == 'response.error') {
      if (type == 'response.error') {
        final msg = _extractErrorMessage(payload);
        debugPrint('OpenAI response.error: $msg');
      }
      _safeCompleteOnce(reason: type);
      return;
    }

    if (type.startsWith('response.') && type.endsWith('.completed')) {
      _safeCompleteOnce(reason: type);
      return;
    }
  }

  void _safeCompleteOnce({required String reason}) {
    if (_completedThisTurn) return;
    _completedThisTurn = true;

    if (showEvents) {
      debugPrint('OpenAI[$sourceTag] onComplete() reason=$reason');
    }
    onComplete?.call();
  }

  String _extractErrorMessage(Map<String, dynamic> payload) {
    final err = payload['error'];
    if (err is Map) {
      final message = err['message'];
      final type = err['type'];
      final code = err['code'];
      return 'type=$type code=$code message=$message';
    }
    final msg = payload['message'];
    if (msg is String) return msg;
    return payload.toString();
  }

  bool _isIgnorableError(Map<String, dynamic> payload) {
    final err = payload['error'];
    if (err is! Map) return false;

    final code = (err['code'] as String? ?? '').trim().toLowerCase();
    final message = (err['message'] as String? ?? '').trim().toLowerCase();

    if (code == 'input_audio_buffer_commit_empty') return true;
    if (message.contains('buffer too small') &&
        message.contains('input audio buffer')) {
      return true;
    }
    return false;
  }

  /// Extrae texto SOLO de eventos de transcripción.
  String _extractTranscriptFromTranscriptionEvent(Map<String, dynamic> payload) {
    final delta = payload['delta'];
    if (delta is String && delta.trim().isNotEmpty) return delta;

    final item = payload['item'];
    if (item is Map) {
      final content = item['content'];
      if (content is List && content.isNotEmpty) {
        final first = content.first;
        if (first is Map) {
          final text = first['text'];
          if (text is String && text.trim().isNotEmpty) return text;
        }
      }
    }

    final t = _extractAnyText(payload).trim();
    if (t.isEmpty) return '';

    final lower = t.toLowerCase();
    if (lower.contains('chat:') ||
        lower.contains('sugerencias:') ||
        lower.contains('pregunta sugerida:') ||
        lower.contains('respuesta sugerida:') ||
        lower.contains('objecion detectada:') ||
        lower.contains('momento de cierre:')) {
      return '';
    }
    return t;
  }

  String _getTranscriptItemId(Map<String, dynamic> payload) {
    final itemId = payload['item_id'];
    if (itemId is String && itemId.isNotEmpty) return itemId;

    final item = payload['item'];
    if (item is Map) {
      final id = item['id'];
      if (id is String && id.isNotEmpty) return id;
    }

    // fallback (último recurso)
    return '${payload['type']}_${payload.hashCode}';
  }

  String _diffTranscript(String previous, String current) {
    if (previous.isEmpty) return current;
    if (current.startsWith(previous)) return current.substring(previous.length);
    // si el backend reescribe (no es prefijo), devolvemos todo el current
    return current;
  }

  /// Extrae texto “simple” (delta/text/transcript/content) desde payload genérico.
  String _extractAnyText(Map<String, dynamic> payload) {
    final delta = payload['delta'];
    if (delta is String) return delta;
    if (delta is Map) {
      final t = delta['text'];
      if (t is String) return t;
      final c = delta['content'];
      if (c is String) return c;
      final tr = delta['transcript'];
      if (tr is String) return tr;
    }

    final transcript = payload['transcript'];
    if (transcript is String) return transcript;

    final text = payload['text'];
    if (text is String) return text;

    final value = payload['value'];
    if (value is String) return value;

    return _findFirstString(payload,
            keys: const ['delta', 'text', 'transcript', 'content', 'value']) ??
        '';
  }

  String _extractAssistantDeltaFromResponseDelta(Map<String, dynamic> payload) {
    final response = payload['response'];
    if (response is! Map) return '';

    final output = response['output'];
    if (output is! List) return '';

    final sb = StringBuffer();
    for (final item in output) {
      if (item is! Map) continue;

      final content = item['content'];
      if (content is! List) continue;

      for (final c in content) {
        if (c is! Map) continue;
        final cType = c['type'];
        if (cType == 'output_text') {
          final text = c['text'];
          if (text is String && text.isNotEmpty) sb.write(text);
        }
        final d = c['delta'];
        if (d is String && d.isNotEmpty) sb.write(d);
      }
    }
    return sb.toString();
  }

  String _extractAssistantDeltaFromOutputItem(Map<String, dynamic> payload) {
    final item = payload['item'];
    if (item is! Map) return '';

    final content = item['content'];
    if (content is! List) return '';

    final sb = StringBuffer();
    for (final c in content) {
      if (c is! Map) continue;

      final cType = c['type'];
      if (cType == 'output_text') {
        final text = c['text'];
        if (text is String && text.isNotEmpty) sb.write(text);
      }

      final d = c['delta'];
      if (d is String && d.isNotEmpty) sb.write(d);
    }
    return sb.toString();
  }

  String? _findFirstString(dynamic node, {required List<String> keys}) {
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key;
        final value = entry.value;

        if (keys.contains(key) && value is String && value.isNotEmpty) {
          return value;
        }
        final nested = _findFirstString(value, keys: keys);
        if (nested != null) return nested;
      }
    } else if (node is List) {
      for (final value in node) {
        final nested = _findFirstString(value, keys: keys);
        if (nested != null) return nested;
      }
    }
    return null;
  }
}
