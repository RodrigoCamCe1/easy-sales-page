import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_config.dart';
import '../models/conversation.dart';
import '../services/agent_profile_store.dart';
import '../services/conversation_store.dart';
import '../services/openai_realtime_client.dart';

class RecordingBarApp extends StatelessWidget {
  const RecordingBarApp({super.key});

  @override
  Widget build(BuildContext context) {
    const brightness = Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: brightness,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AsesorIA Audio Bar',
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        brightness: brightness,
        scaffoldBackgroundColor: Colors.transparent,
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: const RecordingBar(),
    );
  }
}

class RecordingBar extends StatefulWidget {
  const RecordingBar({super.key});

  @override
  State<RecordingBar> createState() => _RecordingBarState();
}

class _RecordingBarState extends State<RecordingBar> {
  bool _listening = false;
  Duration _elapsed = Duration.zero;
  Timer? _timer;
  Timer? _realtimeTimer;
  Timer? _uiTranscriptIdleTimer;
  Timer? _queuedResponseDelayTimer;
  Timer? _silenceAutoStopTimer;

  final ScrollController _chatScrollController = ScrollController();
  final ScrollController _suggestionScrollController = ScrollController();
  final ScrollController _transcriptScrollController = ScrollController();
  final TextEditingController _manualPromptController = TextEditingController();

  final FlutterAudioCapture _audioCapture = FlutterAudioCapture();
  OpenAIRealtimeClient? _openAIClientMic;
  OpenAIRealtimeClient? _openAIClientSystem;

  // âœ… Chat ahora es lista de mensajes (user/assistant)
  final List<_ChatMessage> _chatResponses = [];

  final List<String> _suggestions = [];
  String _currentResponse = '';

  // âœ… TranscripciÃ³n separada (no debe contaminar Chat/Sugerencias)
  final List<String> _transcripts = [];
  // buffers separados para que no se mezclen
  String _currentTranscriptSys = '';
  String _currentTranscriptMic = '';
  // para dedupe por fuente
  String? _lastSysLine;
  String? _lastMicLine;

  String _statusMessage = '';
  Process? _audioProcessSystem;
  Process? _audioProcessMic;
  StreamSubscription<List<int>>? _audioSubscriptionSystem;
  StreamSubscription<List<int>>? _audioSubscriptionMic;
  int _pendingMicBytes = 0;
  int _pendingSystemBytes = 0;

  bool _responseInFlight = false;
  bool _micResponseInFlight = false;
  bool _finalResponseQueued = false;
  String _queuedResponseSource = 'sys';
  String _queuedTranscriptKey = '';
  int _assistantTurnSeq = 0;
  int? _activeAssistantTurnId;
  DateTime? _lastVoiceTriggerAt;
  String _lastVoiceTriggerKey = '';
  int? _streamingAssistantIndex;
  String _streamingAssistantText = '';
  bool _assistantStreamStarted = false;
  DateTime? _lastLevelLogAt;
  String _promptOverride = '';
  String _activeAgentName = 'Personalizar tu agente';
  String _activeAgentMode = 'custom';
  bool _micMixEnabled = false;
  bool _showSuggestions = false;
  bool _suggestionsSidebarOpen = true;
  DateTime? _sessionStartedAt;
  DateTime? _sessionEndedAt;
  bool _conversationSaved = false;

  bool _showTranscript = false;
  static const Duration _voiceResponseMinInterval = Duration(seconds: 15);
  static const int _transcriptIdleFlushMs = 1700;
  static const Duration _micTranscriptMergeWindow = Duration(seconds: 6);
  static const Duration _autoStopSilenceTimeout = Duration(seconds: 21);
  static const Duration _micPauseAfterActivity = Duration(seconds: 4);
  static const int _minSystemWordsPerTurn = 10;
  static const int _minSystemCharsPerTurn = 30;
  static const int _novelSystemWordsToBypassCooldown = 15;

  bool get _systemOnlyMode => Platform.isWindows;
  DateTime? _lastMicTranscriptAt;
  DateTime? _micPauseUntil;
  int _systemWordsAccum = 0;
  int _systemWordsAtLastResponse = 0;

  bool _isRealBarWindow() {
    // La barra solo existe cuando fue creada con type=bar
    // Settings nunca deberÃ­a ejecutar esto
    return true;
  }

  bool get _audioSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isLinux;
  bool get _windowsMicAvailable =>
      Platform.isWindows && windowsMicDevice.trim().isNotEmpty;

  void _addLog(String entry) {
    final timestamp = DateTime.now().toIso8601String();
    debugPrint('[$timestamp] $entry');
  }

  void _scrollToBottom(ScrollController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) return;
      controller.animateTo(
        controller.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _toggleTranscript() {
    setState(() {
      _showTranscript = !_showTranscript;
      if (_showTranscript) _showSuggestions = false;
    });
  }

  void _toggleSuggestions() {
    setState(() {
      _suggestionsSidebarOpen = !_suggestionsSidebarOpen;
    });
  }

  Future<void> _loadActiveAgent() async {
    final active = await AgentProfileStore.instance.getActiveAgent();
    if (!mounted) return;
    setState(() {
      _promptOverride = active.composedPrompt;
      _activeAgentName = active.name;
      _activeAgentMode = active.mode;
    });
    _openAIClientMic?.updateSessionInstructions(_promptOverride);
    _openAIClientSystem?.updateSessionInstructions(_promptOverride);
    _addLog('Agente activo: $_activeAgentName ($_activeAgentMode)');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _configureFramelessWindow();
    });

    _promptOverride = systemPrompt;
    _micMixEnabled = _windowsMicAvailable;
    _loadActiveAgent();

    // âœ… Esto siempre debe ejecutarse SOLO en la ventana BAR
    _notifyBarOpened();

    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      if (call.method == 'updatePrompt') {
        final args = call.arguments as Map?;
        final prompt = args?['prompt'] as String? ?? '';
        final agentName = args?['agentName'] as String?;
        final agentMode = args?['agentMode'] as String?;
        setState(() {
          _promptOverride = prompt.isEmpty ? systemPrompt : prompt;
          if (agentName != null && agentName.trim().isNotEmpty) {
            _activeAgentName = agentName.trim();
          }
          if (agentMode != null && agentMode.trim().isNotEmpty) {
            _activeAgentMode = agentMode.trim();
          }
        });
        _openAIClientMic?.updateSessionInstructions(_promptOverride);
        _openAIClientSystem?.updateSessionInstructions(_promptOverride);
      }

      if (call.method == 'setMicMix') {
        await _setMicMixEnabled(_windowsMicAvailable);
      }

