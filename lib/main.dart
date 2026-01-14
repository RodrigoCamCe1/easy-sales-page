import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as Math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:window_manager/window_manager.dart';

const double _barHeight = 220.0;
const String _dartDefineOpenAIKey = String.fromEnvironment('OPENAI_API_KEY');
const String _openAITranscribeModel = 'gpt-4o-mini-transcribe';
const String _openAIResponseModel = 'gpt-4o-mini';
const bool _showFfmpegLogs = false;
const bool _saveDebugWav = true;
String get _openAIKey {
  if (_dartDefineOpenAIKey.isNotEmpty) {
    return _dartDefineOpenAIKey;
  }
  if (dotenv.isInitialized) {
    return dotenv.env['OPENAI_API_KEY'] ?? '';
  }
  return '';
}

String get _elevenLabsApiKey => dotenv.env['ELEVENLABS_API_KEY'] ?? '';
String get _elevenLabsSttModel =>
    dotenv.env['ELEVENLABS_STT_MODEL_ID'] ?? 'scribe_v1';

String get _systemPrompt =>
    dotenv.env['SYSTEM_PROMPT'] ??
    'Eres un agente de IA que responde de forma clara y breve.';

String get _windowsAudioDevice =>
    dotenv.env['WINDOWS_AUDIO_DEVICE'] ?? 'Stereo Mix (Realtek(R) Audio)';
String get _windowsAudioBackend => dotenv.env['WINDOWS_AUDIO_BACKEND'] ?? 'dshow';
String get _windowsAudioSampleRate =>
    dotenv.env['WINDOWS_AUDIO_SAMPLE_RATE'] ?? '';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  await windowManager.ensureInitialized();

  final flutterView = WidgetsBinding.instance.platformDispatcher.views.first;
  final screenWidth = flutterView.physicalSize.width / flutterView.devicePixelRatio;
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

class OpenAITranscribeClient {
  OpenAITranscribeClient({required this.openAIKey});

  final String openAIKey;

  Future<String> transcribe(Uint8List wavBytes) async {
    final boundary = '----dartform${DateTime.now().microsecondsSinceEpoch}';
    final uri = Uri.parse('https://api.openai.com/v1/audio/transcriptions');
    final client = HttpClient();
    final request = await client.postUrl(uri);
    request.headers.set('Authorization', 'Bearer $openAIKey');
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'multipart/form-data; boundary=$boundary',
    );

    void writeField(String name, String value) {
      request.write('--$boundary\r\n');
      request.write('Content-Disposition: form-data; name="$name"\r\n\r\n');
      request.write(value);
      request.write('\r\n');
    }

    void writeFile(
      String name,
      String filename,
      String contentType,
      Uint8List bytes,
    ) {
      request.write('--$boundary\r\n');
      request.write(
        'Content-Disposition: form-data; name="$name"; filename="$filename"\r\n',
      );
      request.write('Content-Type: $contentType\r\n\r\n');
      request.add(bytes);
      request.write('\r\n');
    }

    writeField('model', _openAITranscribeModel);
    writeField('language', 'es');
    writeField('response_format', 'json');
    writeFile('file', 'audio.wav', 'audio/wav', wavBytes);
    request.write('--$boundary--\r\n');

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close();

    if (response.statusCode >= 400) {
      throw Exception('OpenAI ${response.statusCode}: $body');
    }

    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['text'] is String) {
      return decoded['text'] as String;
    }
    return body;
  }
}

class ElevenLabsTranscribeClient {
  ElevenLabsTranscribeClient({required this.apiKey});

  final String apiKey;

  Future<String> transcribe(Uint8List wavBytes) async {
    final boundary = '----dartform${DateTime.now().microsecondsSinceEpoch}';
    final uri = Uri.parse('https://api.elevenlabs.io/v1/speech-to-text');
    final client = HttpClient();
    final request = await client.postUrl(uri);
    request.headers.set('xi-api-key', apiKey);
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'multipart/form-data; boundary=$boundary',
    );

    void writeField(String name, String value) {
      request.write('--$boundary\r\n');
      request.write('Content-Disposition: form-data; name="$name"\r\n\r\n');
      request.write(value);
      request.write('\r\n');
    }

    void writeFile(
      String name,
      String filename,
      String contentType,
      Uint8List bytes,
    ) {
      request.write('--$boundary\r\n');
      request.write(
        'Content-Disposition: form-data; name="$name"; filename="$filename"\r\n',
      );
      request.write('Content-Type: $contentType\r\n\r\n');
      request.add(bytes);
      request.write('\r\n');
    }

