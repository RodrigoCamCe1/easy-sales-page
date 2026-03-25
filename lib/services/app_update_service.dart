import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/app_config.dart';

class UpdateInfo {
  final String latestVersion;
  final String downloadUrl;
  final String releaseNotes;

  const UpdateInfo({
    required this.latestVersion,
    required this.downloadUrl,
    required this.releaseNotes,
  });
}

class AppUpdateService {
  static final instance = AppUpdateService._();
  AppUpdateService._();

  /// Checks GitHub releases for a newer version.
  /// Returns [UpdateInfo] if an update is available, null otherwise.
  Future<UpdateInfo?> checkForUpdate() async {
    try {
      final client = HttpClient();
      final uri = Uri.parse(
        'https://api.github.com/repos/$githubRepo/releases/latest',
      );
      final request = await client.getUrl(uri);
      request.headers.set('Accept', 'application/vnd.github.v3+json');
      final response = await request.close();

      debugPrint('[UPDATE] GitHub API status: ${response.statusCode}');
      if (response.statusCode != 200) return null;

      final body = await response.transform(utf8.decoder).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final tagName = data['tag_name'] as String?;
      debugPrint('[UPDATE] tag_name: $tagName');
      if (tagName == null) return null;

      final remoteVersion = tagName.replaceFirst(RegExp(r'^v'), '');
      debugPrint('[UPDATE] Remote: $remoteVersion, Local: $appVersion, isNewer: ${_isNewer(remoteVersion, appVersion)}');
      if (!_isNewer(remoteVersion, appVersion)) return null;

      // Find the .exe asset
      final assets = data['assets'] as List<dynamic>?;
      String? downloadUrl;
      if (assets != null) {
        for (final asset in assets) {
          if (asset is Map && (asset['name'] as String?)?.endsWith('.exe') == true) {
            downloadUrl = asset['browser_download_url'] as String?;
            break;
          }
        }
      }
      if (downloadUrl == null) return null;

      final notes = data['body'] as String? ?? '';

      return UpdateInfo(
        latestVersion: remoteVersion,
        downloadUrl: downloadUrl,
        releaseNotes: notes,
      );
    } catch (e) {
      debugPrint('Update check failed: $e');
      return null;
    }
  }

  /// Downloads the installer and launches it.
  Future<bool> downloadAndInstall(String downloadUrl) async {
    try {
      final tempDir = Directory.systemTemp;
      final fileName = downloadUrl.split('/').last;
      final filePath = p.join(tempDir.path, fileName);
      final file = File(filePath);

      // Download
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(downloadUrl));
      final response = await request.close();

      if (response.statusCode != 200) return false;

      final sink = file.openWrite();
      await response.pipe(sink);

      // Launch installer: /SILENT installs quietly, /RESTARTAPPLICATIONS reopens the app after
      await Process.start(
        filePath,
        ['/SILENT', '/RESTARTAPPLICATIONS', '/CLOSEAPPLICATIONS'],
        mode: ProcessStartMode.detached,
      );
      exit(0);
    } catch (e) {
      debugPrint('Download/install failed: $e');
      return false;
    }
  }

  /// Compares two semver strings. Returns true if [remote] is newer than [local].
  bool _isNewer(String remote, String local) {
    final remoteParts = remote.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final localParts = local.split('.').map((s) => int.tryParse(s) ?? 0).toList();

    // Pad to same length
    while (remoteParts.length < 3) remoteParts.add(0);
    while (localParts.length < 3) localParts.add(0);

    for (var i = 0; i < 3; i++) {
      if (remoteParts[i] > localParts[i]) return true;
      if (remoteParts[i] < localParts[i]) return false;
    }
    return false;
  }
}
