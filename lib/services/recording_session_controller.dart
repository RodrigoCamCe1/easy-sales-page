import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/app_config.dart';
import '../models/conversation.dart';
import '../models/session_models.dart';
import 'auth_session_manager.dart';
import 'backend_data_api.dart';
import 'conversation_store.dart';
import 'openai_realtime_client.dart';
import 'realtime_session_api.dart';
import 'store_helpers.dart';

class RecordingSessionController extends ChangeNotifier {
  // ── Dispose guard ───────────────────────────────────────────────────────
  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // ── Mutable config pushed by the widget before startListening ───────────
  String promptOverride = '';
  String activeAgentId = '';
  bool micMixEnabled = false;
  bool freestyleMode = false;
  String? lastSavedConversationId;

  // ── Scroll / platform callbacks wired by widget in initState ────────────
  VoidCallback? onScrollChatToBottom;
  VoidCallback? onScrollTranscriptToBottom;
  VoidCallback? onScrollSuggestionsToBottom;

  /// Called when the controller wants the widget to start FlutterAudioCapture.
  VoidCallback? onRequestStartPlatformCapture;

  /// Called when the controller wants the widget to stop FlutterAudioCapture.
  VoidCallback? onRequestStopPlatformCapture;

  /// Called when the platform audio capture reports an error.
  void Function(String error)? onPlatformCaptureError;

  // ── Private session state ────────────────────────────────────────────────
  bool _listening = false;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  Timer? _realtimeTimer;
  Timer? _uiTranscriptIdleTimer;
  Timer? _queuedResponseDelayTimer;
  Timer? _silenceAutoStopTimer;

  int _pendingMicBytes = 0;
  int _pendingSystemBytes = 0;

  bool _responseInFlight = false;
  bool _micResponseInFlight = false;
  bool _finalResponseQueued = false;
  String _queuedResponseSource = 'sys';

  int _assistantTurnSeq = 0;
  int? _activeAssistantTurnId;
  DateTime? _lastVoiceTriggerAt;
  String _lastVoiceTriggerKey = '';
  int? _streamingAssistantIndex;
  String _streamingAssistantText = '';
  bool _assistantStreamStarted = false;
  DateTime? _lastLevelLogAt;

  String _currentResponse = '';
  final List<ChatMessage> _chatResponses = [];
  final List<String> _suggestions = [];
  final List<String> _transcripts = [];
  String _currentTranscriptSys = '';
  String _currentTranscriptMic = '';
  String? _lastSysLine;
  String? _lastMicLine;
  DateTime? _lastMicTranscriptAt;
  int _systemWordsAccum = 0;
  int _systemWordsAtLastResponse = 0;

  String _statusMessage = '';
  DateTime? _sessionStartedAt;
  DateTime? _sessionEndedAt;

  String _ragContext = '';

  OpenAIRealtimeClient? _openAIClientMic;
  OpenAIRealtimeClient? _openAIClientSystem;
  Process? _audioProcessSystem;
  Process? _audioProcessMic;
  StreamSubscription<List<int>>? _audioSubscriptionSystem;
  StreamSubscription<List<int>>? _audioSubscriptionMic;

  // ── Public read-only state ───────────────────────────────────────────────
  bool get listening => _listening;
  Duration get elapsed => _elapsed;
  String get statusMessage => _statusMessage;
  bool get responseInFlight => _responseInFlight;
  bool get micResponseInFlight => _micResponseInFlight;
  int? get streamingAssistantIndex => _streamingAssistantIndex;
  String get streamingAssistantText => _streamingAssistantText;
  int? get activeAssistantTurnId => _activeAssistantTurnId;
  List<ChatMessage> get chatResponses => List.unmodifiable(_chatResponses);
  List<String> get suggestions => List.unmodifiable(_suggestions);
  List<String> get transcripts => List.unmodifiable(_transcripts);
  String get currentTranscriptSys => _currentTranscriptSys;
  String get currentTranscriptMic => _currentTranscriptMic;
  DateTime? get sessionStartedAt => _sessionStartedAt;
  DateTime? get sessionEndedAt => _sessionEndedAt;

  // ── Platform helpers ─────────────────────────────────────────────────────
  bool get _systemOnlyMode => Platform.isWindows;
  bool get _windowsMicAvailable =>
      Platform.isWindows && windowsMicDevice.trim().isNotEmpty;
  bool get _audioSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isLinux;

  // ── Constants ────────────────────────────────────────────────────────────
  static const Duration _voiceResponseMinInterval = Duration(seconds: 15);
  static const int _transcriptIdleFlushMs = 1700;
  static const Duration _micTranscriptMergeWindow = Duration(seconds: 6);
  static const Duration _autoStopSilenceTimeout = Duration(seconds: 21);
  static const int _minSystemWordsPerTurn = 15;
  static const int _minSystemCharsPerTurn = 60;
  static const int _novelSystemWordsToBypassCooldown = 15;

  // ── Chat prefixes ────────────────────────────────────────────────────────
  static const List<String> _chatPrefixes = [
    'Respuesta sugerida:',
    'Objeción detectada:',
    'Objecion detectada:',
    'Momento de cierre:',
  ];
  static const String _suggestionPrefix = 'Pregunta sugerida:';

  // ──────────────────────────────────────────────────────────────────────────
  // PUBLIC API
  // ──────────────────────────────────────────────────────────────────────────

  void applyUpdatedPrompt() {
    _openAIClientMic?.updateSessionInstructions(_buildSessionInstructions());
    _openAIClientSystem?.updateSessionInstructions(_buildSessionInstructions());
  }

  /// Entry point from the non-Windows platform audio capture callback.
  void appendMicAudioFromPlatform(List<double> floatData) {
    final bytes = _floatTo16(floatData);
    _appendAudio(bytes);
  }

