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
import 'audio_vad_buffer.dart';
import 'auth_session_manager.dart';
import 'backend_data_api.dart';
import 'chat_completion_client.dart';
import 'conversation_store.dart';
import 'groq_transcription_client.dart';
import 'realtime_session_api.dart';
import 'store_helpers.dart';

/// Controller for Meeting Mode — mic-only, in-person meeting coaching.
///
/// Differences vs [RecordingSessionController]:
/// - Single OpenAI client (mic) that both transcribes AND generates responses.
/// - No system audio capture (no Stereo Mix / ffmpeg for loopback).
/// - Transcription is plain text (no mic/sys separation).
/// - Suggestions, chat responses and freestyle mode work identically.
class MeetingSessionController extends ChangeNotifier {
  // ── Dispose guard ───────────────────────────────────────────────────────
  bool _disposed = false;

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  // ── Config pushed by widget before startListening ─────────────────────
  String promptOverride = '';
  String activeAgentId = '';
  bool freestyleMode = false;
  String? lastSavedConversationId;

  // ── Scroll / platform callbacks ───────────────────────────────────────
  VoidCallback? onScrollChatToBottom;
  VoidCallback? onScrollTranscriptToBottom;
  VoidCallback? onScrollSuggestionsToBottom;

  /// Called when the controller wants the widget to start FlutterAudioCapture.
  VoidCallback? onRequestStartPlatformCapture;

  /// Called when the controller wants the widget to stop FlutterAudioCapture.
  VoidCallback? onRequestStopPlatformCapture;

  // ── Private session state ─────────────────────────────────────────────
  bool _listening = false;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  Timer? _realtimeTimer;
  Timer? _uiTranscriptIdleTimer;
  Timer? _queuedResponseDelayTimer;
  Timer? _silenceAutoStopTimer;

  int _pendingMicBytes = 0;
  bool _responseInFlight = false;
  bool _finalResponseQueued = false;

  int _assistantTurnSeq = 0;
  int? _activeAssistantTurnId;
  DateTime? _lastVoiceTriggerAt;
  String _lastVoiceTriggerKey = '';
  int? _streamingAssistantIndex;
  String _streamingAssistantText = '';
  bool _assistantStreamStarted = false;

  String _currentResponse = '';
  final List<ChatMessage> _chatResponses = [];
  final List<String> _suggestions = [];
  final List<String> _transcriptLines = [];
  final List<String> _debugLogs = [];
  String _currentTranscript = '';
  String? _lastLine;
  int _wordsAccum = 0;
  int _wordsAtLastResponse = 0;

  String _statusMessage = '';
  DateTime? _sessionStartedAt;
  DateTime? _sessionEndedAt;

  String _ragContext = '';

  GroqTranscriptionClient? _groqClient;
  ChatCompletionClient? _chatClient;
  ChatCompletionClient? _suggestionsClient;
  AudioVadBuffer? _micVadBuffer;
  Process? _audioProcess;
  StreamSubscription<List<int>>? _audioSubscription;

  // ── Public read-only state ────────────────────────────────────────────
  bool get listening => _listening;
  Duration get elapsed => _elapsed;
  String get statusMessage => _statusMessage;
  bool get responseInFlight => _responseInFlight;
  int? get streamingAssistantIndex => _streamingAssistantIndex;
  String get streamingAssistantText => _streamingAssistantText;
  int? get activeAssistantTurnId => _activeAssistantTurnId;
  List<ChatMessage> get chatResponses => List.unmodifiable(_chatResponses);
  List<String> get suggestions => List.unmodifiable(_suggestions);
  List<String> get transcriptLines => List.unmodifiable(_transcriptLines);
  String get currentTranscript => _currentTranscript;
  DateTime? get sessionStartedAt => _sessionStartedAt;
  DateTime? get sessionEndedAt => _sessionEndedAt;
  List<String> get debugLogs => List.unmodifiable(_debugLogs);
  List<ChatMessage> get pinnedMessages =>
      _chatResponses.where((m) => m.pinned).toList();

  void togglePin(int index) {
    if (index < 0 || index >= _chatResponses.length) return;
    final msg = _chatResponses[index];
    _chatResponses[index] = msg.copyWith(pinned: !msg.pinned);
    _safeNotify();
  }

