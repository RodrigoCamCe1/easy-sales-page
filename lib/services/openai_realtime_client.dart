import 'dart:convert';
import 'dart:typed_data';
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

  IOWebSocketChannel? _channel;
  String _sessionInstructions = '';

  // Para evitar dobles completes en un mismo “response”
  bool _completedThisTurn = false;
  String? _assistantStreamMode;
  String? _activeResponseId;

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
        // Si se cerró sin complete, mejor cerrar la UI de forma segura
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
    final encoded = base64Encode(audioChunk);
    if (showEvents) {
      debugPrint('OpenAI appendAudio ${audioChunk.length} bytes');
    }
    _channel?.sink.add(jsonEncode({
      'type': 'input_audio_buffer.append',
      'audio': encoded,
    }));
  }

  Future<void> commitBuffer() async {
    if (showEvents) debugPrint('OpenAI commitBuffer');
    _channel?.sink.add(jsonEncode({'type': 'input_audio_buffer.commit'}));
  }

  Future<void> requestResponse({required String instructions}) async {
    if (showEvents) debugPrint('OpenAI requestResponse');
    _completedThisTurn = false; // nuevo turno/respuesta
    _assistantStreamMode = null;
    _activeResponseId = null;
    

    _channel?.sink.add(jsonEncode({
      'type': 'response.create',
      'response': {
        'modalities': ['text'],
        // refuerzo por si la sesión no aplicó
        'input_audio_transcription': {
          'model': 'gpt-4o-mini-transcribe',
          'language': 'es',
          'prompt': 'Transcribe únicamente en español (es).',
        },
        'instructions': instructions,
      },
    }));
  }

  Future<void> close() async {
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
    // A veces llega {"type":"error", "error": {...}}
    if (type == 'error') {
      final msg = _extractErrorMessage(payload);
      debugPrint('OpenAI ERROR: $msg');
      _safeCompleteOnce(reason: 'type=error');
      return;
    }

    // =========================
    // 1) TRANSCRIPCIÓN (USUARIO)
    // =========================
    // Realtime típico:
    // conversation.item.input_audio_transcription.delta/completed
    // input_audio_transcription.delta/completed
    if (type == 'conversation.item.input_audio_transcription.delta' ) {
      final t = _extractTranscriptFromTranscriptionEvent(payload);
      if (t.isNotEmpty) onTranscriptDelta(t);
      return;
    }

    if (type == 'conversation.item.input_audio_transcription.completed') {
      final t = _extractTranscriptFromTranscriptionEvent(payload);
      if (t.isNotEmpty) onTranscriptDelta('$t\n');
      return;
    }

    // Algunas variantes (depende del modelo / backend)
    if (type.startsWith('speech_transcript')) {
      final t = _extractAnyText(payload).trim();
      if (t.isNotEmpty) onTranscriptDelta(t);
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

// 2.1 Preferido: output_text (más directo)
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

// 2.2 Alternativo: output_item (algunos backends lo usan)
final isOutputItem = (type == 'response.output_item.added' ||
    type == 'response.output_item.delta' ||
    type == 'response.output_item.done');

if (isOutputItem) {
  // 1) Extrae primero el delta
  final delta = _extractAssistantDeltaFromOutputItem(payload);

  // 2) Si viene vacío, NO fijes el modo todavía
  //    (porque a veces "added" llega sin texto y luego el texto llega por output_text)
  if (delta.trim().isEmpty) {
    if (type == 'response.output_item.done') {
      _safeCompleteOnce(reason: type);
    }
    return;
  }

  // 3) Recién aquí fijamos el modo
  _assistantStreamMode ??= 'output_item';
  if (_assistantStreamMode != 'output_item') return;

  // 4) Emitir texto
  onDelta(delta);

  // 5) Cierre si corresponde
  if (type == 'response.output_item.done') {
    _safeCompleteOnce(reason: type);
  }
  return;
}


// 2.3 Fallback: response.delta (más genérico)
if (type == 'response.delta') {
  _assistantStreamMode ??= 'response_delta';
  if (_assistantStreamMode != 'response_delta') return;

  final delta = _extractAssistantDeltaFromResponseDelta(payload);
  if (delta.trim().isNotEmpty) onDelta(delta);
  return;
}

// 2.4 Último fallback: audio_transcript (si estás usando salida de audio)
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
    // Variantes reales que suelen aparecer:
    // response.done, response.completed, response.failed, response.cancelled
    // response.error, response.output_text.done (ya cubierto arriba)
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

    // Algunos otros cierres raros:
    if (type.startsWith('response.') && type.endsWith('.completed')) {
      _safeCompleteOnce(reason: type);
      return;
    }
  }

  void _safeCompleteOnce({required String reason}) {
    if (_completedThisTurn) return;
    _completedThisTurn = true;

    if (showEvents) {
      debugPrint('OpenAI onComplete() reason=$reason');
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

  /// Extrae texto SOLO de eventos de transcripción.
  String _extractTranscriptFromTranscriptionEvent(
      Map<String, dynamic> payload) {
    // 1) Formato común: payload['delta'] = "..."
    final delta = payload['delta'];
    if (delta is String && delta.trim().isNotEmpty) return delta;

    // 2) Otro formato: payload['item']['content'][0]['text']
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

    // 3) Fallback “seguro”
    final t = _extractAnyText(payload).trim();
    if (t.isEmpty) return '';

    // Si parece salida del asistente, no es transcript de usuario
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

    // A veces viene en payload['value']
    final value = payload['value'];
    if (value is String) return value;

    // fallback profundo
    return _findFirstString(payload,
            keys: const ['delta', 'text', 'transcript', 'content', 'value']) ??
        '';
  }

  /// response.delta suele traer: response.output -> items -> content -> {type:"output_text", text:"..."}
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
        // a veces viene delta dentro
        final d = c['delta'];
        if (d is String && d.isNotEmpty) sb.write(d);
      }
    }
    return sb.toString();
  }

  /// response.output_item.* a veces trae un item con content/output_text
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