    writeField('model_id', _elevenLabsSttModel);
    writeField('language_code', 'es');
    writeFile('file', 'audio.wav', 'audio/wav', wavBytes);
    request.write('--$boundary--\r\n');

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close();

    if (response.statusCode >= 400) {
      throw Exception('ElevenLabs ${response.statusCode}: $body');
    }

    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final text = decoded['text'] ?? decoded['transcript'];
      if (text is String) {
        return text;
      }
    }
    return body;
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
  final FlutterAudioCapture _audioCapture = FlutterAudioCapture();
  String _aiResponse = '';
  String _statusMessage = '';
  Process? _audioProcess;
  StreamSubscription<List<int>>? _audioSubscription;
  BytesBuilder _audioBuffer = BytesBuilder(copy: false);
  bool _transcribing = false;
  DateTime? _lastLevelLogAt;

  bool get _audioSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isLinux;

  void _addLog(String entry) {
    final timestamp = DateTime.now().toIso8601String();
    debugPrint('[$timestamp] $entry');
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

    _audioBuffer = BytesBuilder(copy: false);
    _transcribing = false;
    _aiResponse = '';
    _statusMessage = 'Preparando captura de audio';
    _addLog('Iniciando captura de audio');
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

  }

  Future<void> _stopListening() async {
    if (!_listening) return;
    _timer?.cancel();
    if (Platform.isWindows) {
      await _stopWindowsCapture();
    } else if (_audioSupported) {
      _addLog('Deteniendo flutter_audio_capture');
      await _audioCapture.stop();
    }
    final pcmBytes = _audioBuffer.toBytes();
    _audioBuffer = BytesBuilder(copy: false);
    setState(() {
      _listening = false;
      _elapsed = Duration.zero;
    });
    if (pcmBytes.isEmpty) {
      setState(() {
        _statusMessage = 'No hay audio para transcribir';
      });
      return;
    }
    await _requestTranscription(pcmBytes);
  }

  void _openSettings() {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Configuración'),
          content: const Text(
            'Aquí puedes seleccionar la fuente de audio (por ejemplo, un dispositivo loopback) '
            'y la carpeta de salida. La captura de audio del sistema requiere integrar un '
            'plugin nativo o usar un dispositivo virtual como VB-Audio/BlackHole.',
          ),
          actions: [
            if (Platform.isWindows)
              TextButton(
                onPressed: _openMicPrivacySettings,
                child: const Text('Ir a configuraciİn de Windows'),
              ),
            TextButton(
              onPressed: Navigator.of(context).pop,
              child: const Text('Cerrar'),
            ),
          ],
        );
      },
    );
  }

  void _openMicPrivacySettings() {
    _addLog('Abriendo configuracion de micrófono en Windows');
    Process.start('cmd', ['/c', 'start', 'ms-settings:privacy-microphone']);
  }

  Future<void> _requestTranscription(Uint8List pcmBytes) async {
    if (_transcribing) return;
    _transcribing = true;
    setState(() {
      _statusMessage = 'Transcribiendo audio';
    });

    final wavBytes = _buildWav(pcmBytes, sampleRate: 16000, channels: 1);
    if (_saveDebugWav) {
      await _saveDebugWavFile(wavBytes);
    }
    try {
      final String text;
      if (_elevenLabsApiKey.isNotEmpty) {
        _addLog('Usando transcripcion ElevenLabs');
        final client = ElevenLabsTranscribeClient(apiKey: _elevenLabsApiKey);
        text = await client.transcribe(wavBytes);
      } else {
        _addLog('Usando transcripcion OpenAI');
        final client = OpenAITranscribeClient(openAIKey: _openAIKey);
        text = await client.transcribe(wavBytes);
      }
      _addLog('Transcripcion recibida: $text');
      setState(() {
        _statusMessage = 'Generando respuesta';
      });
      try {
        final responseText = await _requestAssistantResponse(text);
        setState(() {
          _aiResponse = responseText;
          _statusMessage = 'Respuesta en pantalla';
        });
        _addLog('Respuesta IA: $responseText');
      } catch (error) {
        setState(() {
          _statusMessage = 'Error de respuesta: $error';
        });
        _addLog('Error de respuesta: $error');
      }
    } catch (error) {
      setState(() {
        _statusMessage = 'Error de transcripcion: $error';
      });
      _addLog('Error de transcripcion: $error');
    } finally {
      _transcribing = false;
    }
  }

  Future<String> _requestAssistantResponse(String transcript) async {
    final uri = Uri.parse('https://api.openai.com/v1/responses');
    final client = HttpClient();
    final request = await client.postUrl(uri);
    request.headers.set('Authorization', 'Bearer $_openAIKey');
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    _addLog('SYSTEM_PROMPT: $_systemPrompt');
    _addLog('USER_TRANSCRIPT: $transcript');
    final payload = {
      'model': _openAIResponseModel,
      'input': [
        {
          'role': 'system',
          'content': [
            {'type': 'input_text', 'text': _systemPrompt}
          ],
        },
        {
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': transcript}
          ],
        },
      ],
    };
    request.add(utf8.encode(jsonEncode(payload)));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close();

    if (response.statusCode >= 400) {
      throw Exception('OpenAI ${response.statusCode}: $body');
    }

    final decoded = jsonDecode(body);
    final output = decoded is Map ? decoded['output'] : null;
    if (output is List) {
      for (final item in output) {
        if (item is Map && item['content'] is List) {
          for (final content in item['content']) {
            if (content is Map && content['type'] == 'output_text') {
              final text = content['text'];
              if (text is String && text.isNotEmpty) {
                return text;
              }
            }
          }
        }
      }
    }
    if (decoded is Map && decoded['output_text'] is String) {
      return decoded['output_text'] as String;
    }
    return body;
  }

  Uint8List _buildWav(
    Uint8List pcmBytes, {
    required int sampleRate,
    required int channels,
  }) {
    const int bitsPerSample = 16;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final dataSize = pcmBytes.length;
    final fileSize = 36 + dataSize;

    final buffer = BytesBuilder(copy: false);
    buffer.add(ascii.encode('RIFF'));
    buffer.add(_int32le(fileSize));
    buffer.add(ascii.encode('WAVE'));
    buffer.add(ascii.encode('fmt '));
    buffer.add(_int32le(16));
    buffer.add(_int16le(1));
    buffer.add(_int16le(channels));
    buffer.add(_int32le(sampleRate));
    buffer.add(_int32le(byteRate));
    buffer.add(_int16le(blockAlign));
    buffer.add(_int16le(bitsPerSample));
    buffer.add(ascii.encode('data'));
    buffer.add(_int32le(dataSize));
    buffer.add(pcmBytes);
    return buffer.toBytes();
  }

  Uint8List _int16le(int value) {
    final data = ByteData(2);
    data.setInt16(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  Uint8List _int32le(int value) {
    final data = ByteData(4);
    data.setInt32(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  Future<void> _saveDebugWavFile(Uint8List wavBytes) async {
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final dir = Directory.systemTemp;
    final file = File('${dir.path}\\easysales_audio_test_$timestamp.wav');
    await file.writeAsBytes(wavBytes, flush: true);
    _addLog('WAV de prueba guardado: ${file.path}');
  }

  void _appendAudio(Uint8List bytes) {
    _audioBuffer.add(bytes);
    _logAudioLevel(bytes);
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
      final args = <String>['-f', _windowsAudioBackend];
      if (_windowsAudioSampleRate.isNotEmpty) {
        _addLog('Sample rate de captura: $_windowsAudioSampleRate');
        args.addAll(['-sample_rate', _windowsAudioSampleRate]);
      }
      args.addAll([
        '-i',
        'audio=$_windowsAudioDevice',
        '-ac',
        '1',
        '-ar',
        '16000',
        '-f',
        's16le',
        '-',
      ]);
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
    _audioCapture.stop();
    if (Platform.isWindows) {
      _audioSubscription?.cancel();
      _audioProcess?.kill();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget navIconButton(IconData icon, String tooltip, VoidCallback? onPressed) {
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
            constraints: const BoxConstraints(minHeight: _barHeight, maxHeight: _barHeight),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _listening ? 'Escuchando audio del sistema' : 'Listo para escuchar',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _listening
                              ? 'Duración: ${_elapsed.inMinutes.toString().padLeft(2, '0')}:${(_elapsed.inSeconds % 60).toString().padLeft(2, '0')}'
                              : 'Presiona iniciar para comenzar',
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Barra flotante',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                Text(
                                  _listening ? 'Grabando…' : 'En espera',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: colorScheme.primary,
                                      ),
                                ),
                              ],
                            ),
                            if (_aiResponse.isNotEmpty || _statusMessage.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    _aiResponse.isNotEmpty ? _aiResponse : _statusMessage,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(color: colorScheme.onSurface),
                                  ),
                                ),
                          ],
                        ),
                      ],
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
