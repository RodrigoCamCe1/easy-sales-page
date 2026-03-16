import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persists the user's audio device selection.
/// Not scoped per user — audio devices belong to the hardware.
class AudioPreferencesStore {
  AudioPreferencesStore._();

  static final AudioPreferencesStore instance = AudioPreferencesStore._();

  String? _systemDevice;
  String? _micDevice;

  /// Stable device IDs (dshow alternative names) — encoding-safe ASCII paths.
  String? _systemDeviceId;
  String? _micDeviceId;

  /// Effective system device display name: saved preference → .env fallback.
  String get systemDevice =>
      _systemDevice ??
      dotenv.env['WINDOWS_AUDIO_DEVICE'] ??
      'Stereo Mix (Realtek(R) Audio)';

  set systemDevice(String value) => _systemDevice = value;

  /// Effective mic device display name: saved preference → .env fallback.
  String get micDevice =>
      _micDevice ?? dotenv.env['WINDOWS_MIC_DEVICE'] ?? '';

  set micDevice(String value) => _micDevice = value;

  /// Stable system device ID (alternative name). Falls back to display name.
  String get systemDeviceId =>
      (_systemDeviceId != null && _systemDeviceId!.isNotEmpty)
          ? _systemDeviceId!
          : systemDevice;

  set systemDeviceId(String value) => _systemDeviceId = value;

  /// Stable mic device ID (alternative name). Falls back to display name.
  String get micDeviceId =>
      (_micDeviceId != null && _micDeviceId!.isNotEmpty)
          ? _micDeviceId!
          : micDevice;

  set micDeviceId(String value) => _micDeviceId = value;

  // ──────────────────────────────────────────────────────────────

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'audio_prefs.json'));
  }

  Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      final map = jsonDecode(raw);
      if (map is! Map) return;
      _systemDevice = map['systemDevice'] as String?;
      _micDevice = map['micDevice'] as String?;
      _systemDeviceId = map['systemDeviceId'] as String?;
      _micDeviceId = map['micDeviceId'] as String?;
    } catch (e) {
      debugPrint('[AudioPreferencesStore] load error: $e');
    }
  }

  Future<void> save() async {
    try {
      final f = await _file();
      final map = <String, String?>{
        'systemDevice': _systemDevice,
        'micDevice': _micDevice,
        'systemDeviceId': _systemDeviceId,
        'micDeviceId': _micDeviceId,
      };
      await f.writeAsString(jsonEncode(map));
    } catch (e) {
      debugPrint('[AudioPreferencesStore] save error: $e');
    }
  }
}