      return null;
    });
  }

  Future<void> _configureFramelessWindow() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        await windowManager.ensureInitialized();
        await windowManager.setAsFrameless();
        return;
      } catch (error) {
        if (attempt == 3) {
          debugPrint('RecordingBar frameless setup failed: $error');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
  }

  Future<void> _notifyBarOpened() async {
    try {
      await DesktopMultiWindow.invokeMethod(0, 'barOpened');
    } catch (_) {}
  }

  Future<void> _requestMainAction(String action) async {
    try {
      await DesktopMultiWindow.invokeMethod(0, action);
    } catch (_) {}
  }

  Future<void> _startListening() async {
    if (_listening) return;
    await _loadActiveAgent();

    if (openAIKey.isEmpty) {
      setState(() {
        _statusMessage =
            'Define OPENAI_API_KEY con `--dart-define=OPENAI_API_KEY=sk-...` para habilitar la IA.';
      });
      return;
    }

    await _openAIClientMic?.close();
    await _openAIClientSystem?.close();
    _openAIClientMic = null;
    _openAIClientSystem = null;

    // âœ… limpia timers UI transcript
    _uiTranscriptIdleTimer?.cancel();
    _uiTranscriptIdleTimer = null;
    _queuedResponseDelayTimer?.cancel();
    _queuedResponseDelayTimer = null;
    _silenceAutoStopTimer?.cancel();
    _silenceAutoStopTimer = null;

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _elapsed = Duration(seconds: timer.tick);
      });
    });

    _sessionStartedAt = DateTime.now();
    _sessionEndedAt = null;
    _conversationSaved = false;

    _pendingMicBytes = 0;
    _pendingSystemBytes = 0;
    _responseInFlight = false;
    _micResponseInFlight = false;
    _finalResponseQueued = false;
    _queuedResponseSource = _systemOnlyMode ? 'sys' : 'mic';
    _queuedTranscriptKey = '';
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
    _micPauseUntil = null;
    _systemWordsAccum = 0;
    _systemWordsAtLastResponse = 0;

    _statusMessage = 'Conectando con OpenAI';

    _addLog('Iniciando sesion con OpenAI');
    final promptPreview = _promptOverride.length > 120
        ? '${_promptOverride.substring(0, 120)}...'
        : _promptOverride;
    _addLog('Prompt activo: $promptPreview');

    _openAIClientMic = OpenAIRealtimeClient(
      openAIKey: openAIKey,
      model: openAIRealtimeModel,
      vadSilenceMs: vadSilenceMs,
      sessionInstructions: _promptOverride,
      onDelta: _appendResponseDelta,
      onTranscriptDelta: (t) {
        _appendTranscriptDelta(t, source: 'mic');
      },
      onComplete: () {
        _appendTranscriptDelta('\n', source: 'mic');
        _handleResponseComplete();
      },
      showEvents: showOpenAIEvents,
      sourceTag: 'mic',
    );

    _openAIClientSystem = null;
    final hasSystemDevice =
        Platform.isWindows && windowsAudioDevice.trim().isNotEmpty;
    if (hasSystemDevice) {
      _openAIClientSystem = OpenAIRealtimeClient(
        openAIKey: openAIKey,
        model: openAIRealtimeModel,
        vadSilenceMs: vadSilenceMs,
        sessionInstructions: _promptOverride,
        onDelta: _appendResponseDelta,
        onTranscriptDelta: (t) {
          _appendTranscriptDelta(t, source: 'sys');
        },
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
      setState(() {
        _listening = false;
        _statusMessage = 'No se pudo conectar con OpenAI: $error';
      });
      _timer?.cancel();
      _elapsed = Duration.zero;
      return;
    }

    setState(() {
      _listening = true;
      _statusMessage = Platform.isWindows
          ? 'Conectado a OpenAI. Escuchando audio del sistema...'
          : 'Conectado a OpenAI. Escuchando microfono...';
    });
    _scheduleSilenceAutoStop();

    if (Platform.isWindows) {
      await _startWindowsCapture();
    } else if (_audioSupported) {
      try {
        final initialized = await _audioCapture.init();
        if (initialized != true) {
          throw Exception('FlutterAudioCapture failed to init');
        }
        await _audioCapture.start(
          (data) {
            final audioSource =
                (data as Iterable).cast<double>().toList(growable: false);
            final audioBytes = _floatTo16(audioSource);
            _appendAudio(audioBytes);
          },
          (error) {
            setState(() {
              _statusMessage = 'Error de captura: $error';
            });
          },
          sampleRate: 16000,
          bufferSize: 3000,
        );
        setState(() {
          _statusMessage =
              'AsesorIA iniciada: conectada a OpenAI. Ya puedes hablar.';
        });
      } catch (error) {
        setState(() {
          _statusMessage = 'No se pudo iniciar la captura: $error';
          _listening = false;
          _timer?.cancel();
          _elapsed = Duration.zero;
        });
      }
    } else {
      setState(() {
        _statusMessage = 'Captura de sistema no disponible en esta plataforma.';
        _listening = false;
      });
    }

    _realtimeTimer?.cancel();
    _realtimeTimer = Timer.periodic(
      Duration(seconds: realtimeFlushSeconds),
      (_) => _flushRealtimeBoth(),
    );
  }

  Future<void> _sendManualPrompt() async {
    await _loadActiveAgent();
    final prompt = _manualPromptController.text.trim();
    if (prompt.isEmpty) return;

    if (openAIKey.isEmpty) {
      setState(() {
        _statusMessage =
            'Define OPENAI_API_KEY con `--dart-define=OPENAI_API_KEY=sk-...` para habilitar la IA.';
      });
      return;
    }

    // âœ… Muestra el mensaje del usuario como burbuja.
    setState(() {
      _chatResponses.add(_ChatMessage(role: 'user', text: prompt));
    });
    _scrollToBottom(_chatScrollController);

    if (_openAIClientMic == null) {
      _openAIClientMic = OpenAIRealtimeClient(
        openAIKey: openAIKey,
        model: openAIRealtimeModel,
        vadSilenceMs: vadSilenceMs,
        sessionInstructions: _promptOverride,
        onDelta: _appendResponseDelta,
        onTranscriptDelta: (t) {
          _appendTranscriptDelta(t, source: 'mic');
        },
        onComplete: () {
          _appendTranscriptDelta('\n', source: 'mic');
          _handleResponseComplete();
        },
        showEvents: showOpenAIEvents,
        sourceTag: 'mic',
      );
      await _openAIClientMic?.connect();
    }

    _sessionStartedAt ??= DateTime.now();
    _sessionEndedAt = DateTime.now();
    _conversationSaved = false;

    setState(() {
      _statusMessage = 'Enviando prompt manual';
      _responseInFlight = true;
      _micResponseInFlight = true;
      _assistantTurnSeq += 1;
      _activeAssistantTurnId = _assistantTurnSeq;
    });

    _manualPromptController.clear();

    // âœ… por si venÃ­a una transcripciÃ³n abierta, cerramos lÃ­neas antes de responder
    _appendTranscriptDelta('\n', source: 'mic');

    await _openAIClientMic?.requestResponse(
      instructions: _buildChatInstructions(userPrompt: prompt),
    );
  }

  Future<void> _stopListening() async {
    if (!_listening) return;

    _timer?.cancel();
    _realtimeTimer?.cancel();
    _realtimeTimer = null;
    _queuedResponseDelayTimer?.cancel();
    _queuedResponseDelayTimer = null;
    _silenceAutoStopTimer?.cancel();
    _silenceAutoStopTimer = null;

    // Cierra cualquier lÃ­nea abierta antes de detener captura.
    _appendTranscriptDelta('\n', source: 'sys');
    _appendTranscriptDelta('\n', source: 'mic');

    _sessionEndedAt = DateTime.now();

    if (Platform.isWindows) {
      await _stopWindowsCapture();
    } else if (_audioSupported) {
      _addLog('Deteniendo flutter_audio_capture');
      await _audioCapture.stop();
    }

    // âœ… si queda audio pendiente, forzar commit
    if (_pendingSystemBytes > 0) {
      final committed = await _openAIClientSystem?.commitBuffer() ?? false;
      if (committed) {
        _pendingSystemBytes = 0;
      }
    }

    if (_pendingMicBytes > 0) {
      final committed = await _openAIClientMic?.commitBuffer() ?? false;
      if (committed) {
        _pendingMicBytes = 0;
      }
    }

    setState(() {
      _listening = false;
      _elapsed = Duration.zero;
      _statusMessage = 'Procesando respuesta';
    });

    if (!_micResponseInFlight && !_responseInFlight && !_finalResponseQueued) {
      await _openAIClientMic?.close();
      _openAIClientMic = null;
      await _openAIClientSystem?.close();
      _openAIClientSystem = null;
      _maybeSaveConversation();
    }
  }

  Future<void> _openSettings() async {
    final active = await AgentProfileStore.instance.getActiveAgent();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final screenWidth = view.physicalSize.width / view.devicePixelRatio;
    final screenHeight = view.physicalSize.height / view.devicePixelRatio;
    const topOffset = 28.0;
    final window = await DesktopMultiWindow.createWindow(jsonEncode({
      'type': 'settings',
      'mainWindowId': 0,
      'prompt': active.prompt,
      'agentId': active.id,
      'agentName': active.name,
      'agentMode': active.mode,
      'canEditPrompt': active.canEditPrompt,
    }));
    window
      ..setFrame(
        Rect.fromLTWH(0, topOffset, screenWidth, screenHeight - topOffset),
      )
      ..setTitle('Configuracion')
      ..show();
  }

  void _openMicPrivacySettings() {
    _addLog('Abriendo configuracion de micrÃ³fono en Windows');
    Process.start('cmd', ['/c', 'start', 'ms-settings:privacy-microphone']);
  }

  // ============================
  // âœ… STREAMING
  // ============================

  void _appendResponseDelta(String delta) {
    if (delta.isEmpty) return;

    setState(() {
      _currentResponse += delta;
      _statusMessage = 'Respuesta en pantalla';

      // Crea burbuja "en vivo"
      if (!_assistantStreamStarted) {
        _assistantStreamStarted = true;
        _chatResponses.add(
          _ChatMessage(
            role: 'assistant',
            text: '',
            assistantTurnId: _activeAssistantTurnId,
          ),
        );
        _streamingAssistantIndex = _chatResponses.length - 1;
      }

      // âœ… Pintar SOLO chat vÃ¡lido (no preguntas sugeridas)
      _streamingAssistantText = _buildStreamingChatPreview(_currentResponse);

      final idx = _streamingAssistantIndex;
      if (idx != null && idx >= 0 && idx < _chatResponses.length) {
        // Si todavÃ­a no hay nada â€œchat vÃ¡lidoâ€, no muestres basura
        final visible = _streamingAssistantText.trim();
        _chatResponses[idx] = _ChatMessage(
          role: 'assistant',
          text: visible.isEmpty ? '...' : visible,
          assistantTurnId: _activeAssistantTurnId,
        );
      }
    });

    _scrollToBottom(_chatScrollController);
  }

  String _buildStreamingChatPreview(String raw) {
    if (raw.trim().isEmpty) return '';

    final text = _extractResponseText(raw);

    // 1) Normaliza saltos de lÃ­nea y corta por lÃ­neas
    final lines = text.split('\n');

    // 2) Quedate solo con lÃ­neas que sean â€œCHAT prefixâ€
    final kept = <String>[];
    for (final line in lines) {
      final t = line.trim();
      if (t.isEmpty) continue;

      // Nunca mostrar preguntas sugeridas en el chat en vivo
      if (t.toLowerCase().startsWith(_suggestionPrefix.toLowerCase())) continue;

      final n = _normalizeChatLine(t); // devuelve '' si no es prefijo vÃ¡lido
      if (n.isNotEmpty) kept.add(n);
    }

    // 3) Dedup simple manteniendo orden
    final seen = <String>{};
    final out = <String>[];
    for (final l in kept) {
      if (seen.add(l)) out.add(l);
    }

    // 4) Mostramos mÃ¡ximo 4 lÃ­neas (tu regla)
    if (out.length > 4) {
      return out.take(4).join('\n');
    }
    if (out.isNotEmpty) {
      return out.join('\n');
    }
    return _extractFallbackChatText(text);
  }

  /// âœ… Llama con text normal.
  /// Opcional: source = 'sys' o 'mic'
  void _appendTranscriptDelta(String text, {String source = 'sys'}) {
    if (text.isEmpty) return;
    if (text != '\n' && text.trim().isNotEmpty) {
      _scheduleSilenceAutoStop();
    }

    // normaliza source
    source = source.toLowerCase().trim();
    if (source != 'mic') source = 'sys';

    // Si llega un "\n" explÃ­cito, solo cerramos la lÃ­nea de la fuente correspondiente
    void flushOneLine({required bool isMic}) {
      final buf = isMic ? _currentTranscriptMic : _currentTranscriptSys;
      final chunk = buf.trim();
      if (chunk.isEmpty) return;

      final cleaned = _cleanTranscriptChunk(chunk);
      if (cleaned != null && cleaned.trim().isNotEmpty) {
        final normalized = cleaned.trim();
        final tagged = isMic ? 'ðŸŽ¤ $cleaned' : 'ðŸ–¥ï¸ $cleaned';

        // dedupe por fuente
        if (isMic) {
          if (_lastMicLine != tagged) {
            final now = DateTime.now();
            final merged = _tryMergeMicTranscript(cleaned, now);
            if (!merged) {
              _transcripts.add(tagged);
            }
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

    // â±ï¸ Idle flush: si no llegan mÃ¡s deltas, cerramos lÃ­nea automÃ¡ticamente
    void bumpIdleFlush({required bool isMic, int ms = _transcriptIdleFlushMs}) {
      _uiTranscriptIdleTimer?.cancel();
      _uiTranscriptIdleTimer = Timer(Duration(milliseconds: ms), () {
        setState(() {
          flushOneLine(isMic: isMic);
        });
        _scrollToBottom(_transcriptScrollController);
      });
    }

    final isMic = source == 'mic';

    setState(() {
      // 1) Agrega texto al buffer correcto
      if (text == '\n') {
        flushOneLine(isMic: isMic);
      } else {
        if (isMic) {
          _markMicActivity();
          _currentTranscriptMic += text;
        } else {
          _currentTranscriptSys += text;
        }
      }

      // 2) Si el backend manda "\n" dentro del texto, partimos por lÃ­neas
      String working = isMic ? _currentTranscriptMic : _currentTranscriptSys;

      while (working.contains('\n')) {
        final idx = working.indexOf('\n');
        final line = working.substring(0, idx);

        // set temporal para que flush use ese contenido
        if (isMic) {
          _currentTranscriptMic = line;
        } else {
          _currentTranscriptSys = line;
        }

        flushOneLine(isMic: isMic);

        // continÃºa con el resto
        working = working.substring(idx + 1);
      }

      // guarda el residual que quedÃ³ sin \n
      if (isMic) {
        _currentTranscriptMic = working;
      } else {
        _currentTranscriptSys = working;
      }
    });

    // 3) Si no fue "\n", programamos cierre automÃ¡tico por silencio de transcript
    if (text != '\n') {
      bumpIdleFlush(isMic: isMic);
    }

    _scrollToBottom(_transcriptScrollController);
  }

  bool _tryMergeMicTranscript(String cleaned, DateTime now) {
    if (_transcripts.isEmpty) return false;
    final lastIndex = _transcripts.length - 1;
    final last = _transcripts[lastIndex].trim();
    if (!last.startsWith('ðŸŽ¤ ')) return false;
    if (_lastMicTranscriptAt == null ||
        now.difference(_lastMicTranscriptAt!) > _micTranscriptMergeWindow) {
      return false;
    }

    final previous = last.replaceFirst(RegExp(r'^ðŸŽ¤\s*'), '').trim();
    if (previous.isEmpty) return false;

    final prevKey = previous.toLowerCase();
    final nextKey = cleaned.trim().toLowerCase();
    if (nextKey.isEmpty) return false;

    if (prevKey == nextKey || prevKey.contains(nextKey)) return true;

    final merged = nextKey.contains(prevKey)
        ? cleaned.trim()
        : '$previous ${cleaned.trim()}';
    _transcripts[lastIndex] = 'ðŸŽ¤ $merged';
    return true;
  }

  List<String> _splitChatIntoBubbles(String chatBlock) {
    final out = <String>[];
    for (final line in chatBlock.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final cleaned = t.replaceFirst(RegExp(r'^[-â€¢]\s*'), '').trim();
      if (cleaned.isNotEmpty) out.add(cleaned);
    }
    return out;
  }

  void _pushAssistantBubble(String text) {
    final t = text.trim();
    if (t.isEmpty) return;

    // âœ… anti-duplicado consecutivo
    if (_chatResponses.isNotEmpty &&
        _chatResponses.last.role == 'assistant' &&
        _chatResponses.last.text.trim() == t) {
      return;
    }

    _chatResponses.add(
      _ChatMessage(
        role: 'assistant',
        text: t,
        assistantTurnId: _activeAssistantTurnId,
      ),
    );
  }

  void _handleResponseComplete() {
    setState(() {
      _statusMessage = 'Respuesta completa';
    });

    final parsed = _parseAssistantOutput(_currentResponse);

    // ====== SUGERENCIAS (dedup global) ======
    final suggestions = (parsed['suggestions'] as List<String>);
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
        setState(() => _suggestions.addAll(toAdd));
      }
    }

    // ====== CHAT ======
    final chat = (parsed['chat'] as String).trim();

    final finalLines = <String>[];
    if (chat.isNotEmpty) {
      final rawLines = chat
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      final normalized = <String>[];
      for (final l in rawLines) {
        final n = _normalizeChatLine(l);
        if (n.isNotEmpty) normalized.add(n);
      }

      // dedup dentro del bloque manteniendo orden
      final seen = <String>{};
      for (final l in normalized) {
        if (seen.add(l)) finalLines.add(l);
      }
    }

    if (finalLines.isEmpty) {
      final fallback = _extractFallbackChatText(_currentResponse);
      if (fallback.isNotEmpty) {
        finalLines.add(fallback);
      }
    }

    setState(() {
      final idx = _streamingAssistantIndex;

      // Si NO pudimos parsear chatLines, NO borres la burbuja streaming:
      // Ãºsala como mensaje final (para que no â€œdesaparezcaâ€)
      if (finalLines.isEmpty) {
        if (idx != null && idx >= 0 && idx < _chatResponses.length) {
          final fallback = _streamingAssistantText.trim();
          if (fallback.isNotEmpty) {
            _chatResponses[idx] = _ChatMessage(
              role: 'assistant',
              text: fallback,
              assistantTurnId: _activeAssistantTurnId,
            );
          }
        }
      } else {
        // Si SÃ hay chatLines, reemplaza la burbuja streaming por lÃ­neas finales
        if (idx != null && idx >= 0 && idx < _chatResponses.length) {
          _chatResponses.removeAt(idx);
        }
        for (final line in finalLines) {
          if (_chatResponses.isNotEmpty &&
              _chatResponses.last.role == 'assistant' &&
              _chatResponses.last.text.trim() == line) {
            continue;
          }
          _chatResponses.add(
            _ChatMessage(
              role: 'assistant',
              text: line,
              assistantTurnId: _activeAssistantTurnId,
            ),
          );
        }
      }

      _streamingAssistantIndex = null;
      _streamingAssistantText = '';
      _assistantStreamStarted = false;
    });

    // Limpia acumuladores del turno
    _currentResponse = '';

    // ====== TRANSCRIPT final ======
    _appendTranscriptDelta('\n', source: 'sys');
    _appendTranscriptDelta('\n', source: 'mic');

    _scrollToBottom(_chatScrollController);
    _scrollToBottom(_suggestionScrollController);

    setState(() {
      _micResponseInFlight = false;
      _responseInFlight = false;
      _activeAssistantTurnId = null;
    });

    if (_finalResponseQueued) {
      final queuedSource = _queuedResponseSource;
      _finalResponseQueued = false;
      _queuedTranscriptKey = '';
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
          if (!mounted ||
              !_listening ||
              _responseInFlight ||
              _micResponseInFlight) {
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

  // ============================
  // âœ… SAVE CONVERSATION
  // ============================

  Future<void> _maybeSaveConversation() async {
    if (_conversationSaved) return;
    if (_chatResponses.isEmpty && _transcripts.isEmpty) return;

    final startedAt = _sessionStartedAt ?? DateTime.now();
    final endedAt = _sessionEndedAt ?? DateTime.now();
    final duration = endedAt.difference(startedAt).inSeconds;

    final preview = _chatResponses.isNotEmpty
        ? _chatResponses.first.text
        : (_transcripts.isNotEmpty ? _transcripts.first : '');

    final title = _buildTitle(preview);

    final conversation = Conversation(
      id: '${startedAt.millisecondsSinceEpoch}',
      title: title,
      preview: preview,
      startedAt: startedAt,
      endedAt: endedAt,
      durationSeconds: duration,
      messages: _chatResponses
          .map(
            (m) => ConversationMessage(
              role: m.role,
              text: m.text,
              at: m.at,
            ),
          )
          .toList(),
      suggestions: List<String>.from(_suggestions),
      transcripts: List<String>.from(_transcripts),
    );

    await ConversationStore.instance.add(conversation);
    _conversationSaved = true;
  }

  String _buildTitle(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return 'ConversaciÃ³n';
    final words = trimmed.split(RegExp(r'\s+'));
    final titleWords = words.take(6).join(' ');
    return titleWords.length > 42
        ? '${titleWords.substring(0, 42)}â€¦'
        : titleWords;
  }
  // ============================
// âœ… NORMALIZADORES (anti-duplicados / limpieza)
// ============================

  static const List<String> _chatPrefixes = [
    'Respuesta sugerida:',
    'ObjeciÃ³n detectada:',
    'Objecion detectada:', // por si el modelo no pone tilde
    'Momento de cierre:',
  ];

  static const String _suggestionPrefix = 'Pregunta sugerida:';

  String _normalizeChatLine(String line) {
    var t = line.trim();
    if (t.isEmpty) return '';

    // Si viene cola pegada de sugerencias, cortarla para no contaminar CHAT.
    t = t
        .replaceAll(
          RegExp(r'\s*SUGERENCIAS\s*:.*$', caseSensitive: false),
          '',
        )
        .trim();
    if (t.isEmpty) return '';

    // Solo permitimos lÃ­neas que empiecen con prefijos de CHAT
    final prefix = _chatPrefixes.firstWhere(
      (p) => t.toLowerCase().startsWith(p.toLowerCase()),
      orElse: () => '',
    );
    if (prefix.isEmpty) return '';

    // Caso: "Respuesta sugerida: X Respuesta sugerida: X"
    final second = t.toLowerCase().indexOf(prefix.toLowerCase(), prefix.length);
    if (second != -1) {
      final a = t.substring(prefix.length, second).trim();
      final b = t.substring(second + prefix.length).trim();
      if (a.isNotEmpty && (a == b || b.startsWith(a))) {
        return '$prefix $a';
      }
      if (a.isNotEmpty) return '$prefix $a';
    }

    t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return t;
  }

  String _normalizeSuggestion(String s) {
    var t = s.trim();
    t = t.replaceAll('ðŸ‘‰', '').replaceAll('ðŸ’¡', '').trim();

    // Si viene "Pregunta sugerida: ..." quedarnos solo con el valor
    final lower = t.toLowerCase();
    final i = lower.indexOf('pregunta sugerida:');
    if (i != -1) {
      t = t.substring(i + 'pregunta sugerida:'.length).trim();
    }

    // Opcional: cortar muy largas
    if (t.length > 180) t = t.substring(0, 180).trim();

    return t;
  }

  String _collapseImmediateRepeat(String t) {
    var s = t.trim();
    if (s.isEmpty) return s;

    // NormalizaciÃ³n ligera para comparar (sin destruir el original)
    String norm(String x) =>
        x.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

    // Si el texto es literalmente "A A" separado por espacio / puntuaciÃ³n
    // intentamos encontrar el mejor corte posible.
    final tokens = s.split(RegExp(r'\s+'));
    if (tokens.length < 2) return s;

    // Probamos varios tamaÃ±os de bloque (desde 1 token hasta la mitad)
    final maxBlock = (tokens.length / 2).floor();
    final normTokens = tokens.map(norm).toList();

    for (int block = 1; block <= maxBlock; block++) {
      // Compara bloque inicial vs bloque siguiente del mismo tamaÃ±o
      bool equal = true;
      for (int i = 0; i < block; i++) {
        if (normTokens[i] != normTokens[i + block]) {
          equal = false;
          break;
        }
      }
      if (equal) {
        // Devuelve la primera mitad real (sin normalizar)
        return tokens.take(block).join(' ').trim();
      }
    }

    return s;
  }

  String? _cleanTranscriptChunk(String chunk) {
    var t = chunk.trim();
    if (t.isEmpty) return null;

    final lower = t.toLowerCase();

    // Basura tÃ­pica que se cuela en transcript
    final looksLikeContext = lower == '###' ||
        lower.startsWith('context:') ||
        lower.startsWith('###context') ||
        lower == 'context';

    final looksLikeInstruction =
        lower.contains('transcribe Ãºnicamente en espaÃ±ol') ||
            lower.contains('transcribe unicamente en espanol');

    if (looksLikeContext || looksLikeInstruction) return null;

    // Colapsa repeticiÃ³n inmediata de frases: "Gracias. Gracias."
    t = t.replaceAllMapped(
      RegExp(r'(\b\w+[.!?])\1+'),
      (m) => m.group(1)!,
    );
    // Colapsa repeticiÃ³n inmediata (tu helper)
    t = _collapseImmediateRepeat(t);

    // Normaliza espacios
    t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();

    return t.isEmpty ? null : t;
  }

  // ============================
  // âœ… PARSE OUTPUT
  // ============================

  String _extractResponseText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';

    // Si viene un JSON con llm_generated_text
    if (trimmed.startsWith('{') && trimmed.contains('llm_generated_text')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map && decoded['llm_generated_text'] is String) {
          return (decoded['llm_generated_text'] as String).trim();
        }
      } catch (_) {}
    }

    // fallback: intenta extraer el valor de llm_generated_text manualmente
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

    // bloquea tool_calls / session params basura
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
          .hasMatch(t)) {
        continue;
      }
      if (t.toLowerCase().startsWith(_suggestionPrefix.toLowerCase())) continue;
      kept.add(t);
    }

    final fallback = kept.join('\n').trim();
    if (fallback.isEmpty) return '';
    return fallback.length > 800 ? fallback.substring(0, 800).trim() : fallback;
  }

  String _cleanChatSectionText(String raw) {
    var cleaned = _cleanAssistantText(raw);
    if (cleaned.isEmpty) return '';

    cleaned = cleaned.replaceAll(
      RegExp(r'^CHAT:\s*$', caseSensitive: false, multiLine: true),
      '',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'^SUGERENCIAS:\s*$', caseSensitive: false, multiLine: true),
      '',
    );

    cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    return cleaned;
  }

