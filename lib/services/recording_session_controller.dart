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
import 'audio_device_utils.dart';
import 'audio_preferences_store.dart';
import 'audio_vad_buffer.dart';
import 'auth_session_manager.dart';
import 'backend_data_api.dart';
import 'chat_completion_client.dart';
import 'conversation_store.dart';
import 'groq_transcription_client.dart';
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

  /// Called when no loopback device (Stereo Mix) is found, so the UI can
  /// show a setup guide dialog.
  VoidCallback? onNoLoopbackDeviceFound;

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
  // _lastLevelLogSystem / _lastLevelLogMic live near _logAudioLevel

  String _currentResponse = '';
  final List<ChatMessage> _chatResponses = [];
  final List<String> _suggestions = [];
  final List<String> _transcripts = [];
  final List<String> _debugLogs = [];
  String _currentTranscriptSys = '';
  String _currentTranscriptMic = '';
  String? _lastSysLine;
  String? _lastMicLine;
  DateTime? _lastMicTranscriptAt;
  DateTime? _lastSysTranscriptAt;
  int _systemWordsAccum = 0;
  int _systemWordsAtLastResponse = 0;

  String _statusMessage = '';
  DateTime? _sessionStartedAt;
  DateTime? _sessionEndedAt;

  String _ragContext = '';
  String _lastResolvedToken = '';

  OpenAIRealtimeClient? _openAIClientMic;
  OpenAIRealtimeClient? _openAIClientSystem;
  Process? _audioProcessSystem;
  Process? _audioProcessMic;
  StreamSubscription<List<int>>? _audioSubscriptionSystem;
  StreamSubscription<List<int>>? _audioSubscriptionMic;

  // ── Groq STT Pipeline ──────────────────────────────────────────────────
  GroqTranscriptionClient? _groqClient;
  ChatCompletionClient? _chatClient;
  ChatCompletionClient? _suggestionsClient;
  AudioVadBuffer? _systemVadBuffer;
  AudioVadBuffer? _micVadBuffer;
  bool _groqPipelineActive = false;

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
  List<String> get debugLogs => List.unmodifiable(_debugLogs);

  // ── Platform helpers ─────────────────────────────────────────────────────
  bool get _systemOnlyMode => Platform.isWindows;
  bool get _windowsMicAvailable =>
      Platform.isWindows && windowsMicDevice.trim().isNotEmpty;
  bool get _audioSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isLinux;

  // ── Constants ────────────────────────────────────────────────────────────
  static const Duration _voiceResponseMinInterval = Duration(seconds: 8);
  static const int _transcriptIdleFlushMs = 1700;
  static const Duration _micTranscriptMergeWindow = Duration(seconds: 6);
  static const Duration _autoStopSilenceTimeout = Duration(seconds: 50);
  static const int _minSystemCharsPerTurn = 15;
  static const int _novelSystemWordsToBypassCooldown = 6;

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

    // When Groq pipeline is active, we don't need OpenAI ephemeral tokens at all.
    String micKey = '';
    String systemKey = '';
    if (!useGroqPipeline || groqApiKey.isEmpty) {
      micKey = await _resolveOpenAIToken();
      if (micKey.isEmpty) {
        _statusMessage =
            'No se pudo obtener credenciales de OpenAI. Configura OPENAI_API_KEY en el backend.';
        _safeNotify();
        return;
      }
      systemKey = await _resolveOpenAIToken();
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

    _addLog('🟢 Conectando con OpenAI...');
    final promptPreview = promptOverride.length > 120
        ? '${promptOverride.substring(0, 120)}...'
        : promptOverride;
    _addLog('📋 Agente cargado: $promptPreview');

    // RAG: fetch relevant document chunks before connecting
    _ragContext = '';
    if (activeAgentId.isNotEmpty) {
      _addLog('🔍 Buscando documentos del agente...');
      _ragContext = await _fetchRAGContext(promptOverride);
      if (_ragContext.isNotEmpty) {
        _addLog('✅ Documentos del agente cargados');
      }
    }

    _openAIClientMic = null;
    _openAIClientSystem = null;
    _groqPipelineActive = false;
    final hasSystemDevice = Platform.isWindows;

    if (useGroqPipeline && groqApiKey.isNotEmpty) {
      // ── Full Groq pipeline: mic + system via Groq Whisper + Groq Llama 3.3 ──
      _groqPipelineActive = true;
      _addLog('🔄 Pipeline completo Groq: mic y sistema sin OpenAI Realtime');

      _groqClient = GroqTranscriptionClient(
        apiKey: groqApiKey,
        model: groqModel,
        language: 'es',
        onLog: _addLog,
      );

      _chatClient = ChatCompletionClient(
        apiKey: groqApiKey,
        onLog: _addLog,
      );
      _chatClient!.setSystemPrompt(_buildChatOnlyPrompt());

      _suggestionsClient = ChatCompletionClient(
        apiKey: groqApiKey,
        onLog: _addLog,
      );
      _suggestionsClient!.setSystemPrompt(_buildSuggestionsOnlyPrompt());

      // VAD for system audio → transcription + responses
      _systemVadBuffer = AudioVadBuffer(
        silenceThresholdDb: -50.0,
        silenceDurationMs: 800,
        minSpeechDurationMs: 300,
        maxBufferDurationMs: 12000,
        onSpeechComplete: _onGroqSpeechComplete,
      )..onLog = _addLog;

      // VAD for mic audio → transcription only
      _micVadBuffer = AudioVadBuffer(
        silenceThresholdDb: -55.0,
        silenceDurationMs: 2000,
        minSpeechDurationMs: 500,
        maxBufferDurationMs: 30000,
        onSpeechComplete: _onGroqMicSpeechComplete,
      )..onLog = _addLog;
    } else {
      // ── Original OpenAI Realtime pipeline ──
      _openAIClientMic = OpenAIRealtimeClient(
        openAIKey: micKey,
        model: openAIRealtimeModel,
        vadSilenceMs: vadSilenceMs,
        transcriptionOnly: true,
        onDelta: (_) {},
        onTranscriptDelta: (t) => _appendTranscriptDelta(t, source: 'mic'),
        onComplete: () => _appendTranscriptDelta('\n', source: 'mic'),
        onLog: _addLog,
        showEvents: showOpenAIEvents,
        sourceTag: 'mic',
      );

      if (hasSystemDevice) {
        _openAIClientSystem = OpenAIRealtimeClient(
          openAIKey: systemKey.isNotEmpty ? systemKey : micKey,
          model: openAIRealtimeModel,
          vadSilenceMs: vadSilenceMs,
          sessionInstructions: _buildSessionInstructions(),
          onDelta: _appendResponseDelta,
          onTranscriptDelta: (t) => _appendTranscriptDelta(t, source: 'sys'),
          onComplete: () {
            _appendTranscriptDelta('\n', source: 'sys');
            _handleResponseComplete();
          },
          onLog: _addLog,
          showEvents: showOpenAIEvents,
          sourceTag: 'system',
        );
      }
    }

    try {
      if (!_groqPipelineActive) {
        await _openAIClientMic?.connect();
        await _openAIClientSystem?.connect();
      }
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
        ? (_groqPipelineActive
            ? 'Conectado (Groq + Groq Llama 3.3). Escuchando audio del sistema...'
            : 'Conectado a OpenAI. Escuchando audio del sistema...')
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
      _addLog('🔴 Deteniendo captura de audio');
      onRequestStopPlatformCapture?.call();
    }

    // Flush Groq pipeline buffers
    _systemVadBuffer?.forceFlush();
    _micVadBuffer?.forceFlush();

    if (_pendingSystemBytes > 0 && !_groqPipelineActive) {
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
      _groqClient?.close();
      _groqClient = null;
      _chatClient?.close();
      _chatClient = null;
      _suggestionsClient?.close();
      _suggestionsClient = null;
      _systemVadBuffer?.dispose();
      _systemVadBuffer = null;
      _micVadBuffer?.dispose();
      _micVadBuffer = null;
      _groqPipelineActive = false;
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
            final now = DateTime.now();
            final merged = _tryMergeSysTranscript(cleaned, now);
            if (!merged) _transcripts.add(tagged);
            _lastSysLine = tagged;
            _lastSysTranscriptAt = now;
            _lastMicTranscriptAt = null;
            _systemWordsAccum += _wordCount(normalized);
            _addLog('🖥️ Audio sistema transcribió: "${normalized.length > 50 ? '${normalized.substring(0, 50)}...' : normalized}"');
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

  // ── Groq pipeline: called when VAD detects speech complete ──────────────
  void _onGroqSpeechComplete(Uint8List pcmBytes) async {
    if (_disposed || !_groqPipelineActive) return;

    final groq = _groqClient;
    final chat = _chatClient;
    if (groq == null || chat == null) return;

    _addLog('🎙️ Groq: transcribiendo ${(pcmBytes.length / 48000).toStringAsFixed(1)}s de audio...');

    // 1. Transcribe with Groq
    final transcript = await groq.transcribe(pcmBytes);
    if (transcript == null || transcript.trim().isEmpty) {
      _addLog('🔇 Groq: audio sin habla detectada');
      return;
    }

    // 2. Show transcription in UI
    _appendTranscriptDelta(transcript, source: 'sys');
    _appendTranscriptDelta('\n', source: 'sys');

    _addLog('🖥️ Groq transcripción: "$transcript"');

    // 3. Build prompt with recent conversation context + RAG
    final recentTranscripts = <String>[];
    for (final t in _transcripts) {
      final trimmed = t.trim();
      if (trimmed.isEmpty) continue;
      final clean = trimmed
          .replaceFirst(RegExp(r'^🎤\s*'), '')
          .replaceFirst(RegExp(r'^🖥️?\s*'), '')
          .trim();
      if (clean.isNotEmpty) recentTranscripts.add(clean);
    }
    // Keep last 10 lines for context
    final contextLines = recentTranscripts.length > 10
        ? recentTranscripts.sublist(recentTranscripts.length - 10)
        : recentTranscripts;

    final buf = StringBuffer();
    if (_ragContext.isNotEmpty) {
      buf.writeln('CONTEXTO DE DOCUMENTOS:');
      buf.writeln(_ragContext);
      buf.writeln();
    }
    if (contextLines.isNotEmpty) {
      buf.writeln('CONVERSACIÓN RECIENTE:');
      buf.writeln(contextLines.join('\n'));
      buf.writeln();
    }
    buf.writeln('ÚLTIMO FRAGMENTO (responde a esto):');
    buf.writeln(transcript);
    final userMessage = buf.toString();

    // 4. Get response + suggestions in parallel from Groq Llama 3.3
    _currentResponse = '';
    _addLog('🤖 Groq Llama 3.3: generando respuesta + sugerencias...');

    final suggestionsClient = _suggestionsClient;

    // Launch both in parallel
    final chatFuture = chat.sendMessage(
      userMessage: userMessage,
      onDelta: (delta) {
        _appendResponseDelta(delta);
      },
      onComplete: () {
        _appendTranscriptDelta('\n', source: 'sys');
        _handleResponseComplete();
      },
    );

    final suggestionsFuture = suggestionsClient != null
        ? suggestionsClient.sendMessage(
            userMessage: userMessage,
            onDelta: (_) {},
            onComplete: () {},
          )
        : Future.value('');

    final results = await Future.wait([chatFuture, suggestionsFuture]);

    // Parse suggestions from the dedicated client
    final suggestionsText = results[1];
    if (suggestionsText.isNotEmpty) {
      final lines = suggestionsText.split('\n');
      _suggestions.clear();
      for (final line in lines) {
        final t = line.trim();
        if (t.isEmpty) continue;
        // Strip "Pregunta sugerida:" prefix
        final colonIdx = t.indexOf(':');
        if (colonIdx >= 0 && colonIdx < t.length - 1) {
          _suggestions.add(t.substring(colonIdx + 1).trim());
        } else {
          _suggestions.add(t);
        }
      }
      _safeNotify();
    }
  }

  // ── Groq pipeline: mic speech complete → transcription only ──────────────
  void _onGroqMicSpeechComplete(Uint8List pcmBytes) async {
    if (_disposed || !_groqPipelineActive) return;

    final groq = _groqClient;
    if (groq == null) return;

    final transcript = await groq.transcribe(pcmBytes);
    if (transcript == null || transcript.trim().isEmpty) return;

    // Show mic transcription in UI (no response generation)
    _appendTranscriptDelta(transcript, source: 'mic');
    _appendTranscriptDelta('\n', source: 'mic');
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
      unawaited(_maybeSaveConversation());
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
      _addLog('⚠️ No se pudo guardar la conversación');
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
    final normalizedSource = source.toLowerCase().trim() == 'sys' ? 'sys' : 'mic';
    if (!_listening) return;
    if (normalizedSource != 'sys') {
      _addLog('ℹ️ Transcripción del mic ignorada para respuesta (solo audio del sistema genera respuestas)');
      return;
    }

    final cleanedLine = transcriptLine.trim();
    if (cleanedLine.length < _minSystemCharsPerTurn) {
      _addLog('ℹ️ Audio del sistema: línea muy corta (${cleanedLine.length} chars, mínimo $_minSystemCharsPerTurn)');
      return;
    }

    final now = DateTime.now();
    final key = cleanedLine.toLowerCase();
    if (key.isEmpty) return;

    if (_lastVoiceTriggerKey == key &&
        _lastVoiceTriggerAt != null &&
        now.difference(_lastVoiceTriggerAt!) < const Duration(seconds: 12)) {
      _addLog('ℹ️ Audio del sistema: línea duplicada, ignorada');
      return;
    }

    if (_responseInFlight || _micResponseInFlight) {
      _addLog('ℹ️ Audio del sistema: respuesta ya en curso, encolando');
      return;
    }

    final novelWords = _systemWordsAccum - _systemWordsAtLastResponse;
    if (_lastVoiceTriggerAt != null &&
        now.difference(_lastVoiceTriggerAt!) < _voiceResponseMinInterval &&
        novelWords < _novelSystemWordsToBypassCooldown) {
      _addLog('ℹ️ Audio del sistema: cooldown activo ($novelWords palabras nuevas, necesita $_novelSystemWordsToBypassCooldown)');
      return;
    }
    _lastVoiceTriggerAt = now;
    _lastVoiceTriggerKey = key;
    _systemWordsAtLastResponse = _systemWordsAccum;
    _addLog('✅ Audio del sistema: disparando respuesta (${_wordCount(cleanedLine)} palabras detectadas)');
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
    if (_groqPipelineActive) {
      _micVadBuffer?.addAudio(bytes);
    } else {
      _openAIClientMic?.appendAudio(bytes);
    }
    _logAudioLevel(bytes, label: 'mic');
  }

  Future<void> _flushRealtimeBoth() async {
    if (!_listening) return;
    await _maybeCommitSystem();
    await _maybeCommitMic();
  }

  Future<void> _maybeCommitSystem() async {
    if (_groqPipelineActive) return; // VAD buffer handles this
    const minCommitBytesSystem = 7200; // 24kHz * 2B * 150ms
    if (_openAIClientSystem == null) return;
    if (_pendingSystemBytes < minCommitBytesSystem) return;
    final committed = await _openAIClientSystem?.commitBuffer() ?? false;
    if (committed) _pendingSystemBytes = 0;
  }

  Future<void> _maybeCommitMic() async {
    const minCommitBytesMic = 7200; // 24kHz * 2B * 150ms
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

  /// Routes system audio to either Groq VAD buffer or OpenAI Realtime.
  int _sysChunkCount = 0;
  void _handleSystemAudioChunk(Uint8List bytes) {
    _pendingSystemBytes += bytes.length;
    _sysChunkCount++;
    if (_sysChunkCount <= 3) {
      _addLog('🔍 Sistema chunk #$_sysChunkCount: groqActive=$_groqPipelineActive vadNull=${_systemVadBuffer == null} bytes=${bytes.length}');
    }
    if (_groqPipelineActive) {
      _systemVadBuffer?.addAudio(bytes);
    } else {
      _openAIClientSystem?.appendAudio(bytes);
    }
    _logAudioLevel(bytes, label: 'system');
  }

  // ──────────────────────────────────────────────────────────────────────────
  // WINDOWS AUDIO
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> _startWindowsCapture() async {
    await _stopWindowsCapture();

    final store = AudioPreferencesStore.instance;
    final manualSystemId = store.systemDeviceId;
    final hasManualSystem = manualSystemId.isNotEmpty &&
        manualSystemId != 'auto' &&
        manualSystemId != 'Stereo Mix (Realtek(R) Audio)'; // ignore old default

    // Enumerate devices for logging and auto-detection
    final devices = await enumerateAudioDevices();
    _addLog('🎧 Buscando dispositivos de audio...');
    _addLog('🎧 Se encontraron ${devices.length} dispositivo(s):');
    for (final d in devices) {
      _addLog('   🔹 ${d.name}');
    }

    bool systemAudioActive = false;

    if (hasManualSystem) {
      // ── Manual selection ──
      _addLog('🎧 Usando dispositivo manual: ${store.systemDevice}');
      await _startWindowsDeviceCapture(
        label: 'system',
        device: manualSystemId,
        onChunk: _handleSystemAudioChunk,
      );
      systemAudioActive = _audioProcessSystem != null;
      if (!systemAudioActive) {
        _addLog('⚠️ Fallo con ID, reintentando con nombre...');
        await _startWindowsDeviceCapture(
          label: 'system',
          device: store.systemDevice,
          onChunk: _handleSystemAudioChunk,
        );
        systemAudioActive = _audioProcessSystem != null;
      }
    } else {
      // ── Auto-detect loopback (Stereo Mix / Mezcla estéreo) ──
      final loopback = findLoopbackDevice(devices);
      if (loopback != null) {
        _addLog('✅ Audio del sistema detectado: ${loopback.name}');
        await _startWindowsDeviceCapture(
          label: 'system',
          device: loopback.deviceId,
          onChunk: _handleSystemAudioChunk,
        );
        systemAudioActive = _audioProcessSystem != null;
        if (!systemAudioActive) {
          _addLog('⚠️ No se pudo capturar con ID del dispositivo, reintentando con nombre...');
          await _startWindowsDeviceCapture(
            label: 'system',
            device: loopback.name,
            onChunk: _handleSystemAudioChunk,
          );
          systemAudioActive = _audioProcessSystem != null;
        }
      } else {
        _addLog('❌ No se encontró Stereo Mix entre los dispositivos. La IA no podrá escuchar el audio del sistema.');
      }
    }

    if (!systemAudioActive) {
      _addLog('❌ Sin audio del sistema — la IA no generará respuestas. Habilita Stereo Mix.');
      _statusMessage = 'Sin Stereo Mix. Abre la guía para habilitarlo.';
      _safeNotify();
      onNoLoopbackDeviceFound?.call();
    }

    final micDevice = windowsMicDevice.trim();
    final includeMic = micMixEnabled && micDevice.isNotEmpty;
    if (includeMic) {
      await _startWindowsDeviceCapture(
        label: 'mic',
        device: micDevice,
        useInputSampleRate: false,
        onChunk: (bytes) {
          _pendingMicBytes += bytes.length;
          if (_groqPipelineActive) {
            _micVadBuffer?.addAudio(bytes);
          } else {
            _openAIClientMic?.appendAudio(bytes);
          }
          _logAudioLevel(bytes, label: 'mic');
        },
      );
    }

    final modeDesc = systemAudioActive
        ? (includeMic ? 'sistema + micrófono' : 'sistema')
        : (includeMic ? 'solo micrófono (fallback)' : 'sin audio');
    _statusMessage = 'EasyExpert iniciada: conectada a OpenAI ($modeDesc). Ya puedes hablar.';
    _safeNotify();
  }

  Future<void> _startWindowsDeviceCapture({
    required String label,
    required String device,
    required void Function(Uint8List) onChunk,
    bool useInputSampleRate = true,
  }) async {
    try {
      final labelName = label == 'system' ? 'audio del sistema' : 'micrófono';
      _addLog('🎤 Iniciando captura de $labelName...');
      final args = <String>[
        '-f',
        'dshow',
        if (useInputSampleRate && windowsAudioSampleRate.isNotEmpty) ...[
          '-sample_rate',
          windowsAudioSampleRate,
        ],
        '-i',
        'audio=$device',
        '-ac',
        '1',
        '-ar',
        '24000',
        '-f',
        's16le',
        '-',
      ];

      final ffmpegPath = _resolveFfmpeg();
      final process = await Process.start(ffmpegPath, args);
      final subscription = process.stdout.listen(
        (chunk) => onChunk(Uint8List.fromList(chunk)),
        onDone: () => _addLog('🔴 Captura de ${label == 'system' ? 'audio del sistema' : 'micrófono'} finalizada'),
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
        final labelName = label == 'system' ? 'audio del sistema' : 'micrófono';
        if (code == 0) {
          _addLog('✅ Captura de $labelName terminó correctamente');
        } else {
          _addLog('❌ Error en captura de $labelName (código $code) — verifica que el dispositivo esté habilitado');
        }
      });

      process.stderr.transform(const Utf8Decoder()).listen((line) {
        if (showFfmpegLogs) {
          _addLog('⚙️ [$label] $line');
        }
      });
    } catch (error) {
      final labelName = label == 'system' ? 'audio del sistema' : 'micrófono';
      _addLog('❌ No se pudo iniciar la captura de $labelName: $error');
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
      if (ephemeral != null && ephemeral.isNotEmpty) {
        _lastResolvedToken = ephemeral;
        return ephemeral;
      }
    }
    // Fallback: reuse last successful token (backend may be sleeping)
    if (_lastResolvedToken.isNotEmpty) {
      debugPrint('[TOKEN] reutilizando ultimo token obtenido');
      return _lastResolvedToken;
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
    buf.writeln('FORMATO OBLIGATORIO — respeta esta estructura exacta:');
    buf.writeln('');
    buf.writeln('CHAT:');
    buf.writeln('Tu respuesta aquí. Máximo 5 líneas. Concisa y accionable. Sin emojis. Completa todas las palabras y oraciones.');
    buf.writeln('');
    buf.writeln('SUGERENCIAS:');
    buf.writeln('Pregunta sugerida: primera pregunta');
    buf.writeln('Pregunta sugerida: segunda pregunta');
    buf.writeln('Pregunta sugerida: tercera pregunta');
    buf.writeln('');
    buf.writeln('REGLAS:');
    buf.writeln('- Escribe "CHAT:" y "SUGERENCIAS:" como separadores.');
    buf.writeln('- Las preguntas van SOLO en SUGERENCIAS, nunca en CHAT.');
    buf.writeln('- Cada pregunta empieza con "Pregunta sugerida:" en línea propia.');
    buf.writeln('- Completa todas las palabras. No cortes frases a la mitad.');
    buf.writeln('- Responde en español.');
    return buf.toString();
  }

  String _buildChatOnlyPrompt() {
    final buf = StringBuffer();
    if (promptOverride.trim().isNotEmpty) {
      buf.writeln(promptOverride.trim());
      buf.writeln();
    }
    if (freestyleMode) {
      buf.writeln('MODO LIBRE ACTIVADO: Puedes responder usando tu conocimiento general, sin limitarte al documento ni al prompt.');
      buf.writeln();
    }
    buf.writeln('Responde de forma directa y accionable.');
    buf.writeln('- Máximo 5 líneas.');
    buf.writeln('- Sin emojis.');
    buf.writeln('- Completa todas las palabras y oraciones, nunca cortes a la mitad.');
    buf.writeln('- NO incluyas preguntas sugeridas ni secciones como SUGERENCIAS.');
    buf.writeln('- Solo responde con el texto de ayuda para el usuario.');
    buf.writeln('- Responde en español.');
    return buf.toString();
  }

  String _buildSuggestionsOnlyPrompt() {
    final buf = StringBuffer();
    if (promptOverride.trim().isNotEmpty) {
      buf.writeln(promptOverride.trim());
      buf.writeln();
    }
    buf.writeln('Tu ÚNICA tarea es generar 3 preguntas relevantes que el usuario podría hacer basándose en la conversación.');
    buf.writeln('- Responde SOLO con 3 preguntas, una por línea.');
    buf.writeln('- Cada línea debe empezar con "Pregunta sugerida:"');
    buf.writeln('- No incluyas explicaciones, respuestas ni texto adicional.');
    buf.writeln('- Responde en español.');
    return buf.toString();
  }

  String _buildRecentContext({int maxLines = 3}) {
    final buf = StringBuffer();

    // 1) Instrucciones del agente + RAG (response.create sobreescribe session)
    final sessionInstr = _buildSessionInstructions().trim();
    if (sessionInstr.isNotEmpty) {
      buf.writeln(sessionInstr);
      buf.writeln();
    }

    // 2) Transcripción reciente del sistema
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
    if (sysLines.isNotEmpty) {
      final recent = sysLines.length > maxLines
          ? sysLines.sublist(sysLines.length - maxLines)
          : sysLines;
      buf.writeln('Contexto reciente de la conversación:');
      buf.writeln(recent.join('\n'));
    }

    return buf.toString().trim();
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
        lower.startsWith('contexto:') ||
        lower.startsWith('###context') ||
        lower == 'context' ||
        lower == 'contexto';
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
      final t = line.trimLeft().toLowerCase();
      return t.startsWith(_suggestionPrefix.toLowerCase()) ||
          t.startsWith('preguntaida:') ||
          t.startsWith('pregunta ida:') ||
          t.startsWith('suger:') ||
          t.startsWith('sugerida:') ||
          t.startsWith('pregunta:') ||
          RegExp(r'^pregunta\s*sugerida\s*:', caseSensitive: false).hasMatch(t);
    }

    String stripPrefix(String line, String prefix) {
      final t = line.trim();
      // Try exact prefix first
      if (t.length > prefix.length && t.toLowerCase().startsWith(prefix.toLowerCase())) {
        return t.substring(prefix.length).trim();
      }
      // Try flexible match — strip everything before first ':'
      final colonIdx = t.indexOf(':');
      if (colonIdx >= 0 && colonIdx < t.length - 1) {
        return t.substring(colonIdx + 1).trim();
      }
      return t;
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

  static const Duration _sysTranscriptMergeWindow = Duration(seconds: 8);

  bool _tryMergeSysTranscript(String cleaned, DateTime now) {
    if (_transcripts.isEmpty) return false;
    final lastIndex = _transcripts.length - 1;
    final last = _transcripts[lastIndex].trim();
    if (!last.startsWith('🖥️ ')) return false;
    if (_lastSysTranscriptAt == null ||
        now.difference(_lastSysTranscriptAt!) > _sysTranscriptMergeWindow) {
      return false;
    }
    final previous = last.replaceFirst(RegExp(r'^🖥️\s*'), '').trim();
    if (previous.isEmpty) return false;
    final prevKey = previous.toLowerCase();
    final nextKey = cleaned.trim().toLowerCase();
    if (nextKey.isEmpty) return false;
    if (prevKey == nextKey || prevKey.contains(nextKey)) return true;
    final merged = nextKey.contains(prevKey)
        ? cleaned.trim()
        : '$previous\n${cleaned.trim()}';
    _transcripts[lastIndex] = '🖥️ $merged';
    return true;
  }

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
    final line = '[$timestamp] $entry';
    debugPrint(line);
    _debugLogs.add(line);
    if (_debugLogs.length > 500) _debugLogs.removeAt(0);
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

  DateTime? _lastLevelLogSystem;
  DateTime? _lastLevelLogMic;

  void _logAudioLevel(Uint8List bytes, {String label = 'unknown'}) {
    if (bytes.length < 2) return;
    final now = DateTime.now();
    // Rate-limit per device independently
    if (label == 'system') {
      if (_lastLevelLogSystem != null &&
          now.difference(_lastLevelLogSystem!) < const Duration(seconds: 3)) {
        return;
      }
      _lastLevelLogSystem = now;
    } else {
      if (_lastLevelLogMic != null &&
          now.difference(_lastLevelLogMic!) < const Duration(seconds: 3)) {
        return;
      }
      _lastLevelLogMic = now;
    }

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
    final labelName = label == 'system' ? 'Sistema' : 'Micrófono';
    final level = db > -10 ? '🔊 Alto' : db > -30 ? '🔉 Normal' : db > -50 ? '🔈 Bajo' : '🔇 Muy bajo/silencio';
    _addLog('🎚️ $labelName: $level (${db.toStringAsFixed(0)} dB)');
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
