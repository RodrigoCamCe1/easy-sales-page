import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../models/agent_profile.dart';
import '../services/agent_profile_store.dart';
import '../services/audio_device_utils.dart';
import '../services/audio_preferences_store.dart';

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
  List<AttachedFileRef> _attachedFiles = [];
  bool _isProcessingFile = false;
  String? _fileError;

  // Audio device selection (mic only — system audio uses WASAPI loopback auto)
  List<AudioDeviceInfo> _audioDevices = [];
  String? _selectedMicDeviceId;
  bool _loadingDevices = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _configureFramelessWindow();
    });
    _controller = TextEditingController(text: widget.initialPrompt);
    _loadAttachedFiles();
    if (Platform.isWindows) _loadAudioDevices();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadAudioDevices() async {
    setState(() => _loadingDevices = true);
    final store = AudioPreferencesStore.instance;
    _selectedMicDeviceId = store.micDeviceId;
    final devices = await enumerateAudioDevices();
    if (!mounted) return;
    setState(() {
      _audioDevices = devices;
      if (_selectedMicDeviceId != null &&
          _selectedMicDeviceId!.isNotEmpty &&
          !_audioDevices.any((d) => d.deviceId == _selectedMicDeviceId)) {
        _audioDevices.insert(
          0,
          AudioDeviceInfo(
            name: store.micDevice,
            altName: store.micDeviceId,
          ),
        );
      }
      _loadingDevices = false;
    });
  }

  Future<void> _onMicDeviceChanged(AudioDeviceInfo? device) async {
    final store = AudioPreferencesStore.instance;
    if (device == null) {
      setState(() => _selectedMicDeviceId = '');
      store.micDevice = '';
      store.micDeviceId = '';
    } else {
      setState(() => _selectedMicDeviceId = device.deviceId);
      store.micDevice = device.name;
      store.micDeviceId = device.deviceId;
    }
    await store.save();
  }

  Future<void> _loadAttachedFiles() async {
    // Try backend first
    try {
      final files = await AgentProfileStore.instance.listFilesForAgent(
        agentId: widget.agentId,
      );
      if (!mounted) return;
      if (files.isNotEmpty) {
        setState(() => _attachedFiles = files);
        return;
      }
    } catch (_) {}

    // Fallback: load from local config (always in sync after uploads)
    try {
      final config = await AgentProfileStore.instance.loadConfig();
      final agent = config.agents
          .where((a) => a.id == widget.agentId)
          .firstOrNull;
      if (!mounted) return;
      setState(() => _attachedFiles = agent?.attachedFiles ?? []);
    } catch (_) {}
  }

  Future<void> _pickAndAttachFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'txt', 'docx'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;

    setState(() {
      _isProcessingFile = true;
      _fileError = null;
    });
    try {
      final ref = await AgentProfileStore.instance.addFileToAgent(
        agentId: widget.agentId,
        filePath: path,
      );
      if (!mounted) return;
      setState(() {
        _attachedFiles = [..._attachedFiles, ref];
        _isProcessingFile = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessingFile = false;
        _fileError = e.toString();
      });
    }
  }

  Future<void> _removeFile(AttachedFileRef file) async {
    try {
      await AgentProfileStore.instance.removeFileFromAgent(
        agentId: widget.agentId,
        fileId: file.id,
      );
      if (!mounted) return;
      setState(() {
        _attachedFiles =
            _attachedFiles.where((f) => f.id != file.id).toList();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _fileError = e.toString());
    }
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
                    if (Platform.isWindows) ...[
                      if (_loadingDevices)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                              SizedBox(width: 8),
                              Text('Detectando dispositivos de audio...'),
                            ],
                          ),
                        )
                      else ...[
                        _AudioDeviceDropdown(
                          label: 'Microfono',
                          selectedDeviceId: _selectedMicDeviceId,
                          devices: _audioDevices,
                          allowNone: true,
                          onChanged: _onMicDeviceChanged,
                        ),
                      ],
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: _openMicPrivacySettings,
                          icon: const Icon(Icons.settings, size: 16),
                          label: const Text('Permisos de microfono'),
                        ),
                      ),
                    ] else
                      const Text(
                        'La captura de audio del sistema requiere un dispositivo virtual '
                        'como VB-Audio/BlackHole.',
                      ),
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
                    if (widget.canEditPrompt) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text(
                            'Archivos adjuntos (${_attachedFiles.length})',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          const Spacer(),
                          if (_isProcessingFile)
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          else
                            IconButton(
                              onPressed: _pickAndAttachFile,
                              icon: const Icon(Icons.attach_file_rounded),
                              tooltip: 'Adjuntar archivo (PDF, TXT, DOCX)',
                            ),
                        ],
                      ),
                      if (_fileError != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          _fileError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      for (final file in _attachedFiles)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              Icon(
                                _fileTypeIcon(file.fileType),
                                size: 18,
                                color: Colors.white70,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  file.fileName,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              Text(
                                '${file.chunkCount} chunks',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white.withValues(alpha: 0.5),
                                ),
                              ),
                              IconButton(
                                onPressed: () => _removeFile(file),
                                icon: const Icon(
                                  Icons.close_rounded,
                                  size: 16,
                                ),
                                tooltip: 'Eliminar archivo',
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ),
                        ),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: widget.canEditPrompt ? _savePrompt : null,
                        child: Text(
                          widget.canEditPrompt
                              ? 'Guardar configuración'
                              : 'Configuración bloqueada',
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

IconData _fileTypeIcon(String fileType) {
  switch (fileType.toLowerCase()) {
    case 'pdf':
      return Icons.picture_as_pdf_rounded;
    case 'docx':
      return Icons.description_rounded;
    case 'txt':
      return Icons.text_snippet_rounded;
    default:
      return Icons.insert_drive_file_rounded;
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

class _AudioDeviceDropdown extends StatelessWidget {
  const _AudioDeviceDropdown({
    required this.label,
    required this.selectedDeviceId,
    required this.devices,
    required this.onChanged,
    this.allowNone = false,
  });

  final String label;
  final String? selectedDeviceId;
  final List<AudioDeviceInfo> devices;
  final ValueChanged<AudioDeviceInfo?> onChanged;
  final bool allowNone;

  @override
  Widget build(BuildContext context) {
    // Use deviceId as the dropdown value for stable matching
    final items = <DropdownMenuItem<String>>[
      if (allowNone)
        const DropdownMenuItem(value: '', child: Text('Ninguno (desactivar)')),
      for (final d in devices)
        DropdownMenuItem(
          value: d.deviceId,
          child: Text(d.name, overflow: TextOverflow.ellipsis),
        ),
    ];

    // Ensure the current value exists in items
    final hasSelection =
        items.any((i) => i.value == selectedDeviceId);
    final effectiveValue =
        hasSelection ? selectedDeviceId : (allowNone ? '' : null);

    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(label, style: const TextStyle(fontSize: 13)),
        ),
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: effectiveValue,
            isExpanded: true,
            isDense: true,
            decoration: const InputDecoration(
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(),
            ),
            items: items,
            onChanged: (id) {
              if (id == null || id.isEmpty) {
                onChanged(null);
                return;
              }
              final device = devices.firstWhere(
                (d) => d.deviceId == id,
                orElse: () => AudioDeviceInfo(name: id, altName: ''),
              );
              onChanged(device);
            },
          ),
        ),
      ],
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
