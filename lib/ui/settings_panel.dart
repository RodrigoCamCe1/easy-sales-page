import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/agent_profile.dart';
import '../services/agent_profile_store.dart';
import '../services/audio_device_utils.dart';
import '../services/audio_preferences_store.dart';

/// Embeddable settings panel — can be used inside a sidebar, overlay, etc.
/// No dependency on DesktopMultiWindow.
class SettingsPanel extends StatefulWidget {
  const SettingsPanel({
    super.key,
    required this.onClose,
    this.onPromptSaved,
  });

  final VoidCallback onClose;

  /// Called after the prompt is saved so the parent can reload the agent.
  final VoidCallback? onPromptSaved;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  late final TextEditingController _controller;
  List<AttachedFileRef> _attachedFiles = [];
  bool _isProcessingFile = false;
  String? _fileError;
  bool _loading = true;

  // Audio
  List<AudioDeviceInfo> _audioDevices = [];
  String? _selectedMicDeviceId;
  String _selectedSystemDeviceId = 'auto';
  bool _loadingDevices = false;

  // Agent info
  String _agentId = '';
  String _agentName = '';
  String _agentMode = '';
  bool _canEditPrompt = true;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _loadAgent();
    if (Platform.isWindows) _loadAudioDevices();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadAgent() async {
    final active = await AgentProfileStore.instance.getActiveAgent();
    if (!mounted) return;
    setState(() {
      _agentId = active.id;
      _agentName = active.name;
      _agentMode = active.mode;
      _canEditPrompt = active.canEditPrompt;
      _controller.text = active.prompt;
      _loading = false;
    });
    _loadAttachedFiles();
  }

