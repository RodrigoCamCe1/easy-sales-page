import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/app_config.dart';
import 'services/audio_preferences_store.dart';
import 'services/auth_session_manager.dart';
import 'ui/meeting_bar.dart';
import 'ui/recording_bar.dart';
import 'ui/settings_window.dart';

Map<String, dynamic> _parseWindowArgs(List<String> args) {
  // args[0] = windowId, args[1] = json payload (normalmente)
  if (args.length < 2) return {};

  final rawArgs = args[1].toString();
  dynamic decoded;

  try {
    decoded = jsonDecode(rawArgs);
  } catch (_) {
    // A veces llega con comillas simples
    try {
      decoded = jsonDecode(rawArgs.replaceAll("'", '"'));
    } catch (_) {
      decoded = null;
    }
  }

  // A veces viene doble-encoded
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } catch (_) {}
  }

  if (decoded is Map) {
    return Map<String, dynamic>.from(decoded);
  }

  return {};
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');

  // En Windows, cargar AudioPreferencesStore antes de crear subventanas
  // En macOS, protegido con try-catch porque path_provider falla en subventanas
  if (Platform.isWindows) {
    try {
      await AudioPreferencesStore.instance.load();
    } catch (e) {
      debugPrint('[BOOT] Error loading audio prefs on Windows: $e');
    }
  }

  // ============================
  // SUBWINDOW (desktop_multi_window)
  // ============================
  if (args.isNotEmpty) {
    // ignore: avoid_print
    print('[BOOT] args=$args');

    // 1) Detecta windowId: primer token numérico
    int windowId = 0;
    for (final a in args) {
      final n = int.tryParse(a);
      if (n != null) {
        windowId = n;
        break;
      }
    }

    // 2) Detecta payload JSON: primer token que “parece JSON”
    String raw = '';
    for (final a in args) {
      final t = a.toString().trim();
      if (t.startsWith('{') || t.contains('"type"') || t.contains("'type'")) {
        raw = t;
        break;
      }
    }

    // Debug
    // ignore: avoid_print
    print('[SUBWINDOW] windowId=$windowId raw=$raw');

    Map<String, dynamic> arguments = {};
    dynamic decoded;

    if (raw.isNotEmpty) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        try {
          decoded = jsonDecode(raw.replaceAll("'", '"'));
        } catch (_) {
          decoded = null;
        }
      }

      if (decoded is String) {
        try {
          decoded = jsonDecode(decoded);
        } catch (_) {}
      }

      if (decoded is Map) {
        arguments = Map<String, dynamic>.from(decoded);
      }
    }

    final type = (arguments['type'] as String?)?.toLowerCase();

    // ignore: avoid_print
    print('[SUBWINDOW] parsed type=$type args=$arguments');

    // ✅ Regla: si explícitamente dice settings => settings
    if (type == 'settings') {
      await AuthSessionManager.instance.bootstrap();
      runApp(SettingsWindowApp(
        windowId: windowId,
        mainWindowId: arguments['mainWindowId'] as int? ?? 0,
        initialPrompt: arguments['prompt'] as String? ?? systemPrompt,
        agentId: arguments['agentId'] as String? ?? 'custom-default',
        agentName:
            arguments['agentName'] as String? ?? 'Personalizar tu agente',
        agentMode: arguments['agentMode'] as String? ?? 'custom',
        canEditPrompt: arguments['canEditPrompt'] as bool? ?? true,
      ));
      return;
    }

    // ✅ Meeting mode
    if (type == 'meeting') {
      await AuthSessionManager.instance.bootstrap();
      runApp(const MeetingBarApp());
      return;
    }

    // ✅ En cualquier otro caso (incluye vacío) => BAR
    await AuthSessionManager.instance.bootstrap();
    runApp(const RecordingBarApp());
    return;
  }

  // ============================
  // MAIN WINDOW (window_manager)
  // ============================
  // En macOS ya se cargó arriba (con manejo de errores)
  // En Windows, cargar de nuevo para la ventana principal
  if (Platform.isMacOS) {
    // En macOS, usar los valores por defecto de .env (que son seguros)
  } else {
    try {
      await AudioPreferencesStore.instance.load();
    } catch (e) {
      debugPrint('[BOOT] Error loading audio prefs on main window: $e');
    }
  }
  
  await windowManager.ensureInitialized();
  final flutterView = WidgetsBinding.instance.platformDispatcher.views.first;
  final screenSize = flutterView.physicalSize / flutterView.devicePixelRatio;

  final windowOptions = WindowOptions(
    size: Size(screenSize.width, screenSize.height),
    minimumSize: const Size(900, 600),
    center: true,
    backgroundColor: Colors.transparent,
    titleBarStyle: TitleBarStyle.hidden,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setAsFrameless();
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const AsesoriaApp());  
}
