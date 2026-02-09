import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';

import '../core/app_config.dart';
import '../models/conversation.dart';
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

  final ScrollController _chatScrollController = ScrollController();
  final ScrollController _suggestionScrollController = ScrollController();
  final ScrollController _transcriptScrollController = ScrollController();
  final TextEditingController _manualPromptController = TextEditingController();

  final FlutterAudioCapture _audioCapture = FlutterAudioCapture();
  OpenAIRealtimeClient? _openAIClient;

  // ✅ Chat ahora es lista de mensajes (user/assistant)
  final List<_ChatMessage> _chatResponses = [];

  final List<String> _suggestions = [];
  String _currentResponse = '';

  // ✅ Transcripción separada (no debe contaminar Chat/Sugerencias)
  final List<String> _transcripts = [];
  String _currentTranscript = '';

  String _statusMessage = '';
  Process? _audioProcess;
  StreamSubscription<List<int>>? _audioSubscription;
  int _pendingAudioBytes = 0;

  bool _responseInFlight = false;
  bool _finalResponseQueued = false;
  int? _streamingAssistantIndex;
  String _streamingAssistantText = '';
  bool _assistantStreamStarted = false;
  DateTime? _lastLevelLogAt;
  String _promptOverride = '';
  bool _micMixEnabled = false;
  bool _showSuggestions = false;
  bool _suggestionsSidebarOpen = true;
  DateTime? _sessionStartedAt;
  DateTime? _sessionEndedAt;
  bool _conversationSaved = false;

  bool _showTranscript = false;
  bool _isRealBarWindow() {
    // La barra solo existe cuando fue creada con type=bar
    // Settings nunca debería ejecutar esto
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

  Future<void> _loadPromptFromFile() async {
    if (!await promptFile.exists()) return;
    final content = (await promptFile.readAsString()).trim();
    if (content.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _promptOverride = content;
    });
    _addLog('Prompt cargado desde ${promptFile.path}');
  }

  @override
  void initState() {
    super.initState();

    _promptOverride = systemPrompt;
    _micMixEnabled = _windowsMicAvailable;
    _loadPromptFromFile();

    // ✅ Esto siempre debe ejecutarse SOLO en la ventana BAR
    _notifyBarOpened();

    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      if (call.method == 'updatePrompt') {
        final args = call.arguments as Map?;
        final prompt = args?['prompt'] as String? ?? '';
        setState(() {
          _promptOverride = prompt.isEmpty ? systemPrompt : prompt;
        });
        _openAIClient?.updateSessionInstructions(_promptOverride);
      }

      if (call.method == 'setMicMix') {
        final args = call.arguments as Map?;
        final enabled = args?['enabled'] as bool? ?? false;
        await _setMicMixEnabled(enabled);
      }

      return null;
    });
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
    await _loadPromptFromFile();
    if (openAIKey.isEmpty) {
      setState(() {
        _statusMessage =
            'Define OPENAI_API_KEY con `--dart-define=OPENAI_API_KEY=sk-...` para habilitar la IA.';
      });
      return;
    }

    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _elapsed = Duration(seconds: timer.tick);
      });
    });

    _sessionStartedAt = DateTime.now();
    _sessionEndedAt = null;
    _conversationSaved = false;

    _pendingAudioBytes = 0;
    _responseInFlight = false;
    _finalResponseQueued = false;

    _chatResponses.clear();
    _suggestions.clear();
    _currentResponse = '';
    _transcripts.clear();
    _currentTranscript = '';

    _statusMessage = 'Conectando con OpenAI';

    _addLog('Iniciando sesion con OpenAI');
    final promptPreview = _promptOverride.length > 120
        ? '${_promptOverride.substring(0, 120)}...'
        : _promptOverride;
    _addLog('Prompt activo: $promptPreview');

    _openAIClient = OpenAIRealtimeClient(
      openAIKey: openAIKey,
      model: openAIRealtimeModel,
      vadSilenceMs: vadSilenceMs,
      sessionInstructions: _promptOverride,
      onDelta: _appendResponseDelta,
      onTranscriptDelta: _appendTranscriptDelta,
      onComplete: _handleResponseComplete,
      showEvents: showOpenAIEvents,
    );

    await _openAIClient?.connect();

    setState(() {
      _listening = true;
    });

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
      (_) => _flushRealtimeResponse(),
    );
  }

  Future<void> _sendManualPrompt() async {
    await _loadPromptFromFile();
    final prompt = _manualPromptController.text.trim();
    if (prompt.isEmpty) return;

    if (openAIKey.isEmpty) {
      setState(() {
        _statusMessage =
            'Define OPENAI_API_KEY con `--dart-define=OPENAI_API_KEY=sk-...` para habilitar la IA.';
      });
      return;
    }

    // ✅ Muestra el mensaje del usuario como burbuja.
    setState(() {
      _chatResponses.add(_ChatMessage(role: 'user', text: prompt));
    });
    _scrollToBottom(_chatScrollController);

    if (_openAIClient == null) {
      _openAIClient = OpenAIRealtimeClient(
        openAIKey: openAIKey,
        model: openAIRealtimeModel,
        vadSilenceMs: vadSilenceMs,
        sessionInstructions: _promptOverride,
        onDelta: _appendResponseDelta,
        onTranscriptDelta: _appendTranscriptDelta,
        onComplete: _handleResponseComplete,
        showEvents: showOpenAIEvents,
      );
      await _openAIClient?.connect();
    }

    _sessionStartedAt ??= DateTime.now();
    _sessionEndedAt = DateTime.now();
    _conversationSaved = false;

    setState(() {
      _statusMessage = 'Enviando prompt manual';
      _responseInFlight = true;
    });

    _manualPromptController.clear();

    await _openAIClient?.requestResponse(
      instructions: _buildChatInstructions(userPrompt: prompt),
    );
  }

  Future<void> _stopListening() async {
    if (!_listening) return;

    _timer?.cancel();
    _realtimeTimer?.cancel();
    _realtimeTimer = null;

    _sessionEndedAt = DateTime.now();

    if (Platform.isWindows) {
      await _stopWindowsCapture();
    } else if (_audioSupported) {
      _addLog('Deteniendo flutter_audio_capture');
      await _audioCapture.stop();
    }

    // ✅ si queda audio pendiente, forzar commit+respuesta
    if (_pendingAudioBytes > 0) {
      await _openAIClient?.commitBuffer();
      _pendingAudioBytes = 0;

      if (_responseInFlight) {
        _finalResponseQueued = true;
      } else {
        setState(() => _responseInFlight = true);
        await _openAIClient?.requestResponse(
          instructions: _buildChatInstructions(),
        );
      }
    }

    setState(() {
      _listening = false;
      _elapsed = Duration.zero;
      _statusMessage = 'Procesando respuesta';
    });
  }

  Future<void> _openSettings() async {
    await _loadPromptFromFile();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final screenWidth = view.physicalSize.width / view.devicePixelRatio;
    final screenHeight = view.physicalSize.height / view.devicePixelRatio;
    final window = await DesktopMultiWindow.createWindow(jsonEncode({
      'type': 'settings',
      'mainWindowId': 0,
      'prompt': _promptOverride,
    }));
    window
      ..setFrame(Rect.fromLTWH(0, 0, screenWidth, screenHeight))
      ..setTitle('Configuracion')
      ..show();
  }

  void _openMicPrivacySettings() {
    _addLog('Abriendo configuracion de micrófono en Windows');
    Process.start('cmd', ['/c', 'start', 'ms-settings:privacy-microphone']);
  }

  // ============================
  // ✅ STREAMING
  // ============================

  void _appendResponseDelta(String delta) {
  if (delta.isEmpty) return;

  setState(() {
    _currentResponse += delta;
    _statusMessage = 'Respuesta en pantalla';

    // Crea burbuja "en vivo"
    if (!_assistantStreamStarted) {
      _assistantStreamStarted = true;
      _chatResponses.add(_ChatMessage(role: 'assistant', text: ''));
      _streamingAssistantIndex = _chatResponses.length - 1;
    }

    // ✅ Pintar SOLO chat válido (no preguntas sugeridas)
    _streamingAssistantText = _buildStreamingChatPreview(_currentResponse);

    final idx = _streamingAssistantIndex;
    if (idx != null && idx >= 0 && idx < _chatResponses.length) {
      // Si todavía no hay nada “chat válido”, no muestres basura
      final visible = _streamingAssistantText.trim();
      _chatResponses[idx] =
          _ChatMessage(role: 'assistant', text: visible.isEmpty ? '...' : visible);
    }
  });

  _scrollToBottom(_chatScrollController);
}


  String _buildStreamingChatPreview(String raw) {
  if (raw.trim().isEmpty) return '';

  final text = _extractResponseText(raw);

  // 1) Normaliza saltos de línea y corta por líneas
  final lines = text.split('\n');

  // 2) Quedate solo con líneas que sean “CHAT prefix”
  final kept = <String>[];
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty) continue;

    // Nunca mostrar preguntas sugeridas en el chat en vivo
    if (t.toLowerCase().startsWith(_suggestionPrefix.toLowerCase())) continue;

    final n = _normalizeChatLine(t); // devuelve '' si no es prefijo válido
    if (n.isNotEmpty) kept.add(n);
  }

  // 3) Dedup simple manteniendo orden
  final seen = <String>{};
  final out = <String>[];
  for (final l in kept) {
    if (seen.add(l)) out.add(l);
  }

  // 4) Mostramos máximo 4 líneas (tu regla)
  if (out.length > 4) {
    return out.take(4).join('\n');
  }
  return out.join('\n');
}


  void _appendTranscriptDelta(String text) {
    if (text.isEmpty) return;

    setState(() {
      _currentTranscript += text;

      // cortamos por saltos de línea (cuando el engine los mande)
      while (_currentTranscript.contains('\n')) {
        final idx = _currentTranscript.indexOf('\n');
        final chunk = _currentTranscript.substring(0, idx).trim();

        final cleaned = _cleanTranscriptChunk(chunk);
        if (cleaned != null) {
          if (_transcripts.isEmpty || _transcripts.last != cleaned) {
            _transcripts.add(cleaned);
          }
        }

        _currentTranscript = _currentTranscript.substring(idx + 1);
      }
    });

    _scrollToBottom(_transcriptScrollController);
  }

  List<String> _splitChatIntoBubbles(String chatBlock) {
    final out = <String>[];
    for (final line in chatBlock.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final cleaned = t.replaceFirst(RegExp(r'^[-•]\s*'), '').trim();
      if (cleaned.isNotEmpty) out.add(cleaned);
    }
    return out;
  }

  void _pushAssistantBubble(String text) {
    final t = text.trim();
    if (t.isEmpty) return;

    // ✅ anti-duplicado consecutivo
    if (_chatResponses.isNotEmpty &&
        _chatResponses.last.role == 'assistant' &&
        _chatResponses.last.text.trim() == t) {
      return;
    }

    _chatResponses.add(_ChatMessage(role: 'assistant', text: t));
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

    setState(() {
      final idx = _streamingAssistantIndex;

      // Si NO pudimos parsear chatLines, NO borres la burbuja streaming:
      // úsala como mensaje final (para que no “desaparezca”)
      if (finalLines.isEmpty) {
        if (idx != null && idx >= 0 && idx < _chatResponses.length) {
          final fallback = _streamingAssistantText.trim();
          if (fallback.isNotEmpty) {
            _chatResponses[idx] =
                _ChatMessage(role: 'assistant', text: fallback);
          }
        }
      } else {
        // Si SÍ hay chatLines, reemplaza la burbuja streaming por líneas finales
        if (idx != null && idx >= 0 && idx < _chatResponses.length) {
          _chatResponses.removeAt(idx);
        }
        for (final line in finalLines) {
          if (_chatResponses.isNotEmpty &&
              _chatResponses.last.role == 'assistant' &&
              _chatResponses.last.text.trim() == line) {
            continue;
          }
          _chatResponses.add(_ChatMessage(role: 'assistant', text: line));
        }
      }

      _streamingAssistantIndex = null;
      _streamingAssistantText = '';
      _assistantStreamStarted = false;
    });

    // Limpia acumuladores del turno
    _currentResponse = '';

    // ====== TRANSCRIPT final ======
    final transcript = _currentTranscript.trim();
    final cleanedFinal = _cleanTranscriptChunk(transcript);
    if (cleanedFinal != null) {
      setState(() {
        if (_transcripts.isEmpty || _transcripts.last != cleanedFinal) {
          _transcripts.add(cleanedFinal);
        }
      });
    }
    _currentTranscript = '';

    _scrollToBottom(_chatScrollController);
    _scrollToBottom(_suggestionScrollController);

    setState(() {
      _responseInFlight = false;
    });

    if (!_listening && _finalResponseQueued) {
      _finalResponseQueued = false;
      setState(() => _responseInFlight = true);
      _openAIClient?.requestResponse(instructions: _buildChatInstructions());
      return;
    }

    if (!_listening) {
      _openAIClient?.close();
      _openAIClient = null;
      _maybeSaveConversation();
    }
  }

  // ============================
  // ✅ SAVE CONVERSATION
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
    if (trimmed.isEmpty) return 'Conversación';
    final words = trimmed.split(RegExp(r'\s+'));
    final titleWords = words.take(6).join(' ');
    return titleWords.length > 42
        ? '${titleWords.substring(0, 42)}…'
        : titleWords;
  }
  // ============================