// Esto queda para el â€œmodo fallbackâ€ (cuando NO hay secciones)
  String _cleanLooseText(String raw) {
    var cleaned = _cleanAssistantText(raw);
    if (cleaned.isEmpty) return '';
    cleaned = _stripSuggestionLines(cleaned);
    cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    return cleaned;
  }

  String? _extractSuggestionFromLine(String line) {
    var t = line.trim();
    if (t.isEmpty) return null;

    // si viene basura/tool_calls/json, fuera
    if (t.contains('{') || t.toLowerCase().contains('tool_calls')) return null;

    // normaliza bullets/emojis
    t = t.replaceAll(RegExp(r'^[â€¢\-\*\d\)\.]+\s*'), '').trim();
    t = t
        .replaceAll('ðŸ‘‰', '')
        .replaceAll('ðŸ’¡', '')
        .replaceAll('âš ï¸', '')
        .replaceAll('âœ…', '')
        .trim();

    // SOLO acepta preguntas con el prefijo exacto
    if (t.startsWith(_suggestionPrefix)) {
      var value = t.substring(_suggestionPrefix.length).trim();
      value = value
          .replaceAll('â€œ', '')
          .replaceAll('â€', '')
          .replaceAll('"', '')
          .trim();
      if (value.isEmpty) return null;
      if (value.length > 240) value = value.substring(0, 240);
      return '$_suggestionPrefix $value';
    }

    return null;
  }

  String _stripSuggestionLines(String raw) {
    final lines = raw.split('\n');
    final kept = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();

      if (trimmed.isEmpty) {
        kept.add('');
        continue;
      }

      // âŒ Nunca dejar pasar preguntas en CHAT
      if (trimmed.startsWith('Pregunta sugerida:')) {
        continue;
      }

      // âœ… Solo lÃ­neas de chat vÃ¡lidas
      for (final p in _chatPrefixes) {
        if (trimmed.startsWith(p)) {
          kept.add(trimmed);
          break;
        }
      }
    }

    return kept.join('\n').trim();
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
      RegExp(
        r'(SUGERENCIAS\s*:)\s*(Pregunta sugerida:)',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)}\n${m.group(2)}',
    );

    t = t.replaceAllMapped(
      RegExp(
        r'(CHAT\s*:)\s*(Respuesta sugerida:|ObjeciÃ³n detectada:|Objecion detectada:|Momento de cierre:)',
        caseSensitive: false,
      ),
      (m) => '${m.group(1)}\n${m.group(2)}',
    );

    return t;
  }

  Map<String, dynamic> _parseAssistantOutput(String raw) {
    var text = _extractResponseText(raw).trim();
    text = _forceSectionNewlines(text);
    if (text.isEmpty) {
      return {'chat': '', 'suggestions': <String>[]};
    }

    final lines = text.split('\n');

    int chatIndex = -1;
    int suggestionIndex = -1;

    final chatLabel = RegExp(r'^CHAT\s*:?\s*$', caseSensitive: false);
    final suggestionsLabel =
        RegExp(r'^SUGERENCIAS\s*:?\s*$', caseSensitive: false);

    for (var i = 0; i < lines.length; i++) {
      final label = lines[i].trim();
      if (chatLabel.hasMatch(label)) chatIndex = i;
      if (suggestionsLabel.hasMatch(label)) suggestionIndex = i;
    }

    // Helpers
    bool _isChatPrefix(String line) {
      final t = line.trimLeft();
      for (final p in _chatPrefixes) {
        if (t.toLowerCase().startsWith(p.toLowerCase())) return true;
      }
      return false;
    }

    bool _isSuggestionPrefix(String line) {
      final t = line.trimLeft();
      return t.toLowerCase().startsWith(_suggestionPrefix.toLowerCase());
    }

    String _stripPrefix(String line, String prefix) {
      final t = line.trim();
      if (t.length <= prefix.length) return '';
      return t.substring(prefix.length).trim();
    }

    // ---- Caso A: No hay secciones CHAT/SUGERENCIAS -> clasifica por prefijos
    if (chatIndex == -1 && suggestionIndex == -1) {
      final chatOut = <String>[];
      final sugOut = <String>[];

      for (final line in lines) {
        final t = line.trim();
        if (t.isEmpty) continue;

        if (_isSuggestionPrefix(t)) {
          final content = _stripPrefix(t, _suggestionPrefix);
          if (content.isNotEmpty) sugOut.add(content);
          continue;
        }

        if (_isChatPrefix(t)) {
          final n = _normalizeChatLine(t);
          if (n.isNotEmpty) chatOut.add(n);
          continue;
        }
      }

      return {
        'chat': chatOut.join('\n').trim(),
        'suggestions': sugOut,
      };
    }

    // ---- Caso B: Hay secciones -> parsea por rangos
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

    // ---- CHAT: solo prefijos vÃ¡lidos
    final chatOut = <String>[];
    for (final line in chatLinesRaw) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (!_isChatPrefix(t)) continue; // <- FILTRO CLAVE
      final n = _normalizeChatLine(t);
      if (n.isNotEmpty) chatOut.add(n);
    }

    // ---- SUGERENCIAS: SOLO "Pregunta sugerida:"
    final sugOut = <String>[];
    for (final line in suggestionLinesRaw) {
      final t = line.trim();
      if (t.isEmpty) continue;
      if (!_isSuggestionPrefix(t)) continue; // <- FILTRO CLAVE
      final content = _stripPrefix(t, _suggestionPrefix);
      if (content.isNotEmpty) sugOut.add(content);
    }

    return {
      'chat': chatOut.join('\n').trim(),
      'suggestions': sugOut,
    };
  }

  // ============================
  // âœ… PROMPT (Opcion A incluida)
  // ============================

  // âœ… E) REEMPLAZA tu _buildChatInstructions por este (obliga 2â€“4 lÃ­neas en CHAT + 3 sugerencias)
  String _buildChatInstructions({String? userPrompt}) {
    final buffer = StringBuffer();

    if (_promptOverride.trim().isNotEmpty) {
      buffer.writeln(_promptOverride.trim());
      buffer.writeln();
    }

    buffer.writeln(
        'INSTRUCCION CRITICA: Todo lo que generes DEBE seguir el prompt anterior.');
    buffer.writeln('Responde en espaÃ±ol.');
    buffer.writeln('Devuelve EXACTAMENTE dos secciones con estos encabezados:');
    buffer.writeln('CHAT:');
    buffer.writeln('- Devuelve de 2 a 4 mensajes cortos, UNO POR LINEA.');
    buffer.writeln(
        '- Cada linea DEBE iniciar exactamente con uno de estos prefijos:');
    buffer.writeln('      Respuesta sugerida: ...');
    buffer.writeln('      ObjeciÃ³n detectada: ...');
    buffer.writeln('      Momento de cierre: ...');
    buffer.writeln(
        '- No uses emojis. No uses JSON. No agregues texto extra fuera de CHAT/SUGERENCIAS.');
    buffer.writeln('SUGERENCIAS:');
    buffer.writeln('- Solo preguntas cortas (maximo 3), una por linea.');
    buffer.writeln('- Cada linea DEBE iniciar con: Pregunta sugerida: ...');
    buffer.writeln('- No incluyas respuestas ni texto extra.');

    if (userPrompt != null && userPrompt.trim().isNotEmpty) {
      buffer.writeln();
      buffer.writeln('Mensaje del usuario:');
      buffer.writeln(userPrompt.trim());
    }

    return buffer.toString();
  }

  String _buildSuggestionsText() {
    final unique = <String>{};
    for (final suggestion in _suggestions) {
      final cleaned = suggestion.trim();
      if (cleaned.isNotEmpty) unique.add(cleaned);
    }

    if (unique.isEmpty) {
      return 'Aun no hay sugerencias.\n\n'
          'Presiona Iniciar y habla (o envia un prompt manual) para que la IA genere sugerencias.';
    }

    return unique.map((line) => '• $line').join('\n');
  }

  List<_TranscriptEntry> _buildTranscriptEntries() {
    final committed = <_TranscriptEntry>[];

    for (final transcript in _transcripts) {
      final t = transcript.trim();
      if (t.isEmpty) continue;

      if (RegExp(r'^(🎤|ðŸŽ¤)\s*').hasMatch(t)) {
        committed.add(_TranscriptEntry(
          text: t.replaceFirst(RegExp(r'^(🎤|ðŸŽ¤)\s*'), '').trim(),
          isMic: true,
        ));
      } else if (RegExp(r'^(🖥️|🖥|ðŸ–¥ï¸|ðŸ–¥)\s*').hasMatch(t)) {
        committed.add(_TranscriptEntry(
          text: t.replaceFirst(RegExp(r'^(🖥️|🖥|ðŸ–¥ï¸|ðŸ–¥)\s*'), '').trim(),
          isMic: false,
        ));
      } else {
        committed.add(_TranscriptEntry(text: t, isMic: false));
      }
    }

    final out = _normalizeTranscriptEntries(committed);

    final currentSys = _currentTranscriptSys.trim();
    if (currentSys.isNotEmpty) {
      out.add(_TranscriptEntry(text: currentSys, isMic: false, pending: true));
    }

    final currentMic = _currentTranscriptMic.trim();
    if (currentMic.isNotEmpty) {
      out.add(_TranscriptEntry(text: currentMic, isMic: true, pending: true));
    }

    return out;
  }

  List<_TranscriptEntry> _normalizeTranscriptEntries(
    List<_TranscriptEntry> entries,
  ) {
    if (entries.length < 2) return List<_TranscriptEntry>.from(entries);
    final ordered = List<_TranscriptEntry>.from(entries);

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

    final merged = <_TranscriptEntry>[];
    for (final entry in ordered) {
      if (merged.isEmpty) {
        merged.add(entry);
        continue;
      }
      final last = merged.last;
      if (!last.pending && !entry.pending && last.isMic == entry.isMic) {
        merged[merged.length - 1] = _TranscriptEntry(
          text: '${last.text.trim()}\n${entry.text.trim()}'.trim(),
          isMic: last.isMic,
        );
      } else {
        merged.add(entry);
      }
    }

    return merged;
  }

  bool _isShortInterjection(String text) {
    final t = text.trim();
    if (t.isEmpty) return true;
    return _wordCount(t) <= 3 || t.length <= 18;
  }

  // ============================
  // âœ… AUDIO
  // ============================

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
    final bytes = _pendingSystemBytes;
    if (bytes < minCommitBytesSystem) return;

    final committed = await _openAIClientSystem?.commitBuffer() ?? false;
    if (committed) {
      _pendingSystemBytes = 0;
    }
  }

  Future<void> _maybeCommitMic() async {
    const minCommitBytesMic = 4600;
    if (_openAIClientMic == null) return;

    final bytes = _pendingMicBytes;
    if (bytes < minCommitBytesMic) return;

    final committed = await _openAIClientMic?.commitBuffer() ?? false;
    if (committed) {
      _pendingMicBytes = 0;
    }
  }

  bool _isLikelyVoiceLine(String line) {
    final t = line.trim();
    if (t.isEmpty) return false;
    if (t.length < 3) return false;
    return RegExp(r'[A-Za-z0-9ÃÃ‰ÃÃ“ÃšÃ¡Ã©Ã­Ã³ÃºÃ‘Ã±]').hasMatch(t);
  }

  int _wordCount(String text) {
    final t = text.trim();
    if (t.isEmpty) return 0;
    return t.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).length;
  }

  bool get _isMicPauseActive {
    final until = _micPauseUntil;
    if (until == null) return false;
    return DateTime.now().isBefore(until);
  }

  void _markMicActivity() {
    _micPauseUntil = DateTime.now().add(_micPauseAfterActivity);
  }

  void _scheduleSilenceAutoStop() {
    _silenceAutoStopTimer?.cancel();
    if (!_listening) return;
    _silenceAutoStopTimer = Timer(_autoStopSilenceTimeout, () {
      if (!mounted || !_listening) return;
      setState(() {
        _statusMessage = 'Silencio por 10s: asesoria detenida automaticamente';
      });
      unawaited(_stopListening());
    });
  }

  OpenAIRealtimeClient? _resolveClientForSource(String source) {
    final normalized = source.toLowerCase().trim() == 'sys' ? 'sys' : 'mic';
    if (normalized == 'sys') return _openAIClientSystem ?? _openAIClientMic;
    return _openAIClientMic ?? _openAIClientSystem;
  }

  void _triggerResponseFromTranscript({
    required String source,
    required String transcriptLine,
  }) {
    if (!_listening) return;
    final normalizedSource =
        source.toLowerCase().trim() == 'sys' ? 'sys' : 'mic';
    if (normalizedSource != 'sys') return;

    final cleanedLine = transcriptLine.trim();
    if (!_isLikelyVoiceLine(cleanedLine)) return;
    if (cleanedLine.length < _minSystemCharsPerTurn) return;
    if (_wordCount(cleanedLine) < _minSystemWordsPerTurn) return;
    final now = DateTime.now();
    final key = cleanedLine.toLowerCase();
    if (key.isEmpty) return;

    // Evita re-disparar por la misma lÃ­nea cerrada varias veces.
    if (_lastVoiceTriggerKey == key &&
        _lastVoiceTriggerAt != null &&
        now.difference(_lastVoiceTriggerAt!) < const Duration(seconds: 12)) {
      return;
    }

    // Solo una respuesta en vuelo.
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
    _queuedTranscriptKey = '';
    _startVoiceTriggeredResponse(
      source: normalizedSource,
      statusMessage: 'Procesando voz detectada',
    );
  }

  void _startVoiceTriggeredResponse({
    required String source,
    String statusMessage = 'Procesando respuesta',
  }) {
    final normalizedSource =
        source.toLowerCase().trim() == 'sys' ? 'sys' : 'mic';
    final client = _resolveClientForSource(normalizedSource);
    if (client == null) return;

    setState(() {
      _micResponseInFlight = true;
      _responseInFlight = true;
      _statusMessage = statusMessage;
      _assistantTurnSeq += 1;
      _activeAssistantTurnId = _assistantTurnSeq;
    });

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
          if (committed) {
            _pendingSystemBytes = 0;
          }
        }
      } else {
        if (_pendingMicBytes > 0) {
          final committed = await _openAIClientMic?.commitBuffer() ?? false;
          if (committed) {
            _pendingMicBytes = 0;
          }
        }
      }

      await client.requestResponse(
        instructions: _buildChatInstructions(),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _micResponseInFlight = false;
        _responseInFlight = false;
        _statusMessage = 'Error solicitando respuesta: $error';
      });
    }
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
      if (sample & 0x8000 != 0) {
        sample = sample - 0x10000;
      }
      sumSquares += sample * sample;
    }

    final rms = math.sqrt(sumSquares / samples);
    final db = 20 * math.log(rms / 32768 + 1e-6) / math.ln10;
    _addLog('Audio RMS dBFS: ${db.toStringAsFixed(1)}');
  }

  Future<void> _setMicMixEnabled(bool enabled) async {
    if (_systemOnlyMode) {
      final shouldEnableMic = _windowsMicAvailable;
      if (_micMixEnabled != shouldEnableMic) {
        setState(() {
          _micMixEnabled = shouldEnableMic;
          _statusMessage = shouldEnableMic
              ? 'Modo fijo: chat por sistema + transcripcion sistema/microfono.'
              : 'Modo fijo: chat por sistema.';
        });
        if (Platform.isWindows && _listening) {
          await _stopWindowsCapture();
          await _startWindowsCapture();
        }
      }
      return;
    }

    if (!_windowsMicAvailable && enabled) {
      setState(() {
        _statusMessage =
            'No hay microfono configurado. Define WINDOWS_MIC_DEVICE en .env.';
      });
      return;
    }
    if (_micMixEnabled == enabled) return;

    setState(() {
      _micMixEnabled = enabled;
    });

    if (Platform.isWindows && _listening) {
      await _stopWindowsCapture();
      await _startWindowsCapture();
    }
  }

  Future<void> _startWindowsCapture() async {
    final systemDevice = windowsAudioDevice.trim();
    if (systemDevice.isEmpty) {
      setState(() {
        _statusMessage =
            'Define WINDOWS_AUDIO_DEVICE en .env (ej. "Stereo Mix (Realtek(R) Audio)")';
        _listening = false;
      });
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
      setState(() {
        _statusMessage =
            'Conectado a OpenAI, pero no se pudo iniciar captura de audio del sistema.';
      });
      return;
    }

    final micDevice = windowsMicDevice.trim();
    final includeMic = _micMixEnabled && micDevice.isNotEmpty;
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

    setState(() {
      _statusMessage = includeMic
          ? 'AsesorIA iniciada: conectada a OpenAI (sistema + microfono). Ya puedes hablar.'
          : 'AsesorIA iniciada: conectada a OpenAI. Ya puedes hablar.';
    });
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

      final process = await Process.start('ffmpeg', args);
      final subscription = process.stdout.listen(
        (chunk) => onChunk(Uint8List.fromList(chunk)),
        onDone: () => _addLog('ffmpeg ($label) stdout cerrado'),
        onError: (error) {
          setState(() {
            _statusMessage = 'Error en ffmpeg ($label): $error';
          });
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
        if (showFfmpegLogs) {
          _addLog('ffmpeg ($label) stderr: $line');
        }
      });
    } catch (error) {
      _addLog('ffmpeg ($label) no se pudo iniciar: $error');
      setState(() {
        _statusMessage =
            'No se pudo iniciar ffmpeg ($label); instala la herramienta y comprueba el dispositivo.';
        _listening = false;
      });
    }
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

  @override
  void dispose() {
    _requestMainAction('barClosed');
    _timer?.cancel();
    _realtimeTimer?.cancel();
    _uiTranscriptIdleTimer?.cancel();
    _queuedResponseDelayTimer?.cancel();
    _silenceAutoStopTimer?.cancel();
    _chatScrollController.dispose();
    _suggestionScrollController.dispose();
    _transcriptScrollController.dispose();
    _manualPromptController.dispose();

    _audioCapture.stop();
    _openAIClientMic?.close();
    _openAIClientSystem?.close();

    if (Platform.isWindows) {
      _audioSubscriptionSystem?.cancel();
      _audioSubscriptionMic?.cancel();
      _audioProcessSystem?.kill();
      _audioProcessMic?.kill();
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    Widget navIconButton(
        IconData icon, String tooltip, VoidCallback? onPressed) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colorScheme.primary.withOpacity(0.2),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          splashRadius: 20,
          padding: EdgeInsets.zero,
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon, size: 20),
          color: colorScheme.onPrimary,
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SizedBox.expand(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: barHeight),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  colorScheme.surfaceVariant.withOpacity(0.55),
                  colorScheme.surface.withOpacity(0.7),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 24,
                  spreadRadius: -10,
                  offset: Offset(0, 10),
                ),
              ],
              border: Border.all(
                color: colorScheme.outlineVariant.withOpacity(0.3),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isCompact = constraints.maxHeight < 275;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Row(
                            children: [
                              navIconButton(
                                Icons.play_arrow_rounded,
                                'Iniciar',
                                _listening ? null : _startListening,
                              ),
                              const SizedBox(width: 8),
                              navIconButton(
                                Icons.stop_rounded,
                                'Detener',
                                _listening ? _stopListening : null,
                              ),
                              const SizedBox(width: 8),
                              navIconButton(
                                Icons.settings_rounded,
                                'Configurar',
                                _openSettings,
                              ),
                            ],
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: DragToMoveArea(
                              child: Container(
                                height: 28,
                                alignment: Alignment.centerLeft,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                child: Text(
                                  'AsesorIA',
                                  style: textTheme.labelSmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              IconButton(
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                                onPressed: () =>
                                    _requestMainAction('barMinimizeRequested'),
                                icon: const Icon(Icons.remove_rounded),
                                tooltip: 'Minimizar',
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                                onPressed: () =>
                                    _requestMainAction('barCloseRequested'),
                                icon: const Icon(Icons.close_rounded),
                                tooltip: 'Cerrar',
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Divider(height: 0),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            _listening
                                ? (_micMixEnabled && _windowsMicAvailable
                                    ? 'Escuchando sistema y microfono'
                                    : (Platform.isWindows
                                        ? 'Escuchando audio del sistema'
                                        : 'Escuchando microfono'))
                                : 'Listo para escuchar',
                            style: textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _listening
                                ? '${_elapsed.inMinutes.toString().padLeft(2, '0')}:${(_elapsed.inSeconds % 60).toString().padLeft(2, '0')}'
                                : 'En espera',
                            style: textTheme.labelMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (!isCompact) ...[
                        const SizedBox(height: 6),
                        SizedBox(
                          height: 30,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              _QuickChip(
                                label: _suggestionsSidebarOpen
                                    ? 'Ocultar sugerencias'
                                    : 'Mostrar sugerencias',
                                icon: Icons.lightbulb_outline_rounded,
                                onTap: _toggleSuggestions,
                              ),
                              _QuickChip(
                                label: _showTranscript
                                    ? 'Volver'
                                    : 'Transcripcion',
                                icon: Icons.mic_rounded,
                                onTap: _toggleTranscript,
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Container(
                        constraints: const BoxConstraints(minHeight: 34),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceVariant.withOpacity(0.35),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: colorScheme.outlineVariant.withOpacity(0.5),
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _manualPromptController,
                                onSubmitted: (_) => _sendManualPrompt(),
                                decoration: InputDecoration(
                                  border: InputBorder.none,
                                  hintText:
                                      'Ask about your screen or conversation, or',
                                  hintStyle: textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                  isDense: true,
                                  contentPadding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                ),
                                style: textTheme.bodyMedium,
                              ),
                            ),
                            GestureDetector(
                              onTap: _sendManualPrompt,
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: colorScheme.primary,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.send_rounded,
                                  size: 14,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Divider(
                        height: 1,
                        color: colorScheme.outlineVariant.withOpacity(0.25),
                      ),
                      const SizedBox(height: 6),
                      Expanded(
                        child: Row(
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
                              width: _suggestionsSidebarOpen ? 330 : 0,
                              child: _suggestionsSidebarOpen
                                  ? _SuggestionsSidebar(
                                      controller: _suggestionScrollController,
                                      suggestions: _suggestions,
                                      onClose: _toggleSuggestions,
                                    )
                                  : const SizedBox.shrink(),
                            ),
                            Expanded(
                              child: _showTranscript
                                  ? _TranscriptionPane(
                                      controller: _transcriptScrollController,
                                      entries: _buildTranscriptEntries(),
                                      emptyText:
                                          'Esperando audio para transcribir',
                                    )
                                  : _ChatPane(
                                      controller: _chatScrollController,
                                      messages: _chatResponses,
                                      emptyText: _statusMessage,
                                      isThinking: _responseInFlight,
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({required this.label, required this.icon, this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final chip = Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceVariant.withOpacity(0.35),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: colorScheme.outlineVariant.withOpacity(0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );

    if (onTap == null) return chip;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: chip,
    );
  }
}

class _TranscriptionPane extends StatelessWidget {
  const _TranscriptionPane({
    required this.controller,
    required this.entries,
    required this.emptyText,
  });

  final ScrollController controller;
  final List<_TranscriptEntry> entries;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (entries.isEmpty) {
      return SingleChildScrollView(
        controller: controller,
        physics: const ClampingScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            emptyText,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface,
                ),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: controller,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final item = entries[index];
        final isMic = item.isMic;
        return Align(
          alignment: isMic ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            constraints: const BoxConstraints(maxWidth: 560),
            decoration: BoxDecoration(
              color: isMic
                  ? colorScheme.primary.withOpacity(0.22)
                  : colorScheme.surfaceVariant.withOpacity(0.4),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(14),
                topRight: const Radius.circular(14),
                bottomLeft:
                    Radius.circular(isMic ? 14 : (item.pending ? 6 : 14)),
                bottomRight:
                    Radius.circular(isMic ? (item.pending ? 6 : 14) : 14),
              ),
              border: Border.all(
                color: colorScheme.outlineVariant.withOpacity(0.35),
              ),
            ),
            child: Text(
              _fixMojibake(item.text),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                    fontStyle: item.pending ? FontStyle.italic : null,
                  ),
            ),
          ),
        );
      },
    );
  }
}

class _SuggestionsSidebar extends StatelessWidget {
  const _SuggestionsSidebar({
    required this.controller,
    required this.suggestions,
    required this.onClose,
  });

  final ScrollController controller;
  final List<String> suggestions;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceVariant.withOpacity(0.25),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: colorScheme.outlineVariant.withOpacity(0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.lightbulb_outline_rounded,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sugerencias',
                  style: textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Cerrar sugerencias',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Divider(
            height: 1,
            color: colorScheme.outlineVariant.withOpacity(0.25),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _SuggestionsListPane(
              controller: controller,
              suggestions: suggestions,
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionsListPane extends StatelessWidget {
  const _SuggestionsListPane({
    required this.controller,
    required this.suggestions,
  });

  final ScrollController controller;
  final List<String> suggestions;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (suggestions.isEmpty) {
      return SingleChildScrollView(
        controller: controller,
        physics: const ClampingScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            _fixMojibake(
              'Aún no hay sugerencias.\nHabla o envía un prompt manual para generar preguntas.',
            ),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface,
                ),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: controller,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.only(top: 2, bottom: 10),
      itemCount: suggestions.length,
      itemBuilder: (context, index) {
        final s = suggestions[index].trim();
        if (s.isEmpty) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: colorScheme.surface.withOpacity(0.18),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: colorScheme.outlineVariant.withOpacity(0.25),
            ),
          ),
          child: Text(
            _fixMojibake('• $s'),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface,
                ),
          ),
        );
      },
    );
  }
}

// =======================
// âœ… Chat: modelos y UI
// =======================

class _TranscriptEntry {
  const _TranscriptEntry({
    required this.text,
    required this.isMic,
    this.pending = false,
  });

  final String text;
  final bool isMic;
  final bool pending;
}

class _ChatMessage {
  _ChatMessage({
    required this.role,
    required this.text,
    this.assistantTurnId,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final String role; // 'assistant' | 'user'
  final String text;
  final int? assistantTurnId;
  final DateTime at;
}

class _ChatPane extends StatelessWidget {
  // Turn-aware chat styling is handled in this widget.
  const _ChatPane({
    required this.controller,
    required this.messages,
    required this.emptyText,
    required this.isThinking,
  });

  final ScrollController controller;
  final List<_ChatMessage> messages;
  final String emptyText;
  final bool isThinking;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final hasAnything = messages.isNotEmpty || isThinking;
    if (!hasAnything) {
      return _TranscriptionPane(
        controller: controller,
        entries: const [],
        emptyText: emptyText,
      );
    }

    final itemCount = messages.length + (isThinking ? 1 : 0);
    final assistantTurnIds = messages
        .where((m) => m.role == 'assistant' && m.assistantTurnId != null)
        .map((m) => m.assistantTurnId!)
        .toSet()
        .toList()
      ..sort();
    final latestAssistantTurnId =
        assistantTurnIds.isNotEmpty ? assistantTurnIds.last : null;
    final previousAssistantTurnId = assistantTurnIds.length > 1
        ? assistantTurnIds[assistantTurnIds.length - 2]
        : null;

    return ListView.builder(
      controller: controller,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        final isThinkingRow = isThinking && index == itemCount - 1;

        final role = isThinkingRow ? 'assistant' : messages[index].role;
        final text = isThinkingRow
            ? 'Asistente estÃ¡ pensando...'
            : messages[index].text.trim();

        final isAssistant = role == 'assistant';
        final currentAssistantTurnId = isThinkingRow
            ? latestAssistantTurnId
            : messages[index].assistantTurnId;

        return Align(
          alignment: isAssistant ? Alignment.centerLeft : Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            constraints: const BoxConstraints(maxWidth: 560),
            decoration: BoxDecoration(
              color: isAssistant
                  ? ((latestAssistantTurnId != null &&
                          currentAssistantTurnId == latestAssistantTurnId)
                      ? colorScheme.primary.withOpacity(0.24)
                      : (previousAssistantTurnId != null &&
                              currentAssistantTurnId ==
                                  previousAssistantTurnId)
                          ? colorScheme.primary.withOpacity(0.14)
                          : colorScheme.surfaceVariant.withOpacity(0.40))
                  : colorScheme.primary.withOpacity(0.22),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: colorScheme.outlineVariant.withOpacity(0.35),
              ),
            ),
            child: Text(
              _fixMojibake(text),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                    fontStyle:
                        isThinkingRow ? FontStyle.italic : FontStyle.normal,
                  ),
            ),
          ),
        );
      },
    );
  }
}

String _fixMojibake(String input) {
  if (input.isEmpty) return input;
  if (!RegExp(r'[ÃÂâð]').hasMatch(input)) return input;

  try {
    final fixed = utf8.decode(latin1.encode(input), allowMalformed: true);
    if (fixed.isNotEmpty) return fixed;
  } catch (_) {}
  return input;
}
