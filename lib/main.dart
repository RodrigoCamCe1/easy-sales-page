import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as Math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path/path.dart' as p;
import 'package:web_socket_channel/io.dart';
import 'package:window_manager/window_manager.dart';

const double _barHeight = 220.0;
const String _dartDefineOpenAIKey = String.fromEnvironment('OPENAI_API_KEY');
const String _defaultOpenAIRealtimeModel = 'gpt-4o-realtime-preview';
const bool _showFfmpegLogs = true;
const bool _showOpenAIEvents = false;
const String _promptFileName = 'prompt.txt';
const int _defaultVadSilenceMs = 1000;
const int _defaultRealtimeFlushSeconds = 6;
String get _openAIKey {
  if (_dartDefineOpenAIKey.isNotEmpty) {
    return _dartDefineOpenAIKey;
  }
  if (dotenv.isInitialized) {
    return dotenv.env['OPENAI_API_KEY'] ?? '';
  }
  return '';
}

String get _openAIRealtimeModel =>
    dotenv.env['OPENAI_REALTIME_MODEL'] ?? _defaultOpenAIRealtimeModel;

String get _systemPrompt =>
    dotenv.env['SYSTEM_PROMPT'] ??
    'Eres un agente de IA que responde de forma clara y breve.';

String get _windowsAudioDevice =>
    dotenv.env['WINDOWS_AUDIO_DEVICE'] ?? 'Stereo Mix (Realtek(R) Audio)';
String get _windowsMicDevice => dotenv.env['WINDOWS_MIC_DEVICE'] ?? '';
String get _windowsAudioBackend =>
    dotenv.env['WINDOWS_AUDIO_BACKEND'] ?? 'dshow';
String get _windowsAudioSampleRate =>
    dotenv.env['WINDOWS_AUDIO_SAMPLE_RATE'] ?? '';
bool get _windowsAudioLoopback =>
    (dotenv.env['WINDOWS_AUDIO_LOOPBACK'] ?? '').toLowerCase() == 'true';

String get _promptFilePath => p.join(Directory.current.path, _promptFileName);
File get _promptFile => File(_promptFilePath);

int _readIntEnv(String key, int fallback) {
  final raw = dotenv.env[key];
  if (raw == null || raw.trim().isEmpty) return fallback;
  final parsed = int.tryParse(raw.trim());
  return parsed ?? fallback;
}

int get _vadSilenceMs =>
    _readIntEnv('OPENAI_VAD_SILENCE_MS', _defaultVadSilenceMs);
int get _realtimeFlushSeconds => _readIntEnv(
      'OPENAI_REALTIME_FLUSH_SECONDS',
      _defaultRealtimeFlushSeconds,
    );

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');

  if (args.isNotEmpty) {
    final windowId = int.tryParse(args[0]) ?? 0;
    Map<String, dynamic> arguments = {};
    if (args.length > 1) {
      try {
        final decoded = jsonDecode(args[1]);
        if (decoded is Map<String, dynamic>) {
          arguments = decoded;
        }
      } catch (_) {
        arguments = {};
      }
    }
    runApp(SettingsWindowApp(
      windowId: windowId,
      mainWindowId: arguments['mainWindowId'] as int? ?? 0,
      initialPrompt: arguments['prompt'] as String? ?? _systemPrompt,
    ));
    return;
  }

  await windowManager.ensureInitialized();

  final flutterView = WidgetsBinding.instance.platformDispatcher.views.first;
  final screenWidth =
      flutterView.physicalSize.width / flutterView.devicePixelRatio;
  final windowOptions = WindowOptions(
    size: Size(screenWidth, _barHeight),
    minimumSize: Size(screenWidth, _barHeight),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setResizable(false);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setBounds(Rect.fromLTWH(0, 0, screenWidth, _barHeight));
    await windowManager.setPosition(const Offset(0, 0));
  });

  runApp(const EasySalesBarApp());
}

class EasySalesBarApp extends StatelessWidget {
  const EasySalesBarApp({super.key});

