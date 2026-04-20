import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Tracks onboarding completion per screen.
class OnboardingService {
  OnboardingService._();
  static final OnboardingService instance = OnboardingService._();

  static const String _fileName = '.easyexpert_onboarding.json';

  Future<File> _file() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return File(p.join(dir.path, _fileName));
    } catch (e) {
      // En macOS subventanas, path_provider falla
      // Usar HOME/.config/easy-sales-ia como fallback
      final home = Platform.environment['HOME'];
      if (home != null && Platform.isMacOS) {
        final fallback = Directory('$home/.config/easy-sales-ia');
        if (!await fallback.exists()) {
          await fallback.create(recursive: true);
        }
        return File(p.join(fallback.path, _fileName));
      }
      rethrow;
    }
  }

  Future<Map<String, bool>> _load() async {
    final file = await _file();
    if (!file.existsSync()) return {};
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v == true));
      }
    } catch (_) {}
    return {};
  }

  Future<void> _save(Map<String, bool> data) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(data));
  }

  Future<bool> isCompleted(String screen) async {
    final data = await _load();
    return data[screen] ?? false;
  }

  Future<void> markCompleted(String screen) async {
    final data = await _load();
    data[screen] = true;
    await _save(data);
  }

  Future<void> reset(String screen) async {
    final data = await _load();
    data.remove(screen);
    await _save(data);
  }

  Future<void> resetAll() async {
    final file = await _file();
    if (await file.exists()) {
      await file.delete();
    }
  }
}
