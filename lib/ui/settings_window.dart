import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../services/agent_profile_store.dart';

class SettingsWindowApp extends StatelessWidget {
  const SettingsWindowApp({
    super.key,
    required this.windowId,
    required this.mainWindowId,
    required this.initialPrompt,
    required this.agentId,
    required this.agentName,
    required this.agentMode,
    required this.canEditPrompt,
  });

  final int windowId;
  final int mainWindowId;
  final String initialPrompt;
  final String agentId;
  final String agentName;
  final String agentMode;
  final bool canEditPrompt;

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
        agentId: agentId,
        agentName: agentName,
        agentMode: agentMode,
        canEditPrompt: canEditPrompt,
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
    required this.agentId,
    required this.agentName,
    required this.agentMode,
    required this.canEditPrompt,
  });

  final int windowId;
  final int mainWindowId;
  final String initialPrompt;
  final String agentId;
  final String agentName;
  final String agentMode;
  final bool canEditPrompt;

  @override
  State<SettingsWindowPage> createState() => _SettingsWindowPageState();
}

class _SettingsWindowPageState extends State<SettingsWindowPage> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _configureFramelessWindow();
    });
    _controller = TextEditingController(text: widget.initialPrompt);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _savePrompt() async {
    if (!widget.canEditPrompt) {
      await _closeWindow();
      return;
    }

    final prompt = _controller.text.trim();
    if (prompt.isEmpty) return;
    final updatedConfig = await AgentProfileStore.instance.updateAgentPrompt(
      agentId: widget.agentId,
      prompt: prompt,
    );
    var updatedAgent = updatedConfig.activeAgent;
    for (final agent in updatedConfig.agents) {
      if (agent.id == widget.agentId) {
        updatedAgent = agent;
        break;
      }
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
          {
            'agentId': widget.agentId,
            'prompt': updatedAgent?.composedPrompt ?? prompt,
            'agentName': widget.agentName,
            'agentMode': widget.agentMode,
            'canEditPrompt': widget.canEditPrompt,
          },
        );
      } catch (_) {
        // Best-effort broadcast to the main window.
      }
    }

    await _closeWindow();
  }

  Future<void> _closeWindow() async {
    try {
      await WindowController.fromWindowId(widget.windowId).close();
    } catch (_) {
      if (mounted) {
        Navigator.of(context).maybePop();
      }
    }
  }

  void _openMicPrivacySettings() {
    if (!Platform.isWindows) return;
    Process.start('cmd', ['/c', 'start', 'ms-settings:privacy-microphone']);
  }

  Future<void> _configureFramelessWindow() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        await windowManager.ensureInitialized();
        await windowManager.setAsFrameless();
        return;
      } catch (error) {
        if (attempt == 3) {
          debugPrint('Settings frameless setup failed: $error');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _SettingsTitleBar(
              title: 'Configuracion',
              onClose: () async => windowManager.close(),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Aqui puedes seleccionar la fuente de audio (por ejemplo, un dispositivo loopback) '
                      'y la carpeta de salida. La captura de audio del sistema requiere integrar un '
                      'plugin nativo o usar un dispositivo virtual como VB-Audio/BlackHole.',
                    ),
                    if (Platform.isWindows) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Modo de escucha fijo: Chat/sugerencias: sistema | Transcripcion: sistema + microfono',
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: _openMicPrivacySettings,
                            child: const Text('Mic Windows'),
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
                    Text(
                      'Agente activo: ${widget.agentName} (${widget.agentMode})',
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.canEditPrompt
                          ? 'Este agente permite editar el prompt.'
                          : 'Este agente usa prompt bloqueado y no se puede editar.',
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        enabled: widget.canEditPrompt,
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
                        onPressed: widget.canEditPrompt ? _savePrompt : null,
                        child: Text(
                          widget.canEditPrompt
                              ? 'Guardar prompt'
                              : 'Prompt bloqueado',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsTitleBar extends StatelessWidget {
  const _SettingsTitleBar({
    required this.title,
    required this.onClose,
  });

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          _SettingsWindowButton(
            icon: Icons.remove_rounded,
            tooltip: 'Minimizar',
            onPressed: () async => windowManager.minimize(),
          ),
          _SettingsWindowButton(
            icon: Icons.crop_square_rounded,
            tooltip: 'Maximizar',
            onPressed: () async {
              final isMaximized = await windowManager.isMaximized();
              if (isMaximized) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
          ),
          _SettingsWindowButton(
            icon: Icons.close_rounded,
            tooltip: 'Cerrar',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _SettingsWindowButton extends StatelessWidget {
  const _SettingsWindowButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 32,
      child: IconButton(
        iconSize: 16,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
        tooltip: tooltip,
        icon: Icon(icon),
      ),
    );
  }
}
