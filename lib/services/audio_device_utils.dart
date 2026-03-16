import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Represents an audio device with a human-readable name and a stable,
/// encoding-safe alternative name (device path) provided by ffmpeg/dshow.
class AudioDeviceInfo {
  final String name;
  final String altName;

  const AudioDeviceInfo({required this.name, required this.altName});

  /// The identifier to pass to ffmpeg — prefers the alternative name (pure
  /// ASCII, encoding-safe) but falls back to the friendly name when the
  /// alternative is unavailable.
  String get deviceId => altName.isNotEmpty ? altName : name;

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioDeviceInfo &&
          runtimeType == other.runtimeType &&
          deviceId == other.deviceId;

  @override
  int get hashCode => deviceId.hashCode;
}

/// Enumera los dispositivos de audio dshow disponibles usando ffmpeg.
/// Retorna una lista de [AudioDeviceInfo] con nombre amigable y alternative
/// name (ID estable, ASCII puro).
Future<List<AudioDeviceInfo>> enumerateAudioDevices() async {
  try {
    final ffmpeg = _resolveFfmpeg();

    // ffmpeg may output in UTF-8 or the system OEM codepage depending on
    // the build/version. We run it once with raw bytes so we can try both
    // decodings and pick the one that produces clean text.
    final result = await Process.run(
      ffmpeg,
      ['-f', 'dshow', '-list_devices', 'true', '-i', 'dummy'],
      stdoutEncoding: null,
      stderrEncoding: null,
    );

    // ffmpeg lists devices on stderr
    final rawBytes = result.stderr as List<int>;
    final stderr = _decodeBest(rawBytes);

    return _parseDevices(stderr);
  } catch (_) {
    return [];
  }
}

/// Try UTF-8 first; if it produces replacement characters (U+FFFD) fall back
/// to the system OEM codepage which is what older ffmpeg builds use.
String _decodeBest(List<int> bytes) {
  final utf8Result = utf8.decode(bytes, allowMalformed: true);
  if (!utf8Result.contains('\uFFFD')) return utf8Result;
  return systemEncoding.decode(bytes);
}

List<AudioDeviceInfo> _parseDevices(String stderr) {
  final lines = stderr.split('\n');
  final devices = <AudioDeviceInfo>[];

  final nameRe = RegExp(r'"(.+?)" \(audio\)');
  final altRe = RegExp(r'Alternative name "(.+?)"');

  String? pendingName;
  for (final line in lines) {
    final nameMatch = nameRe.firstMatch(line);
    if (nameMatch != null) {
      // If we had a pending audio device without an alt name, flush it
      if (pendingName != null) {
        devices.add(AudioDeviceInfo(name: pendingName, altName: ''));
      }
      pendingName = nameMatch.group(1);
      continue;
    }

    if (pendingName != null) {
      final altMatch = altRe.firstMatch(line);
      if (altMatch != null) {
        devices.add(AudioDeviceInfo(
          name: pendingName,
          altName: altMatch.group(1) ?? '',
        ));
        pendingName = null;
      }
    }
  }
  // Flush last pending device if no alt name followed
  if (pendingName != null) {
    devices.add(AudioDeviceInfo(name: pendingName, altName: ''));
  }

  return devices;
}

String _resolveFfmpeg() {
  final exeDir = p.dirname(Platform.resolvedExecutable);
  final bundled = p.join(exeDir, 'ffmpeg.exe');
  if (File(bundled).existsSync()) return bundled;
  return 'ffmpeg';
}
