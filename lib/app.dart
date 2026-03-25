import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';

import 'core/app_config.dart';
import 'services/app_update_service.dart';
import 'services/auth_session_manager.dart';
import 'ui/auth_screen.dart';
import 'ui/home_screen.dart';

class AsesoriaApp extends StatelessWidget {
  const AsesoriaApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5CB2FF),
      brightness: Brightness.dark,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'EasyExpert',
      locale: const Locale('es', 'ES'),
      supportedLocales: const [
        Locale('es', 'ES'),
        Locale('es'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFF0B0C10),
        fontFamily: 'Segoe UI',
      ),
      home: const _AppBootstrap(),
    );
  }
}

class _AppBootstrap extends StatefulWidget {
  const _AppBootstrap();

  @override
  State<_AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<_AppBootstrap> {
  late final Future<void> _initFuture;
  bool? _wasLoggedIn;

  @override
  void initState() {
    super.initState();
    _initFuture = AuthSessionManager.instance.bootstrap();
  }

  Future<void> _setLoginWindowSize() async {
    if (!Platform.isWindows) return;
    await windowManager.setMinimumSize(const Size(480, 620));
    await windowManager.setSize(const Size(480, 740));
    await windowManager.center();
  }

  Future<void> _checkForUpdate() async {
    debugPrint('[UPDATE] Checking for updates...');
    final update = await AppUpdateService.instance.checkForUpdate();
    debugPrint('[UPDATE] Result: ${update == null ? "no update" : "v${update.latestVersion} available"}');
    if (update == null || !mounted) return;

    final shouldUpdate = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Nueva versión disponible'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Versión actual: v${appVersion}'),
            Text('Nueva versión: v${update.latestVersion}'),
            if (update.releaseNotes.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Novedades:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: Text(
                    update.releaseNotes,
                    style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.7)),
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Más tarde'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Actualizar ahora'),
          ),
        ],
      ),
    );

    if (shouldUpdate == true) {
      await AppUpdateService.instance.downloadAndInstall(update.downloadUrl);
    }
  }

  Future<void> _setMainWindowSize() async {
    if (!Platform.isWindows) return;
    final flutterView =
        WidgetsBinding.instance.platformDispatcher.views.first;
    final screen =
        flutterView.physicalSize / flutterView.devicePixelRatio;
    await windowManager.setMinimumSize(const Size(900, 600));
    await windowManager.setSize(Size(screen.width, screen.height));
    await windowManager.center();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return ValueListenableBuilder(
          valueListenable: AuthSessionManager.instance.currentUser,
          builder: (context, user, _) {
            final loggedIn = user != null;
            if (_wasLoggedIn != loggedIn) {
              _wasLoggedIn = loggedIn;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (loggedIn) {
                  _setMainWindowSize();
                  _checkForUpdate();
                } else {
                  _setLoginWindowSize();
                }
              });
            }
            if (!loggedIn) return const AuthScreen();
            return const HomeScreen();
          },
        );
      },
    );
  }
}