  // ── Constants ─────────────────────────────────────────────────────────
  static const Duration _voiceResponseMinInterval = Duration(seconds: 8);
  static const int _transcriptIdleFlushMs = 1700;
  static const Duration _autoStopSilenceTimeout = Duration(seconds: 30);
  static const int _minCharsPerTurn = 15;
  static const int _novelWordsToBypassCooldown = 6;

  // ── Chat prefixes (reused from normal mode) ───────────────────────────
  static const List<String> _chatPrefixes = [
    'Respuesta sugerida:',
    'Objeción detectada:',
    'Objecion detectada:',
    'Momento de cierre:',
  ];
  static const String _suggestionPrefix = 'Pregunta sugerida:';

  // ────────────────────────────────────────────────────────────────────────
  // PUBLIC API
  // ────────────────────────────────────────────────────────────────────────

  void applyUpdatedPrompt() {
    _chatClient?.updateSystemPrompt(_buildChatOnlyPrompt());
    _suggestionsClient?.updateSystemPrompt(_buildSuggestionsOnlyPrompt());
  }

  /// Entry point from FlutterAudioCapture (non-Windows platforms).
  void appendMicAudioFromPlatform(List<double> floatData) {
    final bytes = _floatTo16(floatData);
    _pendingMicBytes += bytes.length;
    _micVadBuffer?.addAudio(bytes);
    _logAudioLevel(bytes, label: 'mic');
  }