// ✅ NORMALIZADORES (anti-duplicados / limpieza)
// ============================

  static const List<String> _chatPrefixes = [
    'Respuesta sugerida:',
    'Objeción detectada:',
    'Objecion detectada:', // por si el modelo no pone tilde
    'Momento de cierre:',
  ];

  static const String _suggestionPrefix = 'Pregunta sugerida:';

  String _normalizeChatLine(String line) {
    var t = line.trim();
    if (t.isEmpty) return '';

    // Si viene cola pegada de sugerencias, cortarla para no contaminar CHAT.
    t = t.replaceAll(
      RegExp(r'\s*SUGERENCIAS\s*:.*$', caseSensitive: false),
      '',
    ).trim();
    if (t.isEmpty) return '';

    // Solo permitimos líneas que empiecen con prefijos de CHAT
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
    t = t.replaceAll('👉', '').replaceAll('💡', '').trim();

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

    // Normalización ligera para comparar (sin destruir el original)
    String norm(String x) =>
        x.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

    // Si el texto es literalmente "A A" separado por espacio / puntuación
    // intentamos encontrar el mejor corte posible.
    final tokens = s.split(RegExp(r'\s+'));
    if (tokens.length < 2) return s;

    // Probamos varios tamaños de bloque (desde 1 token hasta la mitad)
    final maxBlock = (tokens.length / 2).floor();
    final normTokens = tokens.map(norm).toList();

    for (int block = 1; block <= maxBlock; block++) {
      // Compara bloque inicial vs bloque siguiente del mismo tamaño
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

    // Basura típica que se cuela en transcript
    final looksLikeContext = lower == '###' ||
        lower.startsWith('context:') ||
        lower.startsWith('###context') ||
        lower == 'context';

    final looksLikeInstruction =
        lower.contains('transcribe únicamente en español') ||
            lower.contains('transcribe unicamente en espanol');

    if (looksLikeContext || looksLikeInstruction) return null;

    // Colapsa repetición inmediata de frases: "Gracias. Gracias."
    t = t.replaceAllMapped(
      RegExp(r'(\b\w+[.!?])\1+'),
      (m) => m.group(1)!,
    );
    // Colapsa repetición inmediata (tu helper)
    t = _collapseImmediateRepeat(t);

    // Normaliza espacios
    t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();

    return t.isEmpty ? null : t;
  }

  // ============================
  // ✅ PARSE OUTPUT
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

// Esto queda para el “modo fallback” (cuando NO hay secciones)
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
    t = t.replaceAll(RegExp(r'^[•\-\*\d\)\.]+\s*'), '').trim();
    t = t
        .replaceAll('👉', '')
        .replaceAll('💡', '')
        .replaceAll('⚠️', '')
        .replaceAll('✅', '')
        .trim();

    // SOLO acepta preguntas con el prefijo exacto
    if (t.startsWith(_suggestionPrefix)) {
      var value = t.substring(_suggestionPrefix.length).trim();
      value = value
          .replaceAll('“', '')
          .replaceAll('”', '')
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

      // ❌ Nunca dejar pasar preguntas en CHAT
      if (trimmed.startsWith('Pregunta sugerida:')) {
        continue;
      }

      // ✅ Solo líneas de chat válidas
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
        r'(CHAT\s*:)\s*(Respuesta sugerida:|Objeción detectada:|Objecion detectada:|Momento de cierre:)',
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

    // ---- CHAT: solo prefijos válidos
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
  // ✅ PROMPT (Opcion A incluida)
  // ============================

  // ✅ E) REEMPLAZA tu _buildChatInstructions por este (obliga 2–4 líneas en CHAT + 3 sugerencias)
  String _buildChatInstructions({String? userPrompt}) {
    final buffer = StringBuffer();

    if (_promptOverride.trim().isNotEmpty) {
      buffer.writeln(_promptOverride.trim());
      buffer.writeln();
    }

    buffer.writeln(
        'INSTRUCCION CRITICA: Todo lo que generes DEBE seguir el prompt anterior.');
    buffer.writeln('Responde en español.');
    buffer.writeln('Devuelve EXACTAMENTE dos secciones con estos encabezados:');
    buffer.writeln('CHAT:');
    buffer.writeln('- Devuelve de 2 a 4 mensajes cortos, UNO POR LINEA.');
    buffer.writeln(
        '- Cada linea DEBE iniciar exactamente con uno de estos prefijos:');
    buffer.writeln('      Respuesta sugerida: ...');
    buffer.writeln('      Objeción detectada: ...');
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

  String _buildTranscriptText() {
    final parts = <String>[];

    for (final transcript in _transcripts) {
      final t = transcript.trim();
      if (t.isNotEmpty) parts.add('• $t');
    }

    final current = _currentTranscript.trim();
    if (current.isNotEmpty) parts.add('• $current');

    return parts.isEmpty ? '' : parts.join('\n\n');
  }

  // ============================
  // ✅ AUDIO
  // ============================

  void _appendAudio(Uint8List bytes) {
    _pendingAudioBytes += bytes.length;
    _openAIClient?.appendAudio(bytes);
    _logAudioLevel(bytes);
  }

  Future<void> _flushRealtimeResponse() async {
    if (!_listening || _openAIClient == null) return;
    if (_responseInFlight || _pendingAudioBytes == 0) return;

    setState(() => _responseInFlight = true);

    _pendingAudioBytes = 0;
    await _openAIClient?.commitBuffer();
    await _openAIClient?.requestResponse(
        instructions: _buildChatInstructions());
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
    if (windowsAudioDevice.isEmpty) {
      setState(() {
        _statusMessage =
            'Define WINDOWS_AUDIO_DEVICE en .env (ej. "Stereo Mix (Realtek(R) Audio)")';
        _listening = false;
      });
      return;
    }

    try {
      _addLog('Dispositivo de captura: $windowsAudioDevice');
      if (windowsAudioSampleRate.isNotEmpty) {
        _addLog('Sample rate de captura: $windowsAudioSampleRate');
      }

      final args = <String>[];

      String buildInputDevice(String device) {
        if (windowsAudioBackend == 'wasapi' &&
            device.toLowerCase() == 'default') {
          return 'default';
        }
        return 'audio=$device';
      }

      void addInput(String device, {bool loopback = false}) {
        args.addAll(['-f', windowsAudioBackend]);
        if (windowsAudioSampleRate.isNotEmpty) {
          args.addAll(['-sample_rate', windowsAudioSampleRate]);
        }
        if (windowsAudioBackend == 'wasapi' && loopback) {
          _addLog('Captura loopback habilitada (audio de salida)');
          args.addAll(['-loopback', '1']);
        }
        args.addAll(['-i', buildInputDevice(device)]);
      }

      addInput(
        windowsAudioDevice,
        loopback: windowsAudioBackend == 'wasapi' && windowsAudioLoopback,
      );

      final includeMic = _micMixEnabled && windowsMicDevice.trim().isNotEmpty;
      if (includeMic) {
        _addLog('Microfono adicional: $windowsMicDevice');
        addInput(windowsMicDevice);
      }

      if (includeMic) {
        args.addAll([
          '-filter_complex',
          'amix=inputs=2:duration=longest:dropout_transition=2',
          '-ac',
          '1',
          '-ar',
          '16000',
          '-f',
          's16le',
          '-',
        ]);
      } else {
        args.addAll([
          '-ac',
          '1',
          '-ar',
          '16000',
          '-f',
          's16le',
          '-',
        ]);
      }

      _audioProcess = await Process.start('ffmpeg', args);
      _addLog('ffmpeg arrancado con $windowsAudioDevice');
    } catch (error) {
      _addLog('ffmpeg no se pudo iniciar: $error');
      setState(() {
        _statusMessage =
            'No se pudo iniciar ffmpeg; instala la herramienta y comprueba el dispositivo.';
        _listening = false;
      });
      return;
    }

    _audioSubscription = _audioProcess?.stdout.listen(
      (chunk) {
        _appendAudio(Uint8List.fromList(chunk));
      },
      onDone: () => _addLog('ffmpeg stdout cerrado'),
      onError: (error) {
        setState(() {
          _statusMessage = 'Error en ffmpeg: $error';
        });
      },
    );

    _audioProcess?.exitCode.then((code) {
      _addLog('ffmpeg finalizo con codigo $code');
    });

    final stderrStream = _audioProcess?.stderr;
    if (stderrStream != null) {
      stderrStream.transform(const Utf8Decoder()).listen((line) {
        if (showFfmpegLogs) {
          _addLog('ffmpeg stderr: $line');
        }
      });
    }
  }

  Future<void> _stopWindowsCapture() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;

    if (_audioProcess != null) {
      _audioProcess!.kill();
      await _audioProcess!.exitCode;
      _audioProcess = null;
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
    _chatScrollController.dispose();
    _suggestionScrollController.dispose();
    _transcriptScrollController.dispose();
    _manualPromptController.dispose();

    _audioCapture.stop();
    _openAIClient?.close();

    if (Platform.isWindows) {
      _audioSubscription?.cancel();
      _audioProcess?.kill();
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
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                                      text: (_transcripts.isNotEmpty ||
                                              _currentTranscript.isNotEmpty)
                                          ? _buildTranscriptText()
                                          : 'Esperando audio para transcribir',
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
    required this.text,
  });

  final ScrollController controller;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      controller: controller,
      physics: const ClampingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface,
              ),
        ),
      ),
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
            'Aún no hay sugerencias.\nHabla o envía un prompt manual para generar preguntas.',
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
            '• $s',
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
// ✅ Chat: modelos y UI
// =======================

class _ChatMessage {
  _ChatMessage({required this.role, required this.text, DateTime? at})
      : at = at ?? DateTime.now();

  final String role; // 'assistant' | 'user'
  final String text;
  final DateTime at;
}

class _ChatPane extends StatelessWidget {
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
      return _TranscriptionPane(controller: controller, text: emptyText);
    }

    final itemCount = messages.length + (isThinking ? 1 : 0);

    return ListView.builder(
      controller: controller,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        final isThinkingRow = isThinking && index == itemCount - 1;

        final role = isThinkingRow ? 'assistant' : messages[index].role;
        final text = isThinkingRow
            ? 'Asistente está pensando...'
            : messages[index].text.trim();

        final isAssistant = role == 'assistant';

        return Align(
          alignment: isAssistant ? Alignment.centerLeft : Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            constraints: const BoxConstraints(maxWidth: 560),
            decoration: BoxDecoration(
              color: isAssistant
                  ? colorScheme.surfaceVariant.withOpacity(0.40)
                  : colorScheme.primary.withOpacity(0.22),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: colorScheme.outlineVariant.withOpacity(0.35),
              ),
            ),
            child: Text(
              text,
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