  @override
  Widget build(BuildContext context) {
    const brightness = Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: brightness,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'EasySales Audio Bar',
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

class SettingsWindowApp extends StatelessWidget {
  const SettingsWindowApp({
    super.key,
    required this.windowId,
    required this.mainWindowId,
    required this.initialPrompt,
  });

  final int windowId;
  final int mainWindowId;
  final String initialPrompt;

  @override
  Widget build(BuildContext context) {
    const brightness = Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: brightness,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Configuracion',
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        brightness: brightness,
      ),
      home: SettingsWindowPage(
        windowId: windowId,
        mainWindowId: mainWindowId,
        initialPrompt: initialPrompt,
      ),
    );
  }
}

class SettingsWindowPage extends StatefulWidget {
  const SettingsWindowPage({
    super.key,
    required this.windowId,
    required this.mainWindowId,
    required this.initialPrompt,
  });

  final int windowId;
  final int mainWindowId;
  final String initialPrompt;

  @override
  State<SettingsWindowPage> createState() => _SettingsWindowPageState();
}

class _SettingsWindowPageState extends State<SettingsWindowPage> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialPrompt);
    _loadPromptFromFile();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _savePrompt() async {
    final prompt = _controller.text.trim();
    if (prompt.isNotEmpty) {
      await _promptFile.writeAsString(prompt);
    }
    final targetIds = <int>{
      widget.mainWindowId,
      0,
      1,
    };
    for (final id in targetIds) {
      if (id == widget.windowId) continue;
      try {
        await DesktopMultiWindow.invokeMethod(
          id,
          'updatePrompt',
          {'prompt': prompt},
        );
      } catch (_) {
        // Best-effort broadcast to the main window.
      }
    }
  }

  void _openMicPrivacySettings() {
    if (!Platform.isWindows) return;
    Process.start('cmd', ['/c', 'start', 'ms-settings:privacy-microphone']);
  }

  Future<void> _loadPromptFromFile() async {
    if (!await _promptFile.exists()) return;
    final content = (await _promptFile.readAsString()).trim();
    if (content.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _controller.text = content;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuracion'),
        actions: [
          TextButton(
            onPressed: _savePrompt,
            child: const Text('Guardar'),
          ),
          if (Platform.isWindows)
            TextButton(
              onPressed: _openMicPrivacySettings,
              child: const Text('Mic Windows'),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Aqui puedes seleccionar la fuente de audio (por ejemplo, un dispositivo loopback) '
              'y la carpeta de salida. La captura de audio del sistema requiere integrar un '
              'plugin nativo o usar un dispositivo virtual como VB-Audio/BlackHole. '
              'En Windows puedes definir WINDOWS_MIC_DEVICE para mezclar microfono.',
            ),
            const SizedBox(height: 12),
            const Text('Prompt del sistema'),
            const SizedBox(height: 6),
            Expanded(
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Escribe el prompt para la IA...',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class OpenAIRealtimeClient {
  OpenAIRealtimeClient({
    required this.openAIKey,
    required this.onDelta,
    this.onComplete,
  });

  final String openAIKey;
  final void Function(String) onDelta;
  final VoidCallback? onComplete;

  IOWebSocketChannel? _channel;

  Future<void> connect() async {
    final uri = Uri.parse(
        'wss://api.openai.com/v1/realtime?model=$_openAIRealtimeModel');
    final socket = await WebSocket.connect(
      uri.toString(),
      headers: {
        'Authorization': 'Bearer $openAIKey',
        'OpenAI-Beta': 'realtime=v1',
      },
    );
    _channel = IOWebSocketChannel(socket);
    _updateSession();
    _channel?.stream.listen(
      _handleMessage,
      onDone: () {
        debugPrint('OpenAI WS closed');
        onComplete?.call();
      },
      onError: (error) => debugPrint('OpenAI WS error: $error'),
    );
  }

  void _updateSession() {
    _channel?.sink.add(jsonEncode({
      'type': 'session.update',
      'session': {
        'turn_detection': {
          'type': 'server_vad',
          'silence_duration_ms': _vadSilenceMs,
        },
      },
    }));
  }

  void appendAudio(Uint8List audioChunk) {
    final encoded = base64Encode(audioChunk);
    debugPrint('OpenAI appendAudio ${audioChunk.length} bytes');
    _channel?.sink.add(
      jsonEncode({
        'type': 'input_audio_buffer.append',
        'audio': encoded,
      }),
    );
  }

  Future<void> commitBuffer() async {
    debugPrint('OpenAI commitBuffer');
    _channel?.sink.add(jsonEncode({'type': 'input_audio_buffer.commit'}));
  }

  Future<void> requestResponse({required String instructions}) async {
    debugPrint('OpenAI requestResponse');
    _channel?.sink.add(jsonEncode({
      'type': 'response.create',
      'response': {
        'modalities': ['text'],
        'instructions': instructions,
      },
    }));
  }

  Future<void> close() async {
    await _channel?.sink.close();
    _channel = null;
  }

  void _handleMessage(dynamic event) {
    if (_showOpenAIEvents) {
      debugPrint('OpenAI evento raw: $event');
    }
    if (event is! String) return;
    final payload = jsonDecode(event);
    final type = payload['type'] as String?;
    if (type == null) return;

    if (type == 'response.delta' || type == 'response.stream') {
      final delta = payload['delta'] ?? payload['response']?['delta'];
      final content = delta is Map ? delta['content'] : null;
      if (content is String && content.isNotEmpty) {
        onDelta(content);
      }
      return;
    }
    if (type == 'response.text.delta') {
      final delta = payload['delta'];
      if (delta is String && delta.isNotEmpty) {
        onDelta(delta);
      }
      return;
    }
    if (type == 'response.output_text.delta') {
      final delta = payload['delta'];
      if (delta is String && delta.isNotEmpty) {
        onDelta(delta);
      }
      return;
    }
    if (type == 'response.audio_transcript.delta') {
      final delta = payload['delta'];
      if (delta is String && delta.isNotEmpty) {
        onDelta(delta);
      }
      return;
    }

    if (type == 'response.completed' ||
        type == 'response.text.done' ||
        type == 'response.cancelled' ||
        type == 'response.done' ||
        type == 'response.output_text.done') {
      onComplete?.call();
    }
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
  final ScrollController _scrollController = ScrollController();
  final FlutterAudioCapture _audioCapture = FlutterAudioCapture();
  OpenAIRealtimeClient? _openAIClient;
  final List<String> _responses = [];
  String _currentResponse = '';
  String _statusMessage = '';
  Process? _audioProcess;
  StreamSubscription<List<int>>? _audioSubscription;
  int _pendingAudioBytes = 0;
  bool _responseInFlight = false;
  bool _finalResponseQueued = false;
  DateTime? _lastLevelLogAt;
  String _promptOverride = '';
  bool _micMixEnabled = false;

  bool get _audioSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isLinux;
  bool get _windowsMicAvailable =>
      Platform.isWindows && _windowsMicDevice.trim().isNotEmpty;

  void _addLog(String entry) {
    final timestamp = DateTime.now().toIso8601String();
    debugPrint('[$timestamp] $entry');
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _loadPromptFromFile() async {
    if (!await _promptFile.exists()) return;
    final content = (await _promptFile.readAsString()).trim();
    if (content.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _promptOverride = content;
    });
    _addLog('Prompt cargado desde ${_promptFile.path}');
  }

  @override
  void initState() {
    super.initState();
    _promptOverride = _systemPrompt;
    _micMixEnabled = _windowsMicAvailable;
    _loadPromptFromFile();
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      if (call.method == 'updatePrompt') {
        final args = call.arguments as Map?;
        final prompt = args?['prompt'] as String? ?? '';
        setState(() {
          _promptOverride = prompt.isEmpty ? _systemPrompt : prompt;
        });
      }
      return null;
    });
  }

  Future<void> _startListening() async {
    if (_listening) return;
    if (_openAIKey.isEmpty) {
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

    _pendingAudioBytes = 0;
    _responseInFlight = false;
    _finalResponseQueued = false;
    _responses.clear();
    _currentResponse = '';
    _statusMessage = 'Conectando con OpenAI';
    _addLog('Iniciando sesion con OpenAI');
    final promptPreview = _promptOverride.length > 120
        ? '${_promptOverride.substring(0, 120)}...'
        : _promptOverride;
    _addLog('Prompt activo: $promptPreview');
    _openAIClient = OpenAIRealtimeClient(
      openAIKey: _openAIKey,
      onDelta: _appendResponse,
      onComplete: _handleResponseComplete,
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
      Duration(seconds: _realtimeFlushSeconds),
      (_) => _flushRealtimeResponse(),
    );
  }

  Future<void> _stopListening() async {
    if (!_listening) return;
    _timer?.cancel();
    _realtimeTimer?.cancel();
    _realtimeTimer = null;
    if (Platform.isWindows) {
      await _stopWindowsCapture();
    } else if (_audioSupported) {
      _addLog('Deteniendo flutter_audio_capture');
      await _audioCapture.stop();
    }
    if (_pendingAudioBytes > 0) {
      await _openAIClient?.commitBuffer();
      _pendingAudioBytes = 0;
      if (_responseInFlight) {
        _finalResponseQueued = true;
      } else {
        _responseInFlight = true;
        await _openAIClient?.requestResponse(instructions: _promptOverride);
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
      ..setFrame(Rect.fromLTWH(0, 0, screenWidth / 2, screenHeight / 2))
      ..setTitle('Configuracion')
      ..show();
  }

  void _openMicPrivacySettings() {
    _addLog('Abriendo configuracion de micrófono en Windows');
    Process.start('cmd', ['/c', 'start', 'ms-settings:privacy-microphone']);
  }

  void _appendResponse(String delta) {
    setState(() {
      _currentResponse = '$_currentResponse$delta';
      _statusMessage = 'Respuesta en pantalla';
    });
    _scrollToBottom();
  }

  void _handleResponseComplete() {
    setState(() {
      _statusMessage = 'Respuesta completa';
    });
    final text = _extractResponseText(_currentResponse);
    if (text.isNotEmpty) {
      _responses.add(text);
    }
    _currentResponse = '';
    _scrollToBottom();
    _responseInFlight = false;
    if (!_listening && _finalResponseQueued) {
      _finalResponseQueued = false;
      _responseInFlight = true;
      _openAIClient?.requestResponse(instructions: _promptOverride);
      return;
    }
    if (!_listening) {
      _openAIClient?.close();
      _openAIClient = null;
    }
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
      } catch (_) {
        // Fall back below.
      }
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

  String _extractStreamingText(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    if (!trimmed.contains('llm_generated_text')) {
      return trimmed;
    }
    final idx = trimmed.indexOf('llm_generated_text');
    var start = trimmed.indexOf('"', idx);
    start = trimmed.indexOf('"', start + 1);
    if (start == -1) return trimmed;
    final end = trimmed.lastIndexOf('"');
    if (end <= start) return trimmed.substring(start + 1);
    return trimmed.substring(start + 1, end);
  }

  String _buildResponsesText() {
    final lines = <String>[];
    for (final response in _responses) {
      if (response.isNotEmpty) {
        lines.add(response);
      }
    }
    final current = _extractStreamingText(_currentResponse);
    if (current.isNotEmpty) {
      lines.add(current);
    }
    if (lines.isEmpty) return '';
    return lines.map((line) => '- $line').join('\n');
  }

  void _appendAudio(Uint8List bytes) {
    _pendingAudioBytes += bytes.length;
    _openAIClient?.appendAudio(bytes);
    _logAudioLevel(bytes);
  }

  Future<void> _flushRealtimeResponse() async {
    if (!_listening || _openAIClient == null) return;
    if (_responseInFlight || _pendingAudioBytes == 0) return;
    _responseInFlight = true;
    _pendingAudioBytes = 0;
    await _openAIClient?.commitBuffer();
    await _openAIClient?.requestResponse(instructions: _promptOverride);
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
    final rms = Math.sqrt(sumSquares / samples);
    final db = 20 * Math.log(rms / 32768 + 1e-6) / Math.ln10;
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
    if (_windowsAudioDevice.isEmpty) {
      setState(() {
        _statusMessage =
            'Define WINDOWS_AUDIO_DEVICE en .env (ej. "Stereo Mix (Realtek(R) Audio)")';
        _listening = false;
      });
      return;
    }

    try {
      _addLog('Dispositivo de captura: $_windowsAudioDevice');
      if (_windowsAudioSampleRate.isNotEmpty) {
        _addLog('Sample rate de captura: $_windowsAudioSampleRate');
      }

      final args = <String>[];
      String buildInputDevice(String device) {
        if (_windowsAudioBackend == 'wasapi' &&
            device.toLowerCase() == 'default') {
          return 'default';
        }
        return 'audio=$device';
      }

      void addInput(String device, {bool loopback = false}) {
        args.addAll(['-f', _windowsAudioBackend]);
        if (_windowsAudioSampleRate.isNotEmpty) {
          args.addAll(['-sample_rate', _windowsAudioSampleRate]);
        }
        if (_windowsAudioBackend == 'wasapi' && loopback) {
          _addLog('Captura loopback habilitada (audio de salida)');
          args.addAll(['-loopback', '1']);
        }
        args.addAll(['-i', buildInputDevice(device)]);
      }

      addInput(
        _windowsAudioDevice,
        loopback: _windowsAudioBackend == 'wasapi' && _windowsAudioLoopback,
      );

      final includeMic = _micMixEnabled && _windowsMicDevice.trim().isNotEmpty;
      if (includeMic) {
        _addLog('Microfono adicional: $_windowsMicDevice');
        addInput(_windowsMicDevice);
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
      _addLog('ffmpeg arrancado con $_windowsAudioDevice');
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
        if (_showFfmpegLogs) {
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
    _timer?.cancel();
    _realtimeTimer?.cancel();
    _scrollController.dispose();
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
    Widget navIconButton(
        IconData icon, String tooltip, VoidCallback? onPressed) {
      return Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: colorScheme.primary.withOpacity(0.2),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          splashRadius: 22,
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
          onPanStart: (_) => windowManager.startDragging(),
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(
                minHeight: _barHeight, maxHeight: _barHeight),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  colorScheme.surfaceVariant.withOpacity(0.85),
                  colorScheme.surface.withOpacity(0.95),
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
                  color: Colors.black38,
                  blurRadius: 28,
                  spreadRadius: -8,
                  offset: Offset(0, 12),
                ),
              ],
              border: Border.all(
                color: colorScheme.outlineVariant.withOpacity(0.4),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              child: Column(
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
                          if (Platform.isWindows) ...[
                            const SizedBox(width: 12),
                            TextButton(
                              onPressed: () => _setMicMixEnabled(false),
                              child: const Text('Solo PC'),
                            ),
                            const SizedBox(width: 4),
                            TextButton(
                              onPressed: _windowsMicAvailable
                                  ? () => _setMicMixEnabled(true)
                                  : null,
                              child: const Text('PC + Mic'),
                            ),
                          ],
                        ],
                      ),
                      Row(
                        children: [
                          IconButton(
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            onPressed: () => windowManager.minimize(),
                            icon: const Icon(Icons.remove_rounded),
                            tooltip: 'Minimizar',
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            onPressed: () => windowManager.close(),
                            icon: const Icon(Icons.close_rounded),
                            tooltip: 'Cerrar',
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Divider(height: 0),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      physics: const ClampingScrollPhysics(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _listening
                                ? (_micMixEnabled && _windowsMicAvailable
                                    ? 'Escuchando sistema y microfono'
                                    : (Platform.isWindows
                                        ? 'Escuchando audio del sistema'
                                        : 'Escuchando microfono'))
                                : 'Listo para escuchar',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _listening
                                ? 'Duracion: ${_elapsed.inMinutes.toString().padLeft(2, '0')}:${(_elapsed.inSeconds % 60).toString().padLeft(2, '0')}'
                                : 'Presiona iniciar para comenzar',
                            style: Theme.of(context)
                                .textTheme
                                .labelLarge
                                ?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Barra flotante',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                  Text(
                                    _listening ? 'Grabando' : 'En espera',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: colorScheme.primary,
                                        ),
                                  ),
                                ],
                              ),
                              if (_responses.isNotEmpty ||
                                  _currentResponse.isNotEmpty ||
                                  _statusMessage.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    (_responses.isNotEmpty ||
                                            _currentResponse.isNotEmpty)
                                        ? _buildResponsesText()
                                        : _statusMessage,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                            color: colorScheme.onSurface),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