  Future<void> startListening() async {
    if (_listening) return;

    // Resolve Groq key from backend
    String resolvedGroqKey = groqApiKey;
    if (resolvedGroqKey.isEmpty) {
      final accessToken = AuthSessionManager.instance.accessToken?.trim() ?? '';
      if (accessToken.isNotEmpty) {
        resolvedGroqKey = await RealtimeSessionApi().fetchGroqKey(accessToken: accessToken) ?? '';
      }
    }
    if (resolvedGroqKey.isEmpty) {
      _statusMessage = 'No se pudo obtener credenciales de Groq.';
      _safeNotify();
      return;
    }

    _groqClient?.close();
    _chatClient?.close();
    _suggestionsClient?.close();
    _micVadBuffer?.dispose();

    _uiTranscriptIdleTimer?.cancel();
    _queuedResponseDelayTimer?.cancel();
    _silenceAutoStopTimer?.cancel();

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _elapsed = Duration(seconds: timer.tick);
      _safeNotify();
    });

    _sessionStartedAt = DateTime.now();
    _sessionEndedAt = null;
    _pendingMicBytes = 0;
    _responseInFlight = false;
    _finalResponseQueued = false;
    _assistantTurnSeq = 0;
    _activeAssistantTurnId = null;
    _lastVoiceTriggerAt = null;
    _lastVoiceTriggerKey = '';
    _chatResponses.clear();
    _suggestions.clear();
    _currentResponse = '';
    _transcriptLines.clear();
    _currentTranscript = '';
    _lastLine = null;
    _wordsAccum = 0;
    _wordsAtLastResponse = 0;
    _statusMessage = 'Conectando...';

    _addLog('🟢 Modo Reunión: pipeline Groq (sin OpenAI)');

    // RAG context
    _ragContext = '';
    if (activeAgentId.isNotEmpty) {
      _addLog('🔍 Buscando documentos del agente...');
      _ragContext = await _fetchRAGContext(promptOverride);
      if (_ragContext.isNotEmpty) {
        _addLog('✅ Documentos del agente cargados');
      }
    }

    // Groq clients
    _groqClient = GroqTranscriptionClient(
      apiKey: resolvedGroqKey,
      model: groqModel,
      language: 'es',
      onLog: _addLog,
    );

    _chatClient = ChatCompletionClient(
      apiKey: resolvedGroqKey,
      onLog: _addLog,
      onError: _handleGroqError,
    );
    _chatClient!.setSystemPrompt(_buildChatOnlyPrompt());

    _suggestionsClient = ChatCompletionClient(
      apiKey: resolvedGroqKey,
      onLog: _addLog,
      onError: _handleGroqError,
    );
    _suggestionsClient!.setSystemPrompt(_buildSuggestionsOnlyPrompt());

    // VAD for mic → transcription + responses
    _micVadBuffer = AudioVadBuffer(
      silenceThresholdDb: -55.0,
      silenceDurationMs: 1500,
      minSpeechDurationMs: 500,
      maxBufferDurationMs: 20000,
      onSpeechComplete: _onGroqSpeechComplete,
    )..onLog = _addLog;

    _listening = true;
    _statusMessage = 'Modo Reunión activo. Escuchando...';
    _safeNotify();
    _scheduleSilenceAutoStop();

    if (Platform.isWindows) {
      await _startWindowsMicCapture();
    } else if (Platform.isMacOS) {
      await _startMacOSMicCapture();
    } else {
      onRequestStartPlatformCapture?.call();
    }
  }

  Future<void> stopListening() async {
    if (!_listening) return;

    _timer?.cancel();
    _realtimeTimer?.cancel();
    _realtimeTimer = null;
    _queuedResponseDelayTimer?.cancel();
    _silenceAutoStopTimer?.cancel();

    _appendTranscriptDelta('\n');
    _sessionEndedAt = DateTime.now();

    if (Platform.isWindows) {
      await _stopWindowsMicCapture();
    } else if (Platform.isMacOS) {
      await _stopMacOSMicCapture();
    } else {
      onRequestStopPlatformCapture?.call();
    }

    _micVadBuffer?.forceFlush();

    _listening = false;
    _elapsed = Duration.zero;
    _statusMessage = 'Sesión finalizada';
    _safeNotify();

    _groqClient?.close();
    _groqClient = null;
    _chatClient?.close();
    _chatClient = null;
    _suggestionsClient?.close();
    _suggestionsClient = null;
    _micVadBuffer?.dispose();
    _micVadBuffer = null;
    await _maybeSaveConversation();
  }

  /// Called by VAD when mic speech ends — transcribe + generate response.
  void _onGroqSpeechComplete(Uint8List pcmBytes) async {
    if (_disposed) return;

    final groq = _groqClient;
    final chat = _chatClient;
    if (groq == null || chat == null) return;

    _scheduleSilenceAutoStop();

    final transcript = await groq.transcribe(pcmBytes);
    if (transcript == null || transcript.trim().isEmpty) return;

    // Show transcription
    _appendTranscriptDelta(transcript);
    _appendTranscriptDelta('\n');

    // Build context
    final recentTranscripts = <String>[];
    for (final t in _transcriptLines) {
      final trimmed = t.trim();
      if (trimmed.isNotEmpty) recentTranscripts.add(trimmed);
    }
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

    // Generate response + suggestions in parallel
    _currentResponse = '';
    _responseInFlight = true;
    _assistantTurnSeq += 1;
    _activeAssistantTurnId = _assistantTurnSeq;
    _safeNotify();

    final sugClient = _suggestionsClient;

    final chatFuture = chat.sendMessage(
      userMessage: userMessage,
      onDelta: (delta) {
        _appendResponseDelta(delta);
      },
      onComplete: () {
        _handleResponseComplete();
      },
    );

    final suggestionsFuture = sugClient != null
        ? sugClient.sendMessage(
            userMessage: userMessage,
            onDelta: (_) {},
            onComplete: () {},
          )
        : Future.value('');

    final results = await Future.wait([chatFuture, suggestionsFuture]);

    final suggestionsText = results[1];
    if (suggestionsText.isNotEmpty) {
      final lines = suggestionsText.split('\n');
      _suggestions.clear();
      for (final line in lines) {
        final t = line.trim();
        if (t.isEmpty) continue;
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

  Future<void> sendManualPrompt(String prompt) async {
    if (prompt.isEmpty) return;

    // Resolve Groq key if needed
    if (_chatClient == null) {
      String resolvedGroqKey = groqApiKey;
      if (resolvedGroqKey.isEmpty) {
        final accessToken = AuthSessionManager.instance.accessToken?.trim() ?? '';
        if (accessToken.isNotEmpty) {
          resolvedGroqKey = await RealtimeSessionApi().fetchGroqKey(accessToken: accessToken) ?? '';
        }
      }
      if (resolvedGroqKey.isEmpty) {
        _statusMessage = 'No se pudo obtener credenciales de Groq.';
        _safeNotify();
        return;
      }
      _chatClient = ChatCompletionClient(
        apiKey: resolvedGroqKey,
        onLog: _addLog,
      );
      _chatClient!.setSystemPrompt(_buildChatOnlyPrompt());
    }

    _chatResponses.add(ChatMessage(role: 'user', text: prompt));
    _safeNotify();
    onScrollChatToBottom?.call();

    _sessionStartedAt ??= DateTime.now();
    _sessionEndedAt = DateTime.now();

    _statusMessage = 'Enviando prompt manual';
    _responseInFlight = true;
    _assistantTurnSeq += 1;
    _activeAssistantTurnId = _assistantTurnSeq;
    _safeNotify();

    final ctx = _buildRecentContext();
    final userMessage = [
      'Mensaje del usuario (prioritario para este turno):\n$prompt',
      if (ctx.isNotEmpty) ctx,
    ].join('\n\n');

    await _chatClient!.sendMessage(
      userMessage: userMessage,
      onDelta: (delta) {
        _appendResponseDelta(delta);
      },
      onComplete: () {
        _handleResponseComplete();
      },
    );
  }

  // ────────────────────────────────────────────────────────────────────────
  // UI HELPERS
  // ────────────────────────────────────────────────────────────────────────

  String buildSuggestionsText() {
    final unique = <String>{};
    for (final s in _suggestions) {
      final c = s.trim();
      if (c.isNotEmpty) unique.add(c);
    }
    if (unique.isEmpty) {
      return 'Aun no hay sugerencias.\n\n'
          'Habla o envia un prompt para que la IA genere sugerencias.';
    }
    return unique.map((line) => '• $line').join('\n');
  }

  /// Plain text transcript — continuous paragraph, not separate lines.
  String buildTranscriptText() {
    final parts = <String>[];
    for (final line in _transcriptLines) {
      final t = line.trim();
      if (t.isNotEmpty) parts.add(t);
    }
    final current = _currentTranscript.trim();
    if (current.isNotEmpty) parts.add(current);
    return parts.join(' ');
  }

  void toggleFreestyleMode() {
    freestyleMode = !freestyleMode;
    applyUpdatedPrompt();
    _safeNotify();
  }

  // ────────────────────────────────────────────────────────────────────────
  // STREAMING
  // ────────────────────────────────────────────────────────────────────────

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

  void _appendTranscriptDelta(String text) {
    if (text.isEmpty) return;
    if (text != '\n' && text.trim().isNotEmpty) {
      _scheduleSilenceAutoStop();
    }

    if (text == '\n') {
      _flushTranscriptLine();
    } else {
      _currentTranscript += text;
    }

    // Handle embedded newlines
    String working = _currentTranscript;
    while (working.contains('\n')) {
      final idx = working.indexOf('\n');
      _currentTranscript = working.substring(0, idx);
      _flushTranscriptLine();
      working = working.substring(idx + 1);
    }
    _currentTranscript = working;

    _safeNotify();

    if (text != '\n') {
      _bumpIdleFlush();
    }

    onScrollTranscriptToBottom?.call();
  }

  void _flushTranscriptLine() {
    final chunk = _currentTranscript.trim();
    _currentTranscript = '';
    if (chunk.isEmpty) return;

    final cleaned = _cleanTranscriptChunk(chunk);
    if (cleaned == null || cleaned.trim().isEmpty) return;

    final normalized = cleaned.trim();

    // Dedup
    if (_lastLine == normalized) return;

    _transcriptLines.add(normalized);
    _lastLine = normalized;
    _wordsAccum += _wordCount(normalized);

    _addLog('🗣️ Transcripción: "${normalized.length > 50 ? '${normalized.substring(0, 50)}...' : normalized}"');
    _triggerResponseFromTranscript(normalized);
  }

  void _bumpIdleFlush() {
    _uiTranscriptIdleTimer?.cancel();
    _uiTranscriptIdleTimer = Timer(
      const Duration(milliseconds: _transcriptIdleFlushMs),
      () {
        _flushTranscriptLine();
        _safeNotify();
        onScrollTranscriptToBottom?.call();
      },
    );
  }

  void _handleResponseComplete() {
    _statusMessage = 'Respuesta completa';
    _safeNotify();

    final parsed = _parseAssistantOutput(_currentResponse);

    // Suggestions
    final suggestions = parsed['suggestions'] as List<String>;
    if (suggestions.isNotEmpty) {
      final existing = _suggestions.map((e) => e.trim().toLowerCase()).toSet();
      for (final s in suggestions) {
        final ns = _normalizeSuggestion(s).trim();
        if (ns.isEmpty) continue;
        if (existing.add(ns.toLowerCase())) _suggestions.add(ns);
      }
      _safeNotify();
      onScrollSuggestionsToBottom?.call();
    }

    // Chat
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
    _appendTranscriptDelta('\n');

    onScrollChatToBottom?.call();
    onScrollSuggestionsToBottom?.call();

    _responseInFlight = false;
    _activeAssistantTurnId = null;
    _safeNotify();

    if (_finalResponseQueued) {
      _finalResponseQueued = false;
      final now = DateTime.now();
      final sinceLast = _lastVoiceTriggerAt == null
          ? _voiceResponseMinInterval
          : now.difference(_lastVoiceTriggerAt!);
      if (sinceLast >= _voiceResponseMinInterval) {
        _startVoiceTriggeredResponse();
      } else {
        final delay = _voiceResponseMinInterval - sinceLast;
        _queuedResponseDelayTimer?.cancel();
        _queuedResponseDelayTimer = Timer(delay, () {
          if (_disposed || !_listening || _responseInFlight) return;
          _startVoiceTriggeredResponse();
        });
      }
      return;
    }

    if (!_listening) {
      _groqClient?.close();
      _chatClient?.close();
      _suggestionsClient?.close();
      unawaited(_maybeSaveConversation());
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  // RESPONSE TRIGGER
  // ────────────────────────────────────────────────────────────────────────

  void _triggerResponseFromTranscript(String transcriptLine) {
    if (!_listening) return;

    final cleanedLine = transcriptLine.trim();
    if (cleanedLine.length < _minCharsPerTurn) return;

    final now = DateTime.now();
    final key = cleanedLine.toLowerCase();
    if (key.isEmpty) return;

    // Dedup
    if (_lastVoiceTriggerKey == key &&
        _lastVoiceTriggerAt != null &&
        now.difference(_lastVoiceTriggerAt!) < const Duration(seconds: 12)) {
      return;
    }

    if (_responseInFlight) {
      _finalResponseQueued = true;
      return;
    }

    // Cooldown
    final novelWords = _wordsAccum - _wordsAtLastResponse;
    if (_lastVoiceTriggerAt != null &&
        now.difference(_lastVoiceTriggerAt!) < _voiceResponseMinInterval &&
        novelWords < _novelWordsToBypassCooldown) {
      return;
    }

    _lastVoiceTriggerAt = now;
    _lastVoiceTriggerKey = key;
    _wordsAtLastResponse = _wordsAccum;
    _addLog('✅ Disparando respuesta (${_wordCount(cleanedLine)} palabras)');
    _startVoiceTriggeredResponse();
  }

  void _startVoiceTriggeredResponse() {
    // With Groq pipeline, responses are triggered from _onGroqSpeechComplete
    return;
  }

  Future<void> _requestResponse() async {
    try {
      // No-op: Groq pipeline handles responses via _onGroqSpeechComplete
    } catch (error) {
      if (_disposed) return;
      _responseInFlight = false;
      _statusMessage = 'Error solicitando respuesta: $error';
      _safeNotify();
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  // WINDOWS MIC CAPTURE (ffmpeg dshow)
  // ────────────────────────────────────────────────────────────────────────

  Future<void> _startWindowsMicCapture() async {
    final micDevice = windowsMicDevice.trim();
    if (micDevice.isEmpty) {
      // Try auto-detect first mic
      final devices = await enumerateAudioDevices();
      if (devices.isNotEmpty) {
        final device = devices.first;
        _addLog('🎤 Usando micrófono: ${device.name}');
        await _startFfmpegMic(device.deviceId);
        if (_audioProcess == null) {
          await _startFfmpegMic(device.name);
        }
      } else {
        _addLog('❌ No se encontraron dispositivos de audio');
        _statusMessage = 'No se encontró micrófono.';
        _safeNotify();
      }
      return;
    }
    _addLog('🎤 Usando micrófono configurado: $micDevice');
    await _startFfmpegMic(micDevice);
  }

  Future<void> _startFfmpegMic(String device) async {
    try {
      final args = <String>[
        '-f', 'dshow',
        '-i', 'audio=$device',
        '-ac', '1',
        '-ar', '24000',
        '-f', 's16le',
        '-',
      ];

      final ffmpegPath = _resolveFfmpeg();
      final process = await Process.start(ffmpegPath, args);
      _audioProcess = process;
      _audioSubscription = process.stdout.listen(
        (chunk) {
          final bytes = Uint8List.fromList(chunk);
          _pendingMicBytes += bytes.length;
          _micVadBuffer?.addAudio(bytes);
          _logAudioLevel(bytes, label: 'mic');
        },
        onDone: () => _addLog('🔴 Captura de micrófono finalizada'),
      );

      process.exitCode.then((code) {
        if (code != 0) {
          _addLog('❌ Error en captura de micrófono (código $code)');
        }
      });

      process.stderr.transform(const Utf8Decoder()).listen((line) {
        if (showFfmpegLogs) _addLog('⚙️ [mic] $line');
      });
    } catch (error) {
      _addLog('❌ No se pudo iniciar captura de micrófono: $error');
      _statusMessage = 'No se pudo iniciar ffmpeg para el micrófono.';
      _listening = false;
      _safeNotify();
    }
  }

  String _resolveFfmpeg() {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final filename = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    final bundled = p.join(exeDir, filename);
    if (File(bundled).existsSync()) return bundled;

    final commonPaths = <String>[
      '/opt/homebrew/bin/ffmpeg',
      '/usr/local/bin/ffmpeg',
      '/usr/bin/ffmpeg',
      '/bin/ffmpeg',
    ];
    for (final candidate in commonPaths) {
      if (File(candidate).existsSync()) return candidate;
    }

    return 'ffmpeg';
  }

  Future<void> _stopWindowsMicCapture() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    if (_audioProcess != null) {
      _audioProcess!.kill();
      await _audioProcess!.exitCode;
      _audioProcess = null;
    }
  }

  // ── macOS MIC CAPTURE (avfoundation) ──────────────────────────────────────

  Future<void> _startMacOSMicCapture() async {
    final device = macosMicDevice.trim();
    _addLog('🎤 [macOS] Iniciando captura de micrófono (AVFoundation: :$device)...');
    try {
      final args = <String>[
        '-f', 'avfoundation',
        '-i', ':$device',
        '-ac', '1',
        '-ar', '24000',
        '-f', 's16le',
        '-',
      ];
      final process = await Process.start(_resolveFfmpeg(), args);
      _audioProcess = process;
      _audioSubscription = process.stdout.listen(
        (chunk) {
          _micVadBuffer?.addAudio(Uint8List.fromList(chunk));
        },
        onDone: () => _addLog('🔴 [macOS] Captura de micrófono finalizada'),
        onError: (e) {
          _statusMessage = 'Error en ffmpeg (mic macOS): $e';
          _safeNotify();
        },
      );
      process.exitCode.then((code) {
        if (code != 0) {
          _addLog('❌ [macOS] ffmpeg mic terminó con código $code — verifica el dispositivo con MACOS_MIC_DEVICE en .env');
        }
      });
      process.stderr.transform(const Utf8Decoder()).listen((line) {
        if (showFfmpegLogs) _addLog('⚙️ [macOS-mic] $line');
      });
      _addLog('✅ [macOS] Captura de micrófono iniciada');
    } catch (e) {
      _addLog('❌ [macOS] No se pudo iniciar captura de micrófono: $e');
      _statusMessage = 'No se pudo iniciar ffmpeg en macOS. Asegúrate de que ffmpeg esté en PATH.';
      _listening = false;
      _safeNotify();
    }
  }

  Future<void> _stopMacOSMicCapture() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    if (_audioProcess != null) {
      _audioProcess!.kill();
      await _audioProcess!.exitCode;
      _audioProcess = null;
    }
    _addLog('🔴 [macOS] Captura de micrófono detenida');
  }

  void _scheduleSilenceAutoStop() {
    _silenceAutoStopTimer?.cancel();
    if (!_listening) return;
    _silenceAutoStopTimer = Timer(_autoStopSilenceTimeout, () {
      if (_disposed || !_listening) return;
      _statusMessage = 'Silencio prolongado: sesión detenida';
      _safeNotify();
      unawaited(stopListening());
    });
  }

  // ────────────────────────────────────────────────────────────────────────
  // INSTRUCTIONS / CONTEXT
  // ────────────────────────────────────────────────────────────────────────

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
        if (fileName.isNotEmpty) buf.writeln('[$fileName]:');
        buf.writeln(text.trim());
        buf.writeln();
      }
      return buf.toString().trim();
    } catch (_) {
      return '';
    }
  }

  String _buildChatOnlyPrompt() {
    final buf = StringBuffer();
    buf.writeln('MODO REUNIÓN PRESENCIAL: Estás escuchando una reunión a través del micrófono. Escucharás a todas las personas presentes. Tu rol es asesorar al usuario en tiempo real.');
    buf.writeln();
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
    buf.writeln('- Completa todas las palabras y oraciones.');
    buf.writeln('- NO incluyas preguntas sugeridas.');
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
    buf.writeln('- No incluyas explicaciones ni texto adicional.');
    buf.writeln('- Responde en español.');
    return buf.toString();
  }

  String _buildRecentContext({int maxLines = 5}) {
    final buf = StringBuffer();
    if (_transcriptLines.isNotEmpty) {
      final recent = _transcriptLines.length > maxLines
          ? _transcriptLines.sublist(_transcriptLines.length - maxLines)
          : _transcriptLines;
      buf.writeln('Transcripción reciente de la reunión:');
      buf.writeln(recent.join('\n'));
    }
    return buf.toString().trim();
  }

  // ────────────────────────────────────────────────────────────────────────
  // SAVE
  // ────────────────────────────────────────────────────────────────────────

  Future<void> _maybeSaveConversation() async {
    if (_chatResponses.isEmpty && _transcriptLines.isEmpty) return;

    final startedAt = _sessionStartedAt ?? DateTime.now();
    final endedAt = _sessionEndedAt ?? DateTime.now();
    final duration = endedAt.difference(startedAt).inSeconds;
    final conversationId = '${startedAt.millisecondsSinceEpoch}';
    if (lastSavedConversationId == conversationId) return;

    final preview = _chatResponses.isNotEmpty
        ? _chatResponses.first.text
        : (_transcriptLines.isNotEmpty ? _transcriptLines.first : '');

    final title = _buildTitle(preview);

    final conversation = Conversation(
      id: conversationId,
      title: '[Reunión] $title',
      preview: preview,
      startedAt: startedAt,
      endedAt: endedAt,
      durationSeconds: duration,
      messages: _chatResponses
          .map((m) => ConversationMessage(role: m.role, text: m.text, at: m.at))
          .toList(),
      suggestions: List<String>.from(_suggestions),
      transcripts: List<String>.from(_transcriptLines),
    );

    try {
      await ConversationStore.instance.add(conversation);
      lastSavedConversationId = conversationId;
    } catch (_) {
      _addLog('⚠️ No se pudo guardar la conversación');
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  // TEXT PARSING (reused from normal mode)
  // ────────────────────────────────────────────────────────────────────────

  String _buildTitle(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 'Reunión';
    final words = trimmed.split(RegExp(r'\s+'));
    final titleWords = words.take(6).join(' ');
    return titleWords.length > 42 ? '${titleWords.substring(0, 42)}…' : titleWords;
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
    return trimmed;
  }

  String _extractFallbackChatText(String raw) {
    var text = _extractResponseText(raw).trim();
    if (text.isEmpty) return '';
    final kept = <String>[];
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (RegExp(r'^CHAT\s*:?\s*$', caseSensitive: false).hasMatch(t)) continue;
      if (RegExp(r'^SUGERENCIAS\s*:?\s*$', caseSensitive: false).hasMatch(t)) continue;
      if (t.toLowerCase().startsWith(_suggestionPrefix.toLowerCase())) continue;
      kept.add(t);
    }
    final fallback = kept.join('\n').trim();
    if (fallback.isEmpty) return '';
    return fallback.length > 800 ? fallback.substring(0, 800).trim() : fallback;
  }

  String _normalizeChatLine(String line) {
    var t = line.trim();
    if (t.isEmpty) return '';
    t = t.replaceAll(RegExp(r'\s*SUGERENCIAS\s*:.*$', caseSensitive: false), '').trim();
    if (t.isEmpty) return '';
    final prefix = _chatPrefixes.firstWhere(
      (p) => t.toLowerCase().startsWith(p.toLowerCase()),
      orElse: () => '',
    );
    if (prefix.isEmpty) {
      if (RegExp(r'^(chat|sugerencias)\s*:', caseSensitive: false).hasMatch(t)) return '';
      if (t.toLowerCase().startsWith(_suggestionPrefix.toLowerCase())) return '';
      return t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    }
    return t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  }

  String _normalizeSuggestion(String s) {
    var t = s.trim();
    final lower = t.toLowerCase();
    final i = lower.indexOf('pregunta sugerida:');
    if (i != -1) t = t.substring(i + 'pregunta sugerida:'.length).trim();
    if (t.length > 180) t = t.substring(0, 180).trim();
    return t;
  }

  String? _cleanTranscriptChunk(String chunk) {
    var t = chunk.trim();
    if (t.isEmpty) return null;
    final lower = t.toLowerCase();
    if (lower == '###' ||
        lower.startsWith('context:') ||
        lower.startsWith('contexto:') ||
        lower.contains('transcribe únicamente en español') ||
        lower.contains('transcribe unicamente en espanol')) {
      return null;
    }
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

    bool isSuggestionPrefix(String line) {
      return line.trimLeft().toLowerCase().startsWith(_suggestionPrefix.toLowerCase());
    }

    String stripPrefix(String line, String prefix) {
      final t = line.trim();
      if (t.length <= prefix.length) return '';
      return t.substring(prefix.length).trim();
    }

    // No sections found
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
        final n = _normalizeChatLine(t);
        if (n.isNotEmpty) chatOut.add(n);
      }
      return {'chat': chatOut.join('\n').trim(), 'suggestions': sugOut};
    }

    // Explicit sections
    final chatLinesRaw = <String>[];
    final suggestionLinesRaw = <String>[];

    if (chatIndex != -1) {
      final end = (suggestionIndex != -1 && suggestionIndex > chatIndex)
          ? suggestionIndex
          : lines.length;
      for (var i = chatIndex + 1; i < end; i++) chatLinesRaw.add(lines[i]);
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

  String _forceSectionNewlines(String t) {
    t = t.replaceAllMapped(
      RegExp(r'(\S)\s*(CHAT\s*:)', caseSensitive: false),
      (m) => '${m.group(1)}\n${m.group(2)}',
    );
    t = t.replaceAllMapped(
      RegExp(r'(\S)\s*(SUGERENCIAS\s*:)', caseSensitive: false),
      (m) => '${m.group(1)}\n${m.group(2)}',
    );
    return t;
  }

  // ────────────────────────────────────────────────────────────────────────
  // UTILITIES
  // ────────────────────────────────────────────────────────────────────────

  void _addLog(String entry) {
    final timestamp = DateTime.now().toIso8601String();
    final line = '[$timestamp] $entry';
    debugPrint(line);
    _debugLogs.add(line);
    if (_debugLogs.length > 500) _debugLogs.removeAt(0);
  }

  void _handleGroqError(String userMessage) {
    _addLog('⚠️ $userMessage');
    _statusMessage = userMessage;
    _safeNotify();
  }

  int _wordCount(String text) {
    final t = text.trim();
    if (t.isEmpty) return 0;
    return t.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).length;
  }

  DateTime? _lastLevelLog;

  void _logAudioLevel(Uint8List bytes, {String label = 'mic'}) {
    return;
    // ignore: dead_code
    if (bytes.length < 2) return;
    final now = DateTime.now();
    if (_lastLevelLog != null &&
        now.difference(_lastLevelLog!) < const Duration(seconds: 3)) {
      return;
    }
    _lastLevelLog = now;

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
    final level = db > -10
        ? '🔊 Alto'
        : db > -30
            ? '🔉 Normal'
            : db > -50
                ? '🔈 Bajo'
                : '🔇 Muy bajo/silencio';
    _addLog('🎚️ Micrófono: $level (${db.toStringAsFixed(0)} dB)');
  }

  Uint8List _floatTo16(List<double> source) {
    final buffer = Int16List(source.length);
    for (var i = 0; i < source.length; i++) {
      var sample = (source[i] * 32767).round();
      if (sample > 32767) sample = 32767;
      else if (sample < -32768) sample = -32768;
      buffer[i] = sample;
    }
    return buffer.buffer.asUint8List();
  }

  // ────────────────────────────────────────────────────────────────────────
  // DISPOSE
  // ────────────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _realtimeTimer?.cancel();
    _uiTranscriptIdleTimer?.cancel();
    _queuedResponseDelayTimer?.cancel();
    _silenceAutoStopTimer?.cancel();
    onRequestStopPlatformCapture?.call();
    _audioSubscription?.cancel();
    _audioProcess?.kill();
    _groqClient?.close();
    _chatClient?.close();
    _suggestionsClient?.close();
    _micVadBuffer?.dispose();
    super.dispose();
  }
}