  Future<void> _loadAudioDevices() async {
    setState(() => _loadingDevices = true);
    final store = AudioPreferencesStore.instance;
    _selectedMicDeviceId = store.micDeviceId;
    final rawSystemId = store.systemDeviceId;
    _selectedSystemDeviceId = (rawSystemId.isEmpty ||
            rawSystemId == 'Stereo Mix (Realtek(R) Audio)')
        ? 'auto'
        : rawSystemId;
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

  Future<void> _onSystemDeviceChanged(String? id) async {
    final store = AudioPreferencesStore.instance;
    setState(() => _selectedSystemDeviceId = id ?? 'auto');
    if (id == null || id == 'auto') {
      store.systemDevice = '';
      store.systemDeviceId = '';
    } else {
      final device = _audioDevices.firstWhere(
        (d) => d.deviceId == id,
        orElse: () => AudioDeviceInfo(name: id, altName: ''),
      );
      store.systemDevice = device.name;
      store.systemDeviceId = device.deviceId;
    }
    await store.save();
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
    try {
      final files = await AgentProfileStore.instance.listFilesForAgent(
        agentId: _agentId,
      );
      if (!mounted) return;
      if (files.isNotEmpty) {
        setState(() => _attachedFiles = files);
        return;
      }
    } catch (_) {}

    try {
      final config = await AgentProfileStore.instance.loadConfig();
      final agent =
          config.agents.where((a) => a.id == _agentId).firstOrNull;
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
        agentId: _agentId,
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
        agentId: _agentId,
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

  Future<void> _saveAll() async {
    // Save prompt if editable and changed
    if (_canEditPrompt) {
      final prompt = _controller.text.trim();
      if (prompt.isNotEmpty) {
        await AgentProfileStore.instance.updateAgentPrompt(
          agentId: _agentId,
          prompt: prompt,
        );
      }
    }
    // Audio config is saved immediately on change, so no extra save needed
    widget.onPromptSaved?.call();
    widget.onClose();
  }

  void _openMicPrivacySettings() {
    if (!Platform.isWindows) return;
    Process.start('cmd', ['/c', 'start', 'ms-settings:privacy-microphone']);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_loading) {
      return Container(
        color: cs.surface,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    return Container(
      color: cs.surface,
      child: Column(
        children: [
          // Header
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Colors.white.withValues(alpha: 0.1),
                ),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.settings_rounded, size: 18),
                const SizedBox(width: 8),
                const Text(
                  'Configuracion',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                const Spacer(),
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  tooltip: 'Cerrar',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          // Content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Audio devices ──
                  if (Platform.isWindows) ...[
                    if (_loadingDevices)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('Detectando dispositivos...'),
                          ],
                        ),
                      )
                    else ...[
                      const Text(
                        'Audio del sistema',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _buildSystemDropdown(),
                      const SizedBox(height: 12),
                      const Text(
                        'Microfono',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _buildMicDropdown(),
                    ],
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _openMicPrivacySettings,
                        icon: const Icon(Icons.settings, size: 14),
                        label: const Text(
                          'Permisos de microfono',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    Divider(color: Colors.white.withValues(alpha: 0.1)),
                  ],

                  // ── Prompt ──
                  const SizedBox(height: 8),
                  const Text(
                    'Prompt del sistema',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Agente: $_agentName ($_agentMode)',
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                  if (!_canEditPrompt) ...[
                    const SizedBox(height: 2),
                    const Text(
                      'Prompt bloqueado por el agente.',
                      style: TextStyle(fontSize: 11, color: Colors.amber),
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextField(
                    controller: _controller,
                    enabled: _canEditPrompt,
                    maxLines: 8,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Escribe el prompt para la IA...',
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                  ),

                  // ── Files ──
                  if (_canEditPrompt) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          'Archivos (${_attachedFiles.length})',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                        const Spacer(),
                        if (_isProcessingFile)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          IconButton(
                            onPressed: _pickAndAttachFile,
                            icon: const Icon(Icons.attach_file_rounded,
                                size: 18),
                            tooltip: 'Adjuntar (PDF, TXT, DOCX)',
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    if (_fileError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _fileError!,
                          style: TextStyle(
                            color: cs.error,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    for (final file in _attachedFiles)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Icon(_fileTypeIcon(file.fileType),
                                size: 16, color: Colors.white70),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                file.fileName,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            Text(
                              '${file.chunkCount} chunks',
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.white38),
                            ),
                            IconButton(
                              onPressed: () => _removeFile(file),
                              icon: const Icon(Icons.close_rounded, size: 14),
                              tooltip: 'Eliminar',
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      ),
                  ],

                  // ── Save button ──
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _saveAll,
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text(
                        'Guardar configuracion',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemDropdown() {
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(
        value: 'auto',
        child: Text('Automatico (detectar Stereo Mix)'),
      ),
      for (final d in _audioDevices)
        DropdownMenuItem(
          value: d.deviceId,
          child: Text(d.name, overflow: TextOverflow.ellipsis),
        ),
    ];

    final hasSelection = items.any((i) => i.value == _selectedSystemDeviceId);
    final effectiveValue = hasSelection ? _selectedSystemDeviceId : 'auto';

    return DropdownButtonFormField<String>(
      initialValue: effectiveValue,
      isExpanded: true,
      isDense: true,
      decoration: const InputDecoration(
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(),
      ),
      items: items,
      onChanged: _onSystemDeviceChanged,
    );
  }

  Widget _buildMicDropdown() {
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: '', child: Text('Ninguno (desactivar)')),
      for (final d in _audioDevices)
        DropdownMenuItem(
          value: d.deviceId,
          child: Text(d.name, overflow: TextOverflow.ellipsis),
        ),
    ];

    final hasSelection = items.any((i) => i.value == _selectedMicDeviceId);
    final effectiveValue = hasSelection ? _selectedMicDeviceId : '';

    return DropdownButtonFormField<String>(
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
          _onMicDeviceChanged(null);
          return;
        }
        final device = _audioDevices.firstWhere(
          (d) => d.deviceId == id,
          orElse: () => AudioDeviceInfo(name: id, altName: ''),
        );
        _onMicDeviceChanged(device);
      },
    );
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
}
