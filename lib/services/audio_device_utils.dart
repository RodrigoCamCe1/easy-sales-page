import 'dart:io';

import 'package:path/path.dart' as p;

/// Enumera los dispositivos de audio dshow disponibles usando ffmpeg.
/// Retorna una lista de nombres (ej. "Stereo Mix (Realtek(R) Audio)").
Future<List<String>> enumerateAudioDevices() async {
  try {
    final ffmpeg = _resolveFfmpeg();
    final result = await Process.run(
      ffmpeg,
      ['-f', 'dshow', '-list_devices', 'true', '-i', 'dummy'],
    );

    // ffmpeg lista los dispositivos en stderr
    final stderr = result.stderr as String;
    final devices = <String>[];
    final re = RegExp(r'"(.+?)" \(audio\)');
    for (final match in re.allMatches(stderr)) {
      final name = match.group(1);
      if (name != null && name.isNotEmpty) {
        devices.add(name);
      }
    }
    return devices;
  } catch (_) {
    return [];
  }
}

String _resolveFfmpeg() {
  final exeDir = p.dirname(Platform.resolvedExecutable);
  final bundled = p.join(exeDir, 'ffmpeg.exe');
  if (File(bundled).existsSync()) return bundled;
  return 'ffmpeg';
}
