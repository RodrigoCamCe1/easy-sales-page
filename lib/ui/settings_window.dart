import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';

import '../core/app_config.dart';

class SettingsWindowApp extends StatelessWidget {
  const SettingsWindowApp({
    super.key,
    required this.windowId,
    required this.mainWindowId,
    required this.initialPrompt,
  });

  final int windowId;
  final int mainWindowId;
  final String initialPrompt;

  @override
  Widget build(BuildContext context) {
    const brightness = Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: brightness,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Configuracion',
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        brightness: brightness,
      ),
      home: SettingsWindowPage(
        windowId: windowId,
        mainWindowId: mainWindowId,
        initialPrompt: initialPrompt,
      ),
    );
  }
}

class SettingsWindowPage extends StatefulWidget {
  const SettingsWindowPage({
    super.key,
    required this.windowId,
    required this.mainWindowId,
    required this.initialPrompt,
  });

  final int windowId;
  final int mainWindowId;
  final String initialPrompt;

  @override
  State<SettingsWindowPage> createState() => _SettingsWindowPageState();
}

class _SettingsWindowPageState extends State<SettingsWindowPage> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialPrompt);
    _loadPromptFromFile();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _savePrompt() async {
    final prompt = _controller.text.trim();
    if (prompt.isNotEmpty) {
      await promptFile.writeAsString(prompt);
    }
    final targetIds = <int>{
      widget.mainWindowId,
      0,
      1,
    };
    for (final id in targetIds) {
      if (id == widget.windowId) continue;
      try {
        await DesktopMultiWindow.invokeMethod(
          id,
          'updatePrompt',
          {'prompt': prompt},
        );
      } catch (_) {
        // Best-effort broadcast to the main window.
      }
    }
  }

  void _openMicPrivacySettings() {
    if (!Platform.isWindows) return;
    Process.start('cmd', ['/c', 'start', 'ms-settings:privacy-microphone']);
  }

  Future<void> _setMicMix(bool enabled) async {
    try {
      await DesktopMultiWindow.invokeMethod(
        widget.mainWindowId,
        'setMicMix',
        {'enabled': enabled},
      );
    } catch (_) {
      // Best-effort control of main window capture.
    }
  }

  Future<void> _loadPromptFromFile() async {
    if (!await promptFile.exists()) return;
    final content = (await promptFile.readAsString()).trim();
    if (content.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _controller.text = content;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuracion'),
        actions: [
          if (Platform.isWindows)
            TextButton(
              onPressed: _openMicPrivacySettings,
              child: const Text('Mic Windows'),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Aqui puedes seleccionar la fuente de audio (por ejemplo, un dispositivo loopback) '
              'y la carpeta de salida. La captura de audio del sistema requiere integrar un '
              'plugin nativo o usar un dispositivo virtual como VB-Audio/BlackHole. '
              'En Windows puedes definir WINDOWS_MIC_DEVICE para mezclar microfono.',
            ),
            if (Platform.isWindows) ...[
              const SizedBox(height: 16),
              const Text('Modo de escucha'),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: () => _setMicMix(false),
                    child: const Text('Solo PC'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => _setMicMix(true),
                    child: const Text('PC + Mic'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            Text(
              'Prompt del sistema',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Escribe aqui el prompt que guia las respuestas de la IA.',
            ),
            const SizedBox(height: 10),
            Expanded(
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Escribe el prompt para la IA...',
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _savePrompt,
                child: const Text('Guardar prompt'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
