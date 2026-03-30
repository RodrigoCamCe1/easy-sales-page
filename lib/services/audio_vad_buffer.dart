import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

/// Simple VAD (Voice Activity Detection) buffer.
/// Accumulates PCM audio chunks and fires [onSpeechComplete] when
/// it detects silence after speech, delivering the buffered audio.
class AudioVadBuffer {
  AudioVadBuffer({
    required this.onSpeechComplete,
    this.silenceThresholdDb = -40.0,
    this.silenceDurationMs = 1200,
    this.minSpeechDurationMs = 500,
    this.maxBufferDurationMs = 30000,
    this.sampleRate = 24000,
  });

  /// Called with accumulated PCM bytes when speech ends (silence detected).
  final void Function(Uint8List pcmBytes) onSpeechComplete;

  /// dB threshold below which audio is considered silence.
  final double silenceThresholdDb;

  /// How long silence must last before triggering speech complete (ms).
  final int silenceDurationMs;

  /// Minimum speech duration before we consider it valid (ms).
  final int minSpeechDurationMs;

  /// Maximum buffer duration — flush even if still speaking (ms).
  final int maxBufferDurationMs;

  final int sampleRate;

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  bool _isSpeaking = false;
  DateTime? _speechStartTime;
  DateTime? _lastSpeechTime;
  Timer? _silenceTimer;

  /// Feed a chunk of PCM audio (16-bit signed LE, mono).
  /// Optional log callback for debugging.
  void Function(String)? onLog;

  void addAudio(Uint8List chunk) {
    final db = _calculateDb(chunk);

    if (db > silenceThresholdDb) {
      // Speech detected
      if (!_isSpeaking) {
        _isSpeaking = true;
        _speechStartTime = DateTime.now();
        onLog?.call('VAD: habla detectada (${db.toStringAsFixed(0)} dB)');
      }
      _lastSpeechTime = DateTime.now();
      _silenceTimer?.cancel();
      _silenceTimer = null;
    } else if (_isSpeaking) {
      // Silence after speech — start silence timer
      _silenceTimer ??= Timer(Duration(milliseconds: silenceDurationMs), () {
        onLog?.call('VAD: silencio confirmado, enviando buffer');
        _onSilenceTimeout();
      });
    }

    // Always buffer while speaking
    if (_isSpeaking) {
      _buffer.add(chunk);

      // Check max buffer duration
      if (_speechStartTime != null) {
        final elapsed = DateTime.now().difference(_speechStartTime!).inMilliseconds;
        if (elapsed >= maxBufferDurationMs) {
          onLog?.call('VAD: max buffer alcanzado (${elapsed}ms), forzando flush');
          _flush();
        }
      }
    }
  }

  void _onSilenceTimeout() {
    if (!_isSpeaking) return;

    // Check minimum speech duration
    final speechDuration = _speechStartTime != null
        ? (_lastSpeechTime ?? DateTime.now()).difference(_speechStartTime!).inMilliseconds
        : 0;

    if (speechDuration >= minSpeechDurationMs) {
      _flush();
    } else {
      // Too short — discard
      _reset();
    }
  }

  void _flush() {
    if (_buffer.isEmpty) {
      _reset();
      return;
    }

    final bytes = _buffer.toBytes();
    _reset();

    // Fire callback with accumulated audio
    onSpeechComplete(Uint8List.fromList(bytes));
  }

  void _reset() {
    _buffer.clear();
    _isSpeaking = false;
    _speechStartTime = null;
    _lastSpeechTime = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
  }

  /// Force flush any buffered audio (e.g., on stop listening).
  void forceFlush() {
    if (_buffer.isNotEmpty && _isSpeaking) {
      _flush();
    } else {
      _reset();
    }
  }

  void dispose() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _buffer.clear();
  }

  /// Calculate dB level of a PCM chunk (16-bit signed LE, mono).
  double _calculateDb(Uint8List bytes) {
    if (bytes.length < 2) return -100.0;

    final samples = bytes.buffer.asInt16List(bytes.offsetInBytes, bytes.length ~/ 2);
    double sumSquares = 0;
    for (final sample in samples) {
      final normalized = sample / 32768.0;
      sumSquares += normalized * normalized;
    }
    final rms = math.sqrt(sumSquares / samples.length);
    if (rms < 1e-10) return -100.0;
    return 20 * math.log(rms) / math.ln10;
  }
}
