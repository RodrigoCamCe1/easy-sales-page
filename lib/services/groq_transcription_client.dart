import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Client for Groq's Whisper-based audio transcription API.
/// Accepts raw PCM audio (16-bit, mono, 24kHz), wraps it in a WAV header,
/// and sends it to Groq for transcription.
class GroqTranscriptionClient {
  GroqTranscriptionClient({
    required this.apiKey,
    this.model = 'whisper-large-v3-turbo',
    this.language = 'es',
    this.onLog,
  });

  final String apiKey;
  final String model;
  final String language;
  final void Function(String)? onLog;

  static const String _baseUrl = 'https://api.groq.com/openai/v1/audio/transcriptions';
  static const int _sampleRate = 24000;
  static const int _bitsPerSample = 16;
  static const int _numChannels = 1;

  final HttpClient _httpClient = HttpClient();

  /// Transcribes raw PCM audio bytes into text.
  /// [pcmBytes] must be 16-bit signed LE, mono, 24kHz.
  /// Returns the transcribed text, or null on failure.
  Future<String?> transcribe(Uint8List pcmBytes) async {
    if (pcmBytes.isEmpty) return null;

    final wavBytes = _wrapPcmInWav(pcmBytes);
    const boundary = '----GroqFormBoundary7MA4YWxkTrZu0gW';

    try {
      final request = await _httpClient.postUrl(Uri.parse(_baseUrl));
      request.headers.set('Authorization', 'Bearer $apiKey');
      request.headers.set('Content-Type', 'multipart/form-data; boundary=$boundary');

      // Build multipart body
      final body = BytesBuilder();

      // file field
      _addMultipartField(body, boundary, 'file', 'audio.wav', wavBytes);
      // model field
      _addMultipartTextField(body, boundary, 'model', model);
      // language field
      _addMultipartTextField(body, boundary, 'language', language);
      // response_format field
      _addMultipartTextField(body, boundary, 'response_format', 'json');
      // closing boundary
      body.add(utf8.encode('--$boundary--\r\n'));

      final bodyBytes = body.toBytes();
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);

      final response = await request.close().timeout(const Duration(seconds: 30));
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200) {
        final json = jsonDecode(responseBody) as Map<String, dynamic>;
        final text = (json['text'] as String?)?.trim() ?? '';
        if (text.isNotEmpty) {
          _log('Transcripción: "$text"');
        }
        return text.isEmpty ? null : text;
      } else {
        _log('Error de transcripción ${response.statusCode}: $responseBody');
        return null;
      }
    } catch (e) {
      _log('Error de transcripción: $e');
      return null;
    }
  }

  void _addMultipartField(BytesBuilder body, String boundary, String name, String filename, Uint8List data) {
    body.add(utf8.encode('--$boundary\r\n'));
    body.add(utf8.encode('Content-Disposition: form-data; name="$name"; filename="$filename"\r\n'));
    body.add(utf8.encode('Content-Type: audio/wav\r\n\r\n'));
    body.add(data);
    body.add(utf8.encode('\r\n'));
  }

  void _addMultipartTextField(BytesBuilder body, String boundary, String name, String value) {
    body.add(utf8.encode('--$boundary\r\n'));
    body.add(utf8.encode('Content-Disposition: form-data; name="$name"\r\n\r\n'));
    body.add(utf8.encode('$value\r\n'));
  }

  /// Wraps raw PCM bytes in a standard WAV header (44 bytes).
  Uint8List _wrapPcmInWav(Uint8List pcmData) {
    const dataOffset = 44;
    final dataSize = pcmData.length;
    final fileSize = 36 + dataSize;
    const byteRate = _sampleRate * _numChannels * (_bitsPerSample ~/ 8);
    const blockAlign = _numChannels * (_bitsPerSample ~/ 8);

    final header = ByteData(dataOffset);
    int offset = 0;

    void writeString(String s) {
      for (int i = 0; i < s.length; i++) {
        header.setUint8(offset++, s.codeUnitAt(i));
      }
    }

    // RIFF chunk
    writeString('RIFF');
    header.setUint32(offset, fileSize, Endian.little); offset += 4;
    writeString('WAVE');

    // fmt sub-chunk
    writeString('fmt ');
    header.setUint32(offset, 16, Endian.little); offset += 4;
    header.setUint16(offset, 1, Endian.little); offset += 2;  // PCM
    header.setUint16(offset, _numChannels, Endian.little); offset += 2;
    header.setUint32(offset, _sampleRate, Endian.little); offset += 4;
    header.setUint32(offset, byteRate, Endian.little); offset += 4;
    header.setUint16(offset, blockAlign, Endian.little); offset += 2;
    header.setUint16(offset, _bitsPerSample, Endian.little); offset += 2;

    // data sub-chunk
    writeString('data');
    header.setUint32(offset, dataSize, Endian.little); offset += 4;

    // Combine
    final wav = Uint8List(dataOffset + dataSize);
    wav.setRange(0, dataOffset, header.buffer.asUint8List());
    wav.setRange(dataOffset, dataOffset + dataSize, pcmData);
    return wav;
  }

  void _log(String msg) {
    debugPrint(msg);
    onLog?.call(msg);
  }

  void close() {
    _httpClient.close();
  }
}