  Future<void> startListening() async {
    if (_listening) return;

    final resolvedKey = await _resolveOpenAIToken();
    if (resolvedKey.isEmpty) {
      _statusMessage =
          'No se pudo obtener credenciales de OpenAI. Configura OPENAI_API_KEY en el backend.';
      _safeNotify();
      return;
    }

    await _openAIClientMic?.close();
    await _openAIClientSystem?.close();
    _openAIClientMic = null;
    _openAIClientSystem = null;

    _uiTranscriptIdleTimer?.cancel();
    _uiTranscriptIdleTimer = null;
    _queuedResponseDelayTimer?.cancel();
    _queuedResponseDelayTimer = null;
    _silenceAutoStopTimer?.cancel();
    _silenceAutoStopTimer = null;

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _elapsed = Duration(seconds: timer.tick);
      _safeNotify();
    });

    _sessionStartedAt = DateTime.now();
    _sessionEndedAt = null;
    _pendingMicBytes = 0;
    _pendingSystemBytes = 0;
    _responseInFlight = false;
    _micResponseInFlight = false;
    _finalResponseQueued = false;
    _queuedResponseSource = _systemOnlyMode ? 'sys' : 'mic';
    _assistantTurnSeq = 0;
    _activeAssistantTurnId = null;
    _lastVoiceTriggerAt = null;
    _lastVoiceTriggerKey = '';
    _chatResponses.clear();
    _suggestions.clear();
    _currentResponse = '';
    _transcripts.clear();
    _currentTranscriptSys = '';
    _currentTranscriptMic = '';
    _lastSysLine = null;
    _lastMicLine = null;
    _lastMicTranscriptAt = null;
    _systemWordsAccum = 0;
    _systemWordsAtLastResponse = 0;
    _statusMessage = 'Conectando con OpenAI';

    _addLog('Iniciando sesion con OpenAI');
    final promptPreview = promptOverride.length > 120
        ? '${promptOverride.substring(0, 120)}...'
        : promptOverride;
    _addLog('Prompt activo: $promptPreview');

    // RAG: fetch relevant document chunks before connecting
    _ragContext = '';
    if (activeAgentId.isNotEmpty) {
      _addLog('Buscando contexto RAG para agente $activeAgentId...');
      _ragContext = await _fetchRAGContext(promptOverride);
      if (_ragContext.isNotEmpty) {
        _addLog('Contexto RAG obtenido (${_ragContext.length} chars)');
      }
    }

    _openAIClientMic = OpenAIRealtimeClient(
      openAIKey: resolvedKey,
      model: openAIRealtimeModel,
      vadSilenceMs: vadSilenceMs,
      transcriptionOnly: true,
      onDelta: (_) {},
      onTranscriptDelta: (t) => _appendTranscriptDelta(t, source: 'mic'),
      onComplete: () => _appendTranscriptDelta('\n', source: 'mic'),
      showEvents: showOpenAIEvents,
      sourceTag: 'mic',
    );

    _openAIClientSystem = null;
    final hasSystemDevice =
        Platform.isWindows && windowsAudioDevice.trim().isNotEmpty;
    if (hasSystemDevice) {
      _openAIClientSystem = OpenAIRealtimeClient(
        openAIKey: resolvedKey,
        model: openAIRealtimeModel,
        vadSilenceMs: vadSilenceMs,
        sessionInstructions: _buildSessionInstructions(),
        onDelta: _appendResponseDelta,
        onTranscriptDelta: (t) => _appendTranscriptDelta(t, source: 'sys'),
        onComplete: () {
          _appendTranscriptDelta('\n', source: 'sys');
          _handleResponseComplete();
        },
        showEvents: showOpenAIEvents,
        sourceTag: 'system',
      );
    }

    try {
      await _openAIClientMic?.connect();
      await _openAIClientSystem?.connect();
    } catch (error) {
      _listening = false;
      _statusMessage = 'No se pudo conectar con OpenAI: $error';
      _safeNotify();
      _timer?.cancel();
      _elapsed = Duration.zero;
      return;
    }

    _listening = true;
    _statusMessage = Platform.isWindows
        ? 'Conectado a OpenAI. Escuchando audio del sistema...'
        : 'Conectado a OpenAI. Escuchando microfono...';
    _safeNotify();
    _scheduleSilenceAutoStop();

    if (Platform.isWindows) {
      await _startWindowsCapture();
    } else if (_audioSupported) {
      onRequestStartPlatformCapture?.call();
    } else {
      _statusMessage = 'Captura de sistema no disponible en esta plataforma.';
      _listening = false;
      _safeNotify();
    }

    _realtimeTimer?.cancel();
    _realtimeTimer = Timer.periodic(
      Duration(seconds: realtimeFlushSeconds),
      (_) => _flushRealtimeBoth(),
    );
  }

  Future<void> stopListening() async {
    if (!_listening) return;

    _timer?.cancel();
    _realtimeTimer?.cancel();
    _realtimeTimer = null;
    _queuedResponseDelayTimer?.cancel();
    _queuedResponseDelayTimer = null;
    _silenceAutoStopTimer?.cancel();
    _silenceAutoStopTimer = null;

    _appendTranscriptDelta('\n', source: 'sys');
    _appendTranscriptDelta('\n', source: 'mic');

    _sessionEndedAt = DateTime.now();

    if (Platform.isWindows) {
      await _stopWindowsCapture();
    } else if (_audioSupported) {
      _addLog('Deteniendo flutter_audio_capture');
      onRequestStopPlatformCapture?.call();
    }

    if (_pendingSystemBytes > 0) {
      final committed = await _openAIClientSystem?.commitBuffer() ?? false;
      if (committed) _pendingSystemBytes = 0;
    }
    if (_pendingMicBytes > 0) {
      final committed = await _openAIClientMic?.commitBuffer() ?? false;
      if (committed) _pendingMicBytes = 0;
    }

    _listening = false;
    _elapsed = Duration.zero;
    _statusMessage = 'Procesando respuesta';
    _safeNotify();

    if (!_micResponseInFlight && !_responseInFlight && !_finalResponseQueued) {
      await _openAIClientMic?.close();
      _openAIClientMic = null;
      await _openAIClientSystem?.close();
      _openAIClientSystem = null;
      await _maybeSaveConversation();
    }
  }

  Future<void> sendManualPrompt(String prompt) async {
    if (prompt.isEmpty) return;

    final resolvedKey = await _resolveOpenAIToken();
    if (resolvedKey.isEmpty) {
      _statusMessage =
          'No se pudo obtener credenciales de OpenAI. Configura OPENAI_API_KEY en el backend.';
      _safeNotify();
      return;
    }

    _chatResponses.add(ChatMessage(role: 'user', text: prompt));
    _safeNotify();
    onScrollChatToBottom?.call();

    if (_openAIClientSystem == null && _openAIClientMic == null) {
      _openAIClientMic = OpenAIRealtimeClient(
        openAIKey: resolvedKey,
        model: openAIRealtimeModel,
        vadSilenceMs: vadSilenceMs,
        sessionInstructions: _buildSessionInstructions(),
        onDelta: _appendResponseDelta,
        onTranscriptDelta: (t) => _appendTranscriptDelta(t, source: 'mic'),
        onComplete: () {
          _appendTranscriptDelta('\n', source: 'mic');
          _handleResponseComplete();
        },
        showEvents: showOpenAIEvents,
        sourceTag: 'mic',
      );
      await _openAIClientMic?.connect();
    }

    final responseClient = _openAIClientSystem ?? _openAIClientMic;
    _sessionStartedAt ??= DateTime.now();
    _sessionEndedAt = DateTime.now();

    _statusMessage = 'Enviando prompt manual';
    _responseInFlight = true;
    _micResponseInFlight = true;
    _assistantTurnSeq += 1;
    _activeAssistantTurnId = _assistantTurnSeq;
    _safeNotify();

    _appendTranscriptDelta('\n', source: 'mic');

    final ctx = _buildRecentContext();
    final manualInstructions = [
      'Mensaje del usuario (prioritario para este turno):\n$prompt',
      if (ctx.isNotEmpty) ctx,
    ].join('\n\n');

    await responseClient?.requestResponse(instructions: manualInstructions);
  }

  Future<void> setMicMixEnabled(bool enabled) async {
    if (_systemOnlyMode) {
      final shouldEnableMic = _windowsMicAvailable;
      if (micMixEnabled != shouldEnableMic) {
        micMixEnabled = shouldEnableMic;
        _statusMessage = shouldEnableMic
            ? 'Modo fijo: chat por sistema + transcripcion sistema/microfono.'
            : 'Modo fijo: chat por sistema.';
        _safeNotify();
        if (Platform.isWindows && _listening) {
          await _stopWindowsCapture();
          await _startWindowsCapture();
        }
      }
      return;
    }

    if (!_windowsMicAvailable && enabled) {
      _statusMessage =
          'No hay microfono configurado. Define WINDOWS_MIC_DEVICE en .env.';
      _safeNotify();
      return;
    }
    if (micMixEnabled == enabled) return;

    micMixEnabled = enabled;
    _safeNotify();

    if (Platform.isWindows && _listening) {
      await _stopWindowsCapture();
      await _startWindowsCapture();
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // UI HELPERS (called from build())
  // ──────────────────────────────────────────────────────────────────────────

  String buildSuggestionsText() {
    final unique = <String>{};
    for (final s in _suggestions) {
      final c = s.trim();
      if (c.isNotEmpty) unique.add(c);
    }
    if (unique.isEmpty) {
      return 'Aun no hay sugerencias.\n\n'
          'Presiona Iniciar y habla (o envia un prompt manual) para que la IA genere sugerencias.';
    }
    return unique.map((line) => '• $line').join('\n');
  }

  List<TranscriptEntry> buildTranscriptEntries() {
    final committed = <TranscriptEntry>[];

    for (final transcript in _transcripts) {
      final t = transcript.trim();
      if (t.isEmpty) continue;

      if (RegExp(r'^(🎤|ðŸŽ¤)\s*').hasMatch(t)) {
        committed.add(TranscriptEntry(
          text: t.replaceFirst(RegExp(r'^(🎤|ðŸŽ¤)\s*'), '').trim(),
          isMic: true,
        ));
      } else if (RegExp(r'^(🖥️|🖥|ðŸ–¥ï¸|ðŸ–¥)\s*').hasMatch(t)) {
        committed.add(TranscriptEntry(
          text: t.replaceFirst(RegExp(r'^(🖥️|🖥|ðŸ–¥ï¸|ðŸ–¥)\s*'), '').trim(),
          isMic: false,
        ));
      } else {
        committed.add(TranscriptEntry(text: t, isMic: false));
      }
    }

    final out = _normalizeTranscriptEntries(committed);

    final currentSys = _currentTranscriptSys.trim();
    if (currentSys.isNotEmpty) {
      out.add(TranscriptEntry(text: currentSys, isMic: false, pending: true));
    }
    final currentMic = _currentTranscriptMic.trim();
    if (currentMic.isNotEmpty) {
      out.add(TranscriptEntry(text: currentMic, isMic: true, pending: true));
    }

    return out;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // STREAMING
  // ──────────────────────────────────────────────────────────────────────────

  void _appendResponseDelta(String delta) {
    if (delta.isEmpty) return;

    _currentResponse += delta;
    _statusMessage = 'Respuesta en pantalla';

    if (!_assistantStreamStarted) {
      _assistantStreamStarted = true;
      _chatResponses.add(ChatMessage(
        role: 'assistant',
        text: '',
        assistantTurnId: _activeAssistantTurnId,
        isFreestyle: freestyleMode,
      ));
      _streamingAssistantIndex = _chatResponses.length - 1;
    }

    _streamingAssistantText = _buildStreamingChatPreview(_currentResponse);
    final idx = _streamingAssistantIndex;
    if (idx != null && idx >= 0 && idx < _chatResponses.length) {
      final visible = _streamingAssistantText.trim();
      _chatResponses[idx] = ChatMessage(
        role: 'assistant',
        text: visible.isEmpty ? '...' : visible,
        assistantTurnId: _activeAssistantTurnId,
        isFreestyle: freestyleMode,
      );
    }

    _safeNotify();
    onScrollChatToBottom?.call();
  }

  void _appendTranscriptDelta(String text, {String source = 'sys'}) {
    if (text.isEmpty) return;
    if (text != '\n' && text.trim().isNotEmpty) {
      _scheduleSilenceAutoStop();
    }

    source = source.toLowerCase().trim();
    if (source != 'mic') source = 'sys';

    void flushOneLine({required bool isMic}) {
      final buf = isMic ? _currentTranscriptMic : _currentTranscriptSys;
      final chunk = buf.trim();
      if (chunk.isEmpty) return;

      final cleaned = _cleanTranscriptChunk(chunk);
      if (cleaned != null && cleaned.trim().isNotEmpty) {
        final normalized = cleaned.trim();
        final tagged = isMic ? '🎤 $cleaned' : '🖥️ $cleaned';

        if (isMic) {
          if (_lastMicLine != tagged) {
            final now = DateTime.now();
            final merged = _tryMergeMicTranscript(cleaned, now);
            if (!merged) _transcripts.add(tagged);
            _lastMicLine = tagged;
            _lastMicTranscriptAt = now;
            _triggerResponseFromTranscript(
              source: 'mic',
              transcriptLine: normalized,
            );
          }
        } else {
          if (_lastSysLine != tagged) {
            _transcripts.add(tagged);
            _lastSysLine = tagged;
            _lastMicTranscriptAt = null;
            _systemWordsAccum += _wordCount(normalized);
            _triggerResponseFromTranscript(
              source: 'sys',
              transcriptLine: normalized,
            );
          }
        }
      }

      if (isMic) {
        _currentTranscriptMic = '';
      } else {
        _currentTranscriptSys = '';
      }
    }

    void bumpIdleFlush({required bool isMic, int ms = _transcriptIdleFlushMs}) {
      _uiTranscriptIdleTimer?.cancel();
      _uiTranscriptIdleTimer = Timer(Duration(milliseconds: ms), () {
        flushOneLine(isMic: isMic);
        _safeNotify();
        onScrollTranscriptToBottom?.call();
      });
    }

    final isMic = source == 'mic';

    if (text == '\n') {
      flushOneLine(isMic: isMic);
    } else {
      if (isMic) {
        _currentTranscriptMic += text;
      } else {
        _currentTranscriptSys += text;
      }
    }

    String working = isMic ? _currentTranscriptMic : _currentTranscriptSys;
    while (working.contains('\n')) {
      final idx = working.indexOf('\n');
      final line = working.substring(0, idx);
      if (isMic) {
        _currentTranscriptMic = line;
      } else {
        _currentTranscriptSys = line;
      }
      flushOneLine(isMic: isMic);
      working = working.substring(idx + 1);
    }

    if (isMic) {
      _currentTranscriptMic = working;
    } else {
      _currentTranscriptSys = working;
    }

    _safeNotify();

    if (text != '\n') {
      bumpIdleFlush(isMic: isMic);
    }

    onScrollTranscriptToBottom?.call();
  }

  void _handleResponseComplete() {
    _statusMessage = 'Respuesta completa';
    _safeNotify();

    final parsed = _parseAssistantOutput(_currentResponse);

    // ── Suggestions ──
    final suggestions = parsed['suggestions'] as List<String>;
    if (suggestions.isNotEmpty) {
      final existing = _suggestions.map((e) => e.trim().toLowerCase()).toSet();
      final toAdd = <String>[];
      for (final s in suggestions) {
        final ns = _normalizeSuggestion(s).trim();
        if (ns.isEmpty) continue;
        final key = ns.toLowerCase();
        if (existing.add(key)) toAdd.add(ns);
      }
      if (toAdd.isNotEmpty) {
        _suggestions.addAll(toAdd);
        _safeNotify();
        onScrollSuggestionsToBottom?.call();
      }
    }

    // ── Chat ──
    final chat = (parsed['chat'] as String).trim();
    final finalLines = <String>[];
    if (chat.isNotEmpty) {
      final normalized = chat
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .map(_normalizeChatLine)
          .where((e) => e.isNotEmpty)
          .toList();
      final seen = <String>{};
      for (final l in normalized) {
        if (seen.add(l)) finalLines.add(l);
      }
    }

    if (finalLines.isEmpty) {
      final fallback = _extractFallbackChatText(_currentResponse);
      if (fallback.isNotEmpty) finalLines.add(fallback);
    }

    final idx = _streamingAssistantIndex;
    if (finalLines.isEmpty) {
      if (idx != null && idx >= 0 && idx < _chatResponses.length) {
        final fallback = _streamingAssistantText.trim();
        if (fallback.isNotEmpty) {
          _chatResponses[idx] = ChatMessage(
            role: 'assistant',
            text: fallback,
            assistantTurnId: _activeAssistantTurnId,
            isFreestyle: freestyleMode,
          );
        }
      }
    } else {
      if (idx != null && idx >= 0 && idx < _chatResponses.length) {
        _chatResponses.removeAt(idx);
      }
      for (final line in finalLines) {
        if (_chatResponses.isNotEmpty &&
            _chatResponses.last.role == 'assistant' &&
            _chatResponses.last.text.trim() == line) {
          continue;
        }
        _chatResponses.add(ChatMessage(
          role: 'assistant',
          text: line,
          assistantTurnId: _activeAssistantTurnId,
          isFreestyle: freestyleMode,
        ));
      }
    }

    _streamingAssistantIndex = null;
    _streamingAssistantText = '';
    _assistantStreamStarted = false;
    _safeNotify();

    _currentResponse = '';

    _appendTranscriptDelta('\n', source: 'sys');
    _appendTranscriptDelta('\n', source: 'mic');

    onScrollChatToBottom?.call();
    onScrollSuggestionsToBottom?.call();

    _micResponseInFlight = false;
    _responseInFlight = false;
    _activeAssistantTurnId = null;
    _safeNotify();

    if (_finalResponseQueued) {
      final queuedSource = _queuedResponseSource;
      _finalResponseQueued = false;
      final now = DateTime.now();
      final sinceLast = _lastVoiceTriggerAt == null
          ? _voiceResponseMinInterval
          : now.difference(_lastVoiceTriggerAt!);
      if (sinceLast >= _voiceResponseMinInterval) {
        _startVoiceTriggeredResponse(source: queuedSource);
      } else {
        final delay = _voiceResponseMinInterval - sinceLast;
        _queuedResponseDelayTimer?.cancel();
        _queuedResponseDelayTimer = Timer(delay, () {
          if (_disposed || !_listening || _responseInFlight || _micResponseInFlight) {
            return;
          }
          _startVoiceTriggeredResponse(source: queuedSource);
        });
      }
      return;
    }

    if (!_listening) {
      _openAIClientMic?.close();
      _openAIClientMic = null;
      _openAIClientSystem?.close();
      _openAIClientSystem = null;
      _maybeSaveConversation();
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // SAVE
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _maybeSaveConversation() async {
    if (_chatResponses.isEmpty && _transcripts.isEmpty) return;

    final startedAt = _sessionStartedAt ?? DateTime.now();
    final endedAt = _sessionEndedAt ?? DateTime.now();
    final duration = endedAt.difference(startedAt).inSeconds;
    final conversationId = '${startedAt.millisecondsSinceEpoch}';
    if (lastSavedConversationId == conversationId) return;

    final preview = _chatResponses.isNotEmpty
        ? _chatResponses.first.text
        : (_transcripts.isNotEmpty ? _transcripts.first : '');

    final title = _buildTitle(preview);

    final conversation = Conversation(
      id: conversationId,
      title: title,
      preview: preview,
      startedAt: startedAt,
      endedAt: endedAt,
      durationSeconds: duration,
      messages: _chatResponses
          .map((m) => ConversationMessage(role: m.role, text: m.text, at: m.at))
          .toList(),
      suggestions: List<String>.from(_suggestions),
      transcripts: List<String>.from(_transcripts),
    );

    try {
      await ConversationStore.instance.add(conversation);
      lastSavedConversationId = conversationId;
    } catch (error) {
      _addLog('No se pudo guardar conversacion: $error');
      if (!_disposed) {
        _statusMessage = 'No se pudo guardar la asesoria';
        _safeNotify();
      }
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // TRIGGER / RESPONSE CONTROL
  // ──────────────────────────────────────────────────────────────────────────

  void _triggerResponseFromTranscript({
    required String source,
    required String transcriptLine,
  }) {
    if (!_listening) return;
    final normalizedSource = source.toLowerCase().trim() == 'sys' ? 'sys' : 'mic';
    if (normalizedSource != 'sys') return;

    final cleanedLine = transcriptLine.trim();
    if (!_isLikelyVoiceLine(cleanedLine)) return;
    if (cleanedLine.length < _minSystemCharsPerTurn) return;
    if (_wordCount(cleanedLine) < _minSystemWordsPerTurn) return;

    final now = DateTime.now();
    final key = cleanedLine.toLowerCase();
    if (key.isEmpty) return;

    if (_lastVoiceTriggerKey == key &&
        _lastVoiceTriggerAt != null &&
        now.difference(_lastVoiceTriggerAt!) < const Duration(seconds: 12)) {
      return;
    }

    if (_responseInFlight || _micResponseInFlight) return;

    final novelWords = _systemWordsAccum - _systemWordsAtLastResponse;
    if (_lastVoiceTriggerAt != null &&
        now.difference(_lastVoiceTriggerAt!) < _voiceResponseMinInterval &&
        novelWords < _novelSystemWordsToBypassCooldown) {
      return;
    }

    _lastVoiceTriggerAt = now;
    _lastVoiceTriggerKey = key;
    _systemWordsAtLastResponse = _systemWordsAccum;
    _startVoiceTriggeredResponse(
      source: normalizedSource,
      statusMessage: 'Procesando voz detectada',
    );
  }

  void _startVoiceTriggeredResponse({
    required String source,
    String statusMessage = 'Procesando respuesta',
  }) {
    final normalizedSource = source.toLowerCase().trim() == 'sys' ? 'sys' : 'mic';
    final client = _resolveClientForSource(normalizedSource);
    if (client == null) return;

    _micResponseInFlight = true;
    _responseInFlight = true;
    _statusMessage = statusMessage;
    _assistantTurnSeq += 1;
    _activeAssistantTurnId = _assistantTurnSeq;
    _safeNotify();

    unawaited(_requestResponseForSource(normalizedSource, client));
  }

  Future<void> _requestResponseForSource(
    String source,
    OpenAIRealtimeClient client,
  ) async {
    try {
      if (source == 'sys') {
        if (_pendingSystemBytes > 0) {
          final committed = await _openAIClientSystem?.commitBuffer() ?? false;
          if (committed) _pendingSystemBytes = 0;
        }
      } else {
        if (_pendingMicBytes > 0) {
          final committed = await _openAIClientMic?.commitBuffer() ?? false;
          if (committed) _pendingMicBytes = 0;
        }
      }
      await client.requestResponse(instructions: _buildRecentContext());
    } catch (error) {
      if (_disposed) return;
      _micResponseInFlight = false;
      _responseInFlight = false;
      _statusMessage = 'Error solicitando respuesta: $error';
      _safeNotify();
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // AUDIO
  // ──────────────────────────────────────────────────────────────────────────

  void _appendAudio(Uint8List bytes) {
    _pendingMicBytes += bytes.length;
    _openAIClientMic?.appendAudio(bytes);
    _logAudioLevel(bytes);
  }

  Future<void> _flushRealtimeBoth() async {
    if (!_listening) return;
    await _maybeCommitSystem();
    await _maybeCommitMic();
  }

  Future<void> _maybeCommitSystem() async {
    const minCommitBytesSystem = 4600;
    if (_openAIClientSystem == null) return;
    if (_pendingSystemBytes < minCommitBytesSystem) return;
    final committed = await _openAIClientSystem?.commitBuffer() ?? false;
    if (committed) _pendingSystemBytes = 0;
  }

  Future<void> _maybeCommitMic() async {
    const minCommitBytesMic = 4600;
    if (_openAIClientMic == null) return;
    if (_pendingMicBytes < minCommitBytesMic) return;
    final committed = await _openAIClientMic?.commitBuffer() ?? false;
    if (committed) _pendingMicBytes = 0;
  }

  void _scheduleSilenceAutoStop() {
    _silenceAutoStopTimer?.cancel();
    if (!_listening) return;
    _silenceAutoStopTimer = Timer(_autoStopSilenceTimeout, () {
      if (_disposed || !_listening) return;
      _statusMessage = 'Silencio por 10s: asesoria detenida automaticamente';
      _safeNotify();
      unawaited(stopListening());
    });
  }

  OpenAIRealtimeClient? _resolveClientForSource(String source) {
    final normalized = source.toLowerCase().trim() == 'sys' ? 'sys' : 'mic';
    if (normalized == 'sys') return _openAIClientSystem ?? _openAIClientMic;
    return _openAIClientMic ?? _openAIClientSystem;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // WINDOWS AUDIO
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _startWindowsCapture() async {
    final systemDevice = windowsAudioDevice.trim();
    if (systemDevice.isEmpty) {
      _statusMessage =
          'Define WINDOWS_AUDIO_DEVICE en .env (ej. "Stereo Mix (Realtek(R) Audio)")';
      _listening = false;
      _safeNotify();
      return;
    }

    await _stopWindowsCapture();

    await _startWindowsDeviceCapture(
      label: 'system',
      device: systemDevice,
      loopback: windowsAudioBackend == 'wasapi' && windowsAudioLoopback,
      onChunk: (bytes) {
        _pendingSystemBytes += bytes.length;
        _openAIClientSystem?.appendAudio(bytes);
        _logAudioLevel(bytes);
      },
    );

    if (_audioProcessSystem == null) {
      _statusMessage =
          'Conectado a OpenAI, pero no se pudo iniciar captura de audio del sistema.';
      _safeNotify();
      return;
    }

    final micDevice = windowsMicDevice.trim();
    final includeMic = micMixEnabled && micDevice.isNotEmpty;
    if (includeMic) {
      await _startWindowsDeviceCapture(
        label: 'mic',
        device: micDevice,
        onChunk: (bytes) {
          _pendingMicBytes += bytes.length;
          _openAIClientMic?.appendAudio(bytes);
          _logAudioLevel(bytes);
        },
      );
    }

    _statusMessage = includeMic
        ? 'AsesorIA iniciada: conectada a OpenAI (sistema + microfono). Ya puedes hablar.'
        : 'AsesorIA iniciada: conectada a OpenAI. Ya puedes hablar.';
    _safeNotify();
  }

  Future<void> _startWindowsDeviceCapture({
    required String label,
    required String device,
    required void Function(Uint8List) onChunk,
    bool loopback = false,
  }) async {
    try {
      _addLog('Captura $label: $device');
      final args = <String>[
        '-f',
        windowsAudioBackend,
        if (windowsAudioSampleRate.isNotEmpty) ...[
          '-sample_rate',
          windowsAudioSampleRate,
        ],
        if (windowsAudioBackend == 'wasapi' && loopback) ...['-loopback', '1'],
        '-i',
        (windowsAudioBackend == 'wasapi' && device.toLowerCase() == 'default')
            ? 'default'
            : 'audio=$device',
        '-ac',
        '1',
        '-ar',
        '16000',
        '-f',
        's16le',
        '-',
      ];

      final ffmpegPath = _resolveFfmpeg();
      final process = await Process.start(ffmpegPath, args);
      final subscription = process.stdout.listen(
        (chunk) => onChunk(Uint8List.fromList(chunk)),
        onDone: () => _addLog('ffmpeg ($label) stdout cerrado'),
        onError: (error) {
          _statusMessage = 'Error en ffmpeg ($label): $error';
          _safeNotify();
        },
      );

      if (label == 'system') {
        _audioProcessSystem = process;
        _audioSubscriptionSystem = subscription;
      } else {
        _audioProcessMic = process;
        _audioSubscriptionMic = subscription;
      }

      process.exitCode.then((code) {
        _addLog('ffmpeg ($label) finalizo con codigo $code');
      });

      process.stderr.transform(const Utf8Decoder()).listen((line) {
        if (showFfmpegLogs) _addLog('ffmpeg ($label) stderr: $line');
      });
    } catch (error) {
      _addLog('ffmpeg ($label) no se pudo iniciar: $error');
      _statusMessage =
          'No se pudo iniciar ffmpeg ($label); instala la herramienta y comprueba el dispositivo.';
      _listening = false;
      _safeNotify();
    }
  }

  /// Returns the path to ffmpeg — bundled (next to the exe) if available, otherwise falls back to PATH.
  String _resolveFfmpeg() {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final bundled = p.join(exeDir, 'ffmpeg.exe');
    if (File(bundled).existsSync()) return bundled;
    return 'ffmpeg';
  }

  Future<void> _stopWindowsCapture() async {
    await _audioSubscriptionSystem?.cancel();
    await _audioSubscriptionMic?.cancel();
    _audioSubscriptionSystem = null;
    _audioSubscriptionMic = null;
    if (_audioProcessSystem != null) {
      _audioProcessSystem!.kill();
      await _audioProcessSystem!.exitCode;
      _audioProcessSystem = null;
    }
    if (_audioProcessMic != null) {
      _audioProcessMic!.kill();
      await _audioProcessMic!.exitCode;
      _audioProcessMic = null;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // TOKEN RESOLUTION
  // ──────────────────────────────────────────────────────────────────────────

  Future<String> _resolveOpenAIToken() async {
    final accessToken = AuthSessionManager.instance.accessToken?.trim() ?? '';
    debugPrint('[TOKEN] accessToken presente: ${accessToken.isNotEmpty}');
    if (accessToken.isNotEmpty) {
      final ephemeral =
          await RealtimeSessionApi().createSession(accessToken: accessToken);
      debugPrint('[TOKEN] ephemeralToken obtenido: ${ephemeral != null}');
      if (ephemeral != null && ephemeral.isNotEmpty) return ephemeral;
    }
    debugPrint('[TOKEN] fallback openAIKey presente: ${openAIKey.isNotEmpty}');
    return openAIKey;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // INSTRUCTIONS / CONTEXT
  // ──────────────────────────────────────────────────────────────────────────

  Future<String> _fetchRAGContext(String query) async {
    if (activeAgentId.isEmpty || query.trim().isEmpty) return '';

    try {
      final api = BackendDataApi();
      final chunks = await withAuthRetry<List<Map<String, dynamic>>>(
        action: (token) => api.searchDocuments(
          accessToken: token,
          agentId: activeAgentId,
          query: query,
          limit: 5,
        ),
      );

      if (chunks == null || chunks.isEmpty) return '';

      final buf = StringBuffer();
      buf.writeln('--- Documentos de referencia ---');
      for (final chunk in chunks) {
        final fileName = (chunk['fileName'] as String?) ?? '';
        final text = (chunk['text'] as String?) ?? '';
        if (text.trim().isEmpty) continue;
        if (fileName.isNotEmpty) {
          buf.writeln('[$fileName]:');
        }
        buf.writeln(text.trim());
        buf.writeln();
      }
      return buf.toString().trim();
    } catch (e) {
      debugPrint('[RAG] Error fetching context: $e');
      return '';
    }
  }

  void toggleFreestyleMode() {
    freestyleMode = !freestyleMode;
    applyUpdatedPrompt();
    _safeNotify();
  }

  String _buildSessionInstructions() {
    final buf = StringBuffer();
    if (promptOverride.trim().isNotEmpty) {
      buf.writeln(promptOverride.trim());
      buf.writeln();
    }
    if (_ragContext.trim().isNotEmpty) {
      buf.writeln(_ragContext.trim());
      buf.writeln();
    }
    if (freestyleMode) {
      buf.writeln('MODO LIBRE ACTIVADO: Puedes responder usando tu conocimiento general, sin limitarte al documento ni al prompt. Está permitido especular o extrapolar información cuando sea útil para el vendedor.');
      buf.writeln();
    }
    buf.writeln('Responde siempre en español. Usa exactamente estas dos secciones:');
    buf.writeln('CHAT:');
    buf.writeln('[4-8 líneas directas y accionables. Sin emojis ni JSON.]');
    buf.writeln('SUGERENCIAS:');
    buf.writeln('[Máx. 3 preguntas. Una por línea con formato: Pregunta sugerida: ...]');
    return buf.toString();
  }

  String _buildRecentContext({int maxLines = 3}) {
    final sysLines = <String>[];
    for (final t in _transcripts) {
      final trimmed = t.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('🎤')) continue;
      final text = trimmed
          .replaceFirst(RegExp(r'^🖥️?\s*'), '')
          .replaceFirst(RegExp(r'^🖥\s*'), '')
          .trim();
      if (text.isNotEmpty) sysLines.add(text);
    }
    if (sysLines.isEmpty) return '';
    final recent = sysLines.length > maxLines
        ? sysLines.sublist(sysLines.length - maxLines)
        : sysLines;
    return 'Contexto reciente de la conversación:\n${recent.join('\n')}';
  }

  // ──────────────────────────────────────────────────────────────────────────
  // TEXT PARSING & NORMALISATION
  // ──────────────────────────────────────────────────────────────────────────

  String _buildTitle(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 'Conversación';
    final words = trimmed.split(RegExp(r'\s+'));
    final titleWords = words.take(6).join(' ');
    return titleWords.length > 42
        ? '${titleWords.substring(0, 42)}…'
        : titleWords;
  }

  String _buildStreamingChatPreview(String raw) {
    if (raw.trim().isEmpty) return '';
    final text = _extractResponseText(raw);
    final kept = <String>[];
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (t.toLowerCase().startsWith(_suggestionPrefix.toLowerCase())) continue;
      final n = _normalizeChatLine(t);
      if (n.isNotEmpty) kept.add(n);
    }
    final seen = <String>{};
    final out = <String>[];
    for (final l in kept) {
      if (seen.add(l)) out.add(l);
    }
    if (out.length > 8) return out.take(8).join('\n');
    if (out.isNotEmpty) return out.join('\n');
    return _extractFallbackChatText(text);
  }

  String _extractResponseText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.startsWith('{') && trimmed.contains('llm_generated_text')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map && decoded['llm_generated_text'] is String) {
          return (decoded['llm_generated_text'] as String).trim();
        }
      } catch (_) {}
    }
    if (trimmed.contains('llm_generated_text')) {
      final idx = trimmed.indexOf('llm_generated_text');
      var start = trimmed.indexOf('"', idx);
      start = trimmed.indexOf('"', start + 1);
      if (start != -1) {
        final end = trimmed.lastIndexOf('"');
        if (end > start) {
          return trimmed.substring(start + 1, end).trim();
        }
      }
    }
    return trimmed;
  }

  String _cleanAssistantText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (trimmed.contains('"tool_calls"') ||
        trimmed.contains('tool_calls') ||
        (trimmed.contains('"name"') && trimmed.contains('"parameters"'))) {
      return '';
    }
    if (trimmed.contains('"session_params"') ||
        trimmed.contains('"lead_size"') ||
        trimmed.contains('"recommended_plan"') ||
        trimmed.contains('"plans"')) {
      return '';
    }
    return trimmed;
  }

  String _extractFallbackChatText(String raw) {
    var text = _extractResponseText(raw).trim();
    text = _cleanAssistantText(text);
    if (text.isEmpty) return '';
    final kept = <String>[];
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (RegExp(r'^CHAT\s*:?\s*$', caseSensitive: false).hasMatch(t)) continue;
      if (RegExp(r'^SUGERENCIAS\s*:?\s*$', caseSensitive: false)
          .hasMatch(t)) continue;
      if (t.toLowerCase().startsWith(_suggestionPrefix.toLowerCase())) continue;
      kept.add(t);
    }
    final fallback = kept.join('\n').trim();
    if (fallback.isEmpty) return '';
    return fallback.length > 800 ? fallback.substring(0, 800).trim() : fallback;
  }

  String _forceSectionNewlines(String t) {
    t = t.replaceAllMapped(
      RegExp(r'(\S)\s*(CHAT\s*:)', caseSensitive: false),
      (m) => '${m.group(1)}\n${m.group(2)}',
    );
    t = t.replaceAllMapped(
      RegExp(r'(\S)\s*(SUGERENCIAS\s*:)', caseSensitive: false),
      (m) => '${m.group(1)}\n${m.group(2)}',
    );
    t = t.replaceAllMapped(
      RegExp(r'(SUGERENCIAS\s*:)\s*(Pregunta sugerida:)', caseSensitive: false),
      (m) => '${m.group(1)}\n${m.group(2)}',
    );
    t = t.replaceAllMapped(
      RegExp(
        r'(CHAT\s*:)\s*(Respuesta sugerida:|Objeción detectada:|Objecion detectada:|Momento de cierre:)',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)}\n${m.group(2)}',
    );
    return t;
  }

  String _normalizeChatLine(String line) {
    var t = line.trim();
    if (t.isEmpty) return '';
    t = t
        .replaceAll(
          RegExp(r'\s*SUGERENCIAS\s*:.*$', caseSensitive: false),
          '',
        )
        .trim();
    if (t.isEmpty) return '';
    final prefix = _chatPrefixes.firstWhere(
      (p) => t.toLowerCase().startsWith(p.toLowerCase()),
      orElse: () => '',
    );
    if (prefix.isEmpty) {
      if (RegExp(r'^(chat|sugerencias)\s*:', caseSensitive: false).hasMatch(t)) {
        return '';
      }
      if (t.toLowerCase().startsWith(_suggestionPrefix.toLowerCase())) {
        return '';
      }
      t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
      return t;
    }
    final second = t.toLowerCase().indexOf(prefix.toLowerCase(), prefix.length);
    if (second != -1) {
      final a = t.substring(prefix.length, second).trim();
      final b = t.substring(second + prefix.length).trim();
      if (a.isNotEmpty && (a == b || b.startsWith(a))) return '$prefix $a';
      if (a.isNotEmpty) return '$prefix $a';
    }
    t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return t;
  }

  String _normalizeSuggestion(String s) {
    var t = s.trim();
    t = t.replaceAll('👉', '').replaceAll('💡', '').trim();
    final lower = t.toLowerCase();
    final i = lower.indexOf('pregunta sugerida:');
    if (i != -1) {
      t = t.substring(i + 'pregunta sugerida:'.length).trim();
    }
    if (t.length > 180) t = t.substring(0, 180).trim();
    return t;
  }

  String _collapseImmediateRepeat(String t) {
    var s = t.trim();
    if (s.isEmpty) return s;
    String norm(String x) =>
        x.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final tokens = s.split(RegExp(r'\s+'));
    if (tokens.length < 2) return s;
    final maxBlock = (tokens.length / 2).floor();
    final normTokens = tokens.map(norm).toList();
    for (int block = 1; block <= maxBlock; block++) {
      bool equal = true;
      for (int i = 0; i < block; i++) {
        if (normTokens[i] != normTokens[i + block]) {
          equal = false;
          break;
        }
      }
      if (equal) return tokens.take(block).join(' ').trim();
    }
    return s;
  }

  String? _cleanTranscriptChunk(String chunk) {
    var t = chunk.trim();
    if (t.isEmpty) return null;
    final lower = t.toLowerCase();
    final looksLikeContext = lower == '###' ||
        lower.startsWith('context:') ||
        lower.startsWith('###context') ||
        lower == 'context';
    final looksLikeInstruction =
        lower.contains('transcribe únicamente en español') ||
            lower.contains('transcribe unicamente en espanol');
    if (looksLikeContext || looksLikeInstruction) return null;
    t = t.replaceAllMapped(
      RegExp(r'(\b\w+[.!?])\1+'),
      (m) => m.group(1)!,
    );
    t = _collapseImmediateRepeat(t);
    t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return t.isEmpty ? null : t;
  }

  Map<String, dynamic> _parseAssistantOutput(String raw) {
    var text = _extractResponseText(raw).trim();
    text = _forceSectionNewlines(text);
    if (text.isEmpty) return {'chat': '', 'suggestions': <String>[]};

    final lines = text.split('\n');
    int chatIndex = -1;
    int suggestionIndex = -1;
    final chatLabel = RegExp(r'^CHAT\s*:?\s*$', caseSensitive: false);
    final suggestionsLabel = RegExp(r'^SUGERENCIAS\s*:?\s*$', caseSensitive: false);

    for (var i = 0; i < lines.length; i++) {
      final label = lines[i].trim();
      if (chatLabel.hasMatch(label)) chatIndex = i;
      if (suggestionsLabel.hasMatch(label)) suggestionIndex = i;
    }

    bool isChatPrefix(String line) {
      final t = line.trimLeft();
      for (final p in _chatPrefixes) {
        if (t.toLowerCase().startsWith(p.toLowerCase())) return true;
      }
      return false;
    }

    bool isSuggestionPrefix(String line) {
      final t = line.trimLeft();
      return t.toLowerCase().startsWith(_suggestionPrefix.toLowerCase());
    }

    String stripPrefix(String line, String prefix) {
      final t = line.trim();
      if (t.length <= prefix.length) return '';
      return t.substring(prefix.length).trim();
    }

    // Caso A: no hay secciones
    if (chatIndex == -1 && suggestionIndex == -1) {
      final chatOut = <String>[];
      final sugOut = <String>[];
      for (final line in lines) {
        final t = line.trim();
        if (t.isEmpty) continue;
        if (isSuggestionPrefix(t)) {
          final content = stripPrefix(t, _suggestionPrefix);
          if (content.isNotEmpty) sugOut.add(content);
          continue;
        }
        if (isChatPrefix(t)) {
          final n = _normalizeChatLine(t);
          if (n.isNotEmpty) chatOut.add(n);
        }
      }
      return {'chat': chatOut.join('\n').trim(), 'suggestions': sugOut};
    }

    // Caso B: secciones explícitas
    final chatLinesRaw = <String>[];
    final suggestionLinesRaw = <String>[];

    if (chatIndex != -1) {
      final end = (suggestionIndex != -1 && suggestionIndex > chatIndex)
          ? suggestionIndex
          : lines.length;
      for (var i = chatIndex + 1; i < end; i++) {
        chatLinesRaw.add(lines[i]);
      }
    }
    if (suggestionIndex != -1) {
      for (var i = suggestionIndex + 1; i < lines.length; i++) {
        suggestionLinesRaw.add(lines[i]);
      }
    }

    final chatOut = <String>[];
    for (final line in chatLinesRaw) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (chatLabel.hasMatch(t) || suggestionsLabel.hasMatch(t)) continue;
      if (isSuggestionPrefix(t)) continue;
      final n = _normalizeChatLine(t);
      if (n.isNotEmpty) chatOut.add(n);
    }

    final sugOut = <String>[];
    for (final line in suggestionLinesRaw) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (!isSuggestionPrefix(t)) continue;
      final content = stripPrefix(t, _suggestionPrefix);
      if (content.isNotEmpty) sugOut.add(content);
    }

    return {'chat': chatOut.join('\n').trim(), 'suggestions': sugOut};
  }

  // ──────────────────────────────────────────────────────────────────────────
  // TRANSCRIPT HELPERS
  // ──────────────────────────────────────────────────────────────────────────

  bool _tryMergeMicTranscript(String cleaned, DateTime now) {
    if (_transcripts.isEmpty) return false;
    final lastIndex = _transcripts.length - 1;
    final last = _transcripts[lastIndex].trim();
    if (!last.startsWith('🎤 ')) return false;
    if (_lastMicTranscriptAt == null ||
        now.difference(_lastMicTranscriptAt!) > _micTranscriptMergeWindow) {
      return false;
    }
    final previous = last.replaceFirst(RegExp(r'^🎤\s*'), '').trim();
    if (previous.isEmpty) return false;
    final prevKey = previous.toLowerCase();
    final nextKey = cleaned.trim().toLowerCase();
    if (nextKey.isEmpty) return false;
    if (prevKey == nextKey || prevKey.contains(nextKey)) return true;
    final merged = nextKey.contains(prevKey)
        ? cleaned.trim()
        : '$previous ${cleaned.trim()}';
    _transcripts[lastIndex] = '🎤 $merged';
    return true;
  }

  List<TranscriptEntry> _normalizeTranscriptEntries(
    List<TranscriptEntry> entries,
  ) {
    if (entries.length < 2) return List<TranscriptEntry>.from(entries);
    final ordered = List<TranscriptEntry>.from(entries);

    for (var i = 1; i < ordered.length - 1; i++) {
      final prev = ordered[i - 1];
      final current = ordered[i];
      final next = ordered[i + 1];
      if (prev.isMic != next.isMic) continue;
      if (current.isMic == prev.isMic) continue;
      if (!_isShortInterjection(current.text)) continue;
      ordered.removeAt(i);
      ordered.insert(i + 1, current);
      i++;
    }

    final merged = <TranscriptEntry>[];
    for (final entry in ordered) {
      if (merged.isEmpty) {
        merged.add(entry);
        continue;
      }
      final last = merged.last;
      if (!last.pending && !entry.pending && last.isMic == entry.isMic) {
        merged[merged.length - 1] = TranscriptEntry(
          text: '${last.text.trim()}\n${entry.text.trim()}'.trim(),
          isMic: last.isMic,
        );
      } else {
        merged.add(entry);
      }
    }
    return merged;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // UTILITIES
  // ──────────────────────────────────────────────────────────────────────────

  void _addLog(String entry) {
    final timestamp = DateTime.now().toIso8601String();
    debugPrint('[$timestamp] $entry');
  }

  bool _isLikelyVoiceLine(String line) {
    final t = line.trim();
    if (t.isEmpty || t.length < 3) return false;
    return RegExp(r'[A-Za-z0-9ÁÉÍÓÚáéíóúÑñ]').hasMatch(t);
  }

  bool _isShortInterjection(String text) {
    final t = text.trim();
    if (t.isEmpty) return true;
    return _wordCount(t) <= 3 || t.length <= 18;
  }

  int _wordCount(String text) {
    final t = text.trim();
    if (t.isEmpty) return 0;
    return t.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).length;
  }

  void _logAudioLevel(Uint8List bytes) {
    if (bytes.length < 2) return;
    final now = DateTime.now();
    if (_lastLevelLogAt != null &&
        now.difference(_lastLevelLogAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastLevelLogAt = now;

    final samples = bytes.length ~/ 2;
    int sumSquares = 0;
    for (var i = 0; i < samples; i++) {
      final lo = bytes[i * 2];
      final hi = bytes[i * 2 + 1];
      int sample = (hi << 8) | lo;
      if (sample & 0x8000 != 0) sample = sample - 0x10000;
      sumSquares += sample * sample;
    }
    final rms = math.sqrt(sumSquares / samples);
    final db = 20 * math.log(rms / 32768 + 1e-6) / math.ln10;
    _addLog('Audio RMS dBFS: ${db.toStringAsFixed(1)}');
  }

  Uint8List _floatTo16(List<double> source) {
    final buffer = Int16List(source.length);
    for (var i = 0; i < source.length; i++) {
      var sample = (source[i] * 32767).round();
      if (sample > 32767) {
        sample = 32767;
      } else if (sample < -32768) {
        sample = -32768;
      }
      buffer[i] = sample;
    }
    return buffer.buffer.asUint8List();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // DISPOSE
  // ──────────────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _realtimeTimer?.cancel();
    _uiTranscriptIdleTimer?.cancel();
    _queuedResponseDelayTimer?.cancel();
    _silenceAutoStopTimer?.cancel();
    onRequestStopPlatformCapture?.call();
    _audioSubscriptionSystem?.cancel();
    _audioSubscriptionMic?.cancel();
    _audioProcessSystem?.kill();
    _audioProcessMic?.kill();
    _openAIClientMic?.close();
    _openAIClientSystem?.close();
    super.dispose();
  }
}
