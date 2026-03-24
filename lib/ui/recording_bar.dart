import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_config.dart';
import '../services/window_capture_utils.dart' as capture;
import '../models/session_models.dart';
import '../services/agent_profile_store.dart';
import '../services/recording_session_controller.dart';
import 'settings_panel.dart';

class RecordingBarApp extends StatelessWidget {
  const RecordingBarApp({super.key});

  @override
  Widget build(BuildContext context) {
    const brightness = Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: brightness,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'EasyExpert Audio Bar',
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        brightness: brightness,
        scaffoldBackgroundColor: Colors.transparent,
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: const RecordingBar(),
    );
  }
}

class RecordingBar extends StatefulWidget {
  const RecordingBar({super.key});

  @override
  State<RecordingBar> createState() => _RecordingBarState();
}

class _RecordingBarState extends State<RecordingBar> {
  // ── UI-only state ──────────────────────────────────────────────────────────
  bool _showTranscript = false;
  bool _showDebugLogs = false;
  bool _suggestionsSidebarOpen = true;
  bool _invisibleMode = false;
  bool _settingsPanelOpen = false;

  // ── Scroll / input controllers ─────────────────────────────────────────────
  final ScrollController _chatScrollController = ScrollController();
  final ScrollController _suggestionScrollController = ScrollController();
  final ScrollController _transcriptScrollController = ScrollController();
  final TextEditingController _manualPromptController = TextEditingController();

  // ── Platform audio (FlutterAudioCapture must remain in the widget) ─────────
  final FlutterAudioCapture _audioCapture = FlutterAudioCapture();

  // ── Session controller ─────────────────────────────────────────────────────
  late final RecordingSessionController _controller;

  // ── Platform helpers ───────────────────────────────────────────────────────
  bool get _windowsMicAvailable =>
      Platform.isWindows && windowsMicDevice.trim().isNotEmpty;
  bool get _audioSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isLinux;

  void _addLog(String entry) {
    debugPrint('[${DateTime.now().toIso8601String()}] $entry');
  }

  void _scrollToBottom(ScrollController ctrl) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!ctrl.hasClients) return;
      final pos = ctrl.position;
      final distanceFromBottom = pos.maxScrollExtent - pos.pixels;
      // Solo auto-scroll si el usuario está cerca del fondo (< 50px)
      if (distanceFromBottom > 100) return;
      ctrl.animateTo(
        pos.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _toggleTranscript() {
    setState(() => _showTranscript = !_showTranscript);
  }

  void _toggleSuggestions() {
    setState(() => _suggestionsSidebarOpen = !_suggestionsSidebarOpen);
  }

  Future<void> _loadActiveAgent() async {
    final active = await AgentProfileStore.instance.getActiveAgent();
    if (!mounted) return;
    _controller.promptOverride = active.composedPrompt;
    _controller.activeAgentId = active.id;
    _controller.applyUpdatedPrompt();
    _addLog('Agente activo: ${active.name} (${active.mode})');
  }

  @override
  void initState() {
    super.initState();

    _controller = RecordingSessionController();
    _controller.micMixEnabled = _windowsMicAvailable;
    _controller.promptOverride = systemPrompt;
    _controller.onScrollChatToBottom =
        () => _scrollToBottom(_chatScrollController);
    _controller.onScrollTranscriptToBottom =
        () => _scrollToBottom(_transcriptScrollController);
    _controller.onScrollSuggestionsToBottom =
        () => _scrollToBottom(_suggestionScrollController);
    _controller.onRequestStartPlatformCapture = _startPlatformCapture;
    _controller.onRequestStopPlatformCapture = () async {
      await _audioCapture.stop();
    };
    _controller.onNoLoopbackDeviceFound = _showStereoMixGuide;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _configureFramelessWindow();
    });

    _loadActiveAgent();
    _notifyBarOpened();

    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      if (call.method == 'updatePrompt') {
        final args = call.arguments as Map?;
        final prompt = args?['prompt'] as String? ?? '';
        final agentId = args?['agentId'] as String? ?? '';
        _controller.promptOverride =
            prompt.isEmpty ? systemPrompt : prompt;
        _controller.activeAgentId = agentId;
        _controller.applyUpdatedPrompt();
      }

      if (call.method == 'setMicMix') {
        await _controller.setMicMixEnabled(_windowsMicAvailable);
      }

      return null;
    });
  }

  Future<void> _startPlatformCapture() async {
    if (!_audioSupported) return;
    try {
      final initialized = await _audioCapture.init();
      if (initialized != true) {
        throw Exception('FlutterAudioCapture failed to init');
      }
      await _audioCapture.start(
        (data) {
          final floats =
              (data as Iterable).cast<double>().toList(growable: false);
          _controller.appendMicAudioFromPlatform(floats);
        },
        (error) {
          _controller.onPlatformCaptureError?.call(error.toString());
        },
        sampleRate: 16000,
        bufferSize: 3000,
      );
    } catch (error) {
      _controller.onPlatformCaptureError?.call(error.toString());
    }
  }

  Future<void> _configureFramelessWindow() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        await windowManager.ensureInitialized();
        await windowManager.setBackgroundColor(Colors.transparent);
        await windowManager.setAsFrameless();
        await windowManager.setAlwaysOnTop(true);
        return;
      } catch (error) {
        if (attempt == 3) {
          debugPrint('RecordingBar frameless setup failed: $error');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
  }

  Future<void> _notifyBarOpened() async {
    try {
      await DesktopMultiWindow.invokeMethod(0, 'barOpened');
    } catch (_) {}
  }

  Future<void> _requestMainAction(String action) async {
    try {
      await DesktopMultiWindow.invokeMethod(0, action);
    } catch (_) {}
  }

  Future<void> _startListening() async {
    await _loadActiveAgent();
    await _controller.startListening();
  }

  Future<void> _stopListening() async {
    await _controller.stopListening();
  }

  Future<void> _sendManualPrompt() async {
    final prompt = _manualPromptController.text.trim();
    if (prompt.isEmpty) return;
    _manualPromptController.clear();
    await _controller.sendManualPrompt(prompt);
  }

  void _toggleSettings() {
    setState(() => _settingsPanelOpen = !_settingsPanelOpen);
  }

  void _showStereoMixGuide() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => const _StereoMixGuideDialog(),
    );
  }

  @override
  void dispose() {
    _controller.onScrollChatToBottom = null;
    _controller.onScrollTranscriptToBottom = null;
    _controller.onScrollSuggestionsToBottom = null;
    _controller.onRequestStartPlatformCapture = null;
    _controller.onRequestStopPlatformCapture = null;
    _controller.onPlatformCaptureError = null;
    _controller.onNoLoopbackDeviceFound = null;
    _controller.dispose();
    _chatScrollController.dispose();
    _suggestionScrollController.dispose();
    _transcriptScrollController.dispose();
    _manualPromptController.dispose();
    _audioCapture.stop();
    _requestMainAction('barClosed');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    Widget navIconButton(
        IconData icon, String tooltip, VoidCallback? onPressed) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colorScheme.primary.withOpacity(0.2),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          splashRadius: 20,
          padding: EdgeInsets.zero,
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon, size: 20),
          color: colorScheme.onPrimary,
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SizedBox.expand(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // ── Settings panel (left side) ──
                if (_settingsPanelOpen)
                  Container(
                    width: 320,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      borderRadius: const BorderRadius.all(Radius.circular(18)),
                      border: Border.all(
                        color: colorScheme.outlineVariant.withOpacity(0.68),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: SettingsPanel(
                      onClose: _toggleSettings,
                      onPromptSaved: _loadActiveAgent,
                    ),
                  ),
                // ── Main bar ──
                Expanded(
                  child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: barHeight),
              decoration: BoxDecoration(
                color: colorScheme.surface.withOpacity(0.42),
                gradient: LinearGradient(
                  colors: [
                    colorScheme.surfaceVariant.withOpacity(0.62),
                    colorScheme.surface.withOpacity(0.76),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: const BorderRadius.all(Radius.circular(18)),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 38,
                    spreadRadius: -10,
                    offset: Offset(0, 16),
                  ),
                ],
                border: Border.all(
                  color: colorScheme.outlineVariant.withOpacity(0.68),
                ),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isCompact = constraints.maxHeight < 275;
                    final suggestionsWidth = math.min(
                      300.0,
                      constraints.maxWidth * 0.35,
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Row(
                              children: [
                                navIconButton(
                                  Icons.play_arrow_rounded,
                                  'Iniciar',
                                  _controller.listening ? null : _startListening,
                                ),
                                const SizedBox(width: 8),
                                navIconButton(
                                  Icons.stop_rounded,
                                  'Detener',
                                  _controller.listening ? _stopListening : null,
                                ),
                                const SizedBox(width: 8),
                                navIconButton(
                                  Icons.settings_rounded,
                                  'Configurar',
                                  _toggleSettings,
                                ),
                              ],
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: DragToMoveArea(
                                child: Container(
                                  height: 28,
                                  alignment: Alignment.centerLeft,
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 8),
                                  child: Text(
                                    'EasyExpert $appVersion',
                                    style: textTheme.labelSmall?.copyWith(
                                      color: colorScheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Row(
                              children: [
                                IconButton(
                                  padding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => windowManager.minimize(),
                                  icon: const Icon(Icons.remove_rounded),
                                  tooltip: 'Minimizar',
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  padding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () =>
                                      _requestMainAction('barCloseRequested'),
                                  icon: const Icon(Icons.close_rounded),
                                  tooltip: 'Cerrar',
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Divider(height: 0),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              _controller.listening
                                  ? (_controller.micMixEnabled &&
                                          _windowsMicAvailable
                                      ? 'Escuchando sistema y microfono'
                                      : (Platform.isWindows
                                          ? 'Escuchando audio del sistema'
                                          : 'Escuchando microfono'))
                                  : 'Listo para escuchar',
                              style: textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _controller.listening
                                  ? '${_controller.elapsed.inMinutes.toString().padLeft(2, '0')}:${(_controller.elapsed.inSeconds % 60).toString().padLeft(2, '0')}'
                                  : 'En espera',
                              style: textTheme.labelMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (!isCompact) ...[
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 30,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: [
                                _QuickChip(
                                  label: _suggestionsSidebarOpen
                                      ? 'Ocultar sugerencias'
                                      : 'Mostrar sugerencias',
                                  icon: Icons.lightbulb_outline_rounded,
                                  onTap: _toggleSuggestions,
                                ),
                                _QuickChip(
                                  label: _showTranscript
                                      ? 'Volver'
                                      : 'Transcripcion',
                                  icon: Icons.mic_rounded,
                                  onTap: _toggleTranscript,
                                ),
                                _QuickChip(
                                  label: _controller.freestyleMode
                                      ? 'Modo libre ON'
                                      : 'Modo libre',
                                  icon: Icons.auto_fix_high_rounded,
                                  onTap: _controller.toggleFreestyleMode,
                                  activeColor: const Color(0xFFE53935),
                                  isActive: _controller.freestyleMode,
                                ),
                                _QuickChip(
                                  label: _invisibleMode
                                      ? 'Visible'
                                      : 'Invisible',
                                  icon: _invisibleMode
                                      ? Icons.visibility_off_rounded
                                      : Icons.visibility_rounded,
                                  onTap: () {
                                    setState(() {
                                      _invisibleMode = !_invisibleMode;
                                    });
                                    capture.setInvisibleMode(_invisibleMode);
                                  },
                                  activeColor: const Color(0xFF5CB2FF),
                                  isActive: _invisibleMode,
                                ),
                                _QuickChip(
                                  label: _showDebugLogs ? 'Ocultar logs' : 'Logs',
                                  icon: Icons.bug_report_rounded,
                                  onTap: () {
                                    setState(() {
                                      _showDebugLogs = !_showDebugLogs;
                                    });
                                  },
                                  activeColor: const Color(0xFFFF9800),
                                  isActive: _showDebugLogs,
                                ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Container(
                          constraints: const BoxConstraints(minHeight: 34),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceVariant.withOpacity(0.58),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color:
                                  colorScheme.outlineVariant.withOpacity(0.72),
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _manualPromptController,
                                  onSubmitted: (_) => _sendManualPrompt(),
                                  decoration: InputDecoration(
                                    border: InputBorder.none,
                                    hintText:
                                        'Pregunta sobre lo que quieras, sobre la conversación o alguna duda.',
                                    hintStyle: textTheme.bodySmall?.copyWith(
                                      color: colorScheme.onSurface
                                          .withOpacity(0.78),
                                    ),
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                        vertical: 10),
                                  ),
                                  style: textTheme.bodyMedium,
                                ),
                              ),
                              GestureDetector(
                                onTap: _sendManualPrompt,
                                child: Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: colorScheme.primary,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.send_rounded,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Divider(
                          height: 1,
                          color: colorScheme.outlineVariant.withOpacity(0.25),
                        ),
                        const SizedBox(height: 6),
                        Expanded(
                          child: Row(
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOut,
                                width: _suggestionsSidebarOpen
                                    ? suggestionsWidth
                                    : 0,
                                child: _suggestionsSidebarOpen
                                    ? _SuggestionsSidebar(
                                        controller: _suggestionScrollController,
                                        suggestions: _controller.suggestions,
                                        onClose: _toggleSuggestions,
                                      )
                                    : const SizedBox.shrink(),
                              ),
                              Expanded(
                                child: _showDebugLogs
                                    ? _DebugLogsPane(
                                        logs: _controller.debugLogs,
                                      )
                                    : _showTranscript
                                        ? _TranscriptionPane(
                                            controller:
                                                _transcriptScrollController,
                                            entries: _controller
                                                .buildTranscriptEntries(),
                                            emptyText:
                                                'Esperando audio para transcribir',
                                          )
                                        : _ChatPane(
                                            controller: _chatScrollController,
                                            messages:
                                                _controller.chatResponses,
                                            emptyText:
                                                _controller.statusMessage,
                                            isThinking:
                                                _controller.responseInFlight,
                                          ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
                ), // end Expanded (main bar)
              ],
            ), // end Row (settings + main bar)
          ),
        ),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({
    required this.label,
    required this.icon,
    this.onTap,
    this.activeColor,
    this.isActive = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final Color? activeColor;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final effectiveColor = isActive && activeColor != null ? activeColor! : null;
    final chip = Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: effectiveColor != null
            ? effectiveColor.withOpacity(0.15)
            : colorScheme.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: effectiveColor != null
              ? effectiveColor.withOpacity(0.7)
              : colorScheme.outlineVariant.withOpacity(0.6),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14,
              color: effectiveColor ?? colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: effectiveColor ?? colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );

    if (onTap == null) return chip;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: chip,
    );
  }
}

class _TranscriptionPane extends StatelessWidget {
  const _TranscriptionPane({
    required this.controller,
    required this.entries,
    required this.emptyText,
  });

  final ScrollController controller;
  final List<TranscriptEntry> entries;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (entries.isEmpty) {
      return SingleChildScrollView(
        controller: controller,
        physics: const ClampingScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            emptyText,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface,
                ),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: controller,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final item = entries[index];
        final isMic = item.isMic;
        return Align(
          alignment: isMic ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            constraints: const BoxConstraints(maxWidth: 560),
            decoration: BoxDecoration(
              color: isMic
                  ? colorScheme.primary.withOpacity(0.35)
                  : colorScheme.surfaceVariant.withOpacity(0.54),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(14),
                topRight: const Radius.circular(14),
                bottomLeft:
                    Radius.circular(isMic ? 14 : (item.pending ? 6 : 14)),
                bottomRight:
                    Radius.circular(isMic ? (item.pending ? 6 : 14) : 14),
              ),
              border: Border.all(
                color: colorScheme.outlineVariant.withOpacity(0.52),
              ),
            ),
            child: Text(
              _fixMojibake(item.text),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                    fontStyle: item.pending ? FontStyle.italic : null,
                  ),
            ),
          ),
        );
      },
    );
  }
}

class _SuggestionsSidebar extends StatelessWidget {
  const _SuggestionsSidebar({
    required this.controller,
    required this.suggestions,
    required this.onClose,
  });

  final ScrollController controller;
  final List<String> suggestions;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceVariant.withOpacity(0.4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: colorScheme.outlineVariant.withOpacity(0.56),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.lightbulb_outline_rounded,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sugerencias',
                  style: textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Cerrar sugerencias',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Divider(
            height: 1,
            color: colorScheme.outlineVariant.withOpacity(0.25),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _SuggestionsListPane(
              controller: controller,
              suggestions: suggestions,
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionsListPane extends StatelessWidget {
  const _SuggestionsListPane({
    required this.controller,
    required this.suggestions,
  });

  final ScrollController controller;
  final List<String> suggestions;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (suggestions.isEmpty) {
      return SingleChildScrollView(
        controller: controller,
        physics: const ClampingScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            _fixMojibake(
              'Aún no hay sugerencias.\nHabla o envía un prompt manual para generar preguntas.',
            ),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface,
                ),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: controller,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.only(top: 2, bottom: 10),
      itemCount: suggestions.length,
      itemBuilder: (context, index) {
        final s = suggestions[index].trim();
        if (s.isEmpty) return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: colorScheme.surface.withOpacity(0.34),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: colorScheme.outlineVariant.withOpacity(0.48),
            ),
          ),
          child: Text(
            _fixMojibake('• $s'),
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface,
                ),
          ),
        );
      },
    );
  }
}

// =======================
// ✅ Chat: UI
// =======================

class _ChatPane extends StatelessWidget {
  // Turn-aware chat styling is handled in this widget.
  const _ChatPane({
    required this.controller,
    required this.messages,
    required this.emptyText,
    required this.isThinking,
  });

  final ScrollController controller;
  final List<ChatMessage> messages;
  final String emptyText;
  final bool isThinking;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final hasAnything = messages.isNotEmpty || isThinking;
    if (!hasAnything) {
      return _TranscriptionPane(
        controller: controller,
        entries: const [],
        emptyText: emptyText,
      );
    }

    final itemCount = messages.length + (isThinking ? 1 : 0);
    final assistantTurnIds = messages
        .where((m) => m.role == 'assistant' && m.assistantTurnId != null)
        .map((m) => m.assistantTurnId!)
        .toSet()
        .toList()
      ..sort();
    final latestAssistantTurnId =
        assistantTurnIds.isNotEmpty ? assistantTurnIds.last : null;
    final previousAssistantTurnId = assistantTurnIds.length > 1
        ? assistantTurnIds[assistantTurnIds.length - 2]
        : null;

    return ListView.builder(
      controller: controller,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        final isThinkingRow = isThinking && index == itemCount - 1;

        final role = isThinkingRow ? 'assistant' : messages[index].role;
        final text = isThinkingRow
            ? 'Asistente está pensando...'
            : messages[index].text.trim();

        final isAssistant = role == 'assistant';
        final currentAssistantTurnId = isThinkingRow
            ? latestAssistantTurnId
            : messages[index].assistantTurnId;
        final isFreestyle = !isThinkingRow && messages[index].isFreestyle;
        const freestyleRed = Color(0xFFE53935);

        return Align(
          alignment: isAssistant ? Alignment.centerLeft : Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            constraints: const BoxConstraints(maxWidth: 560),
            decoration: BoxDecoration(
              color: isFreestyle
                  ? freestyleRed.withOpacity(0.12)
                  : isAssistant
                      ? ((latestAssistantTurnId != null &&
                              currentAssistantTurnId == latestAssistantTurnId)
                          ? colorScheme.primary.withOpacity(0.4)
                          : (previousAssistantTurnId != null &&
                                  currentAssistantTurnId ==
                                      previousAssistantTurnId)
                              ? colorScheme.primary.withOpacity(0.24)
                              : colorScheme.surfaceVariant.withOpacity(0.56))
                      : colorScheme.primary.withOpacity(0.36),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isFreestyle
                    ? freestyleRed.withOpacity(0.6)
                    : colorScheme.outlineVariant.withOpacity(0.54),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isFreestyle)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.auto_fix_high_rounded,
                            size: 11, color: freestyleRed.withOpacity(0.8)),
                        const SizedBox(width: 4),
                        Text(
                          'Modo libre · puede contener info no verificada',
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: freestyleRed.withOpacity(0.8),
                                    fontSize: 10,
                                  ),
                        ),
                      ],
                    ),
                  ),
                Text(
                  _fixMojibake(text),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurface,
                        fontStyle:
                            isThinkingRow ? FontStyle.italic : FontStyle.normal,
                      ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

String _fixMojibake(String input) {
  if (input.isEmpty) return input;
  if (!RegExp(r'[ÃÂâð]').hasMatch(input)) return input;

  try {
    final fixed = utf8.decode(latin1.encode(input), allowMalformed: true);
    if (fixed.isNotEmpty) return fixed;
  } catch (_) {}
  return input;
}

// ── Stereo Mix setup guide dialog ───────────────────────────────────────────

class _StereoMixGuideDialog extends StatelessWidget {
  const _StereoMixGuideDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF111827),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.surround_sound_rounded,
                size: 48,
                color: Color(0xFF5CB2FF),
              ),
              const SizedBox(height: 12),
              const Text(
                'Habilitar audio del sistema',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'EasyExpert necesita "Stereo Mix" para escuchar el audio de tu PC. '
                'Sigue estos pasos para activarlo:',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.65),
                ),
              ),
              const SizedBox(height: 20),
              const _GuideStep(
                number: 1,
                icon: Icons.volume_up_rounded,
                title: 'Abrir configuracion de sonido',
                description:
                    'Click derecho en el icono de parlante en la barra de tareas → '
                    '"Configuracion de sonido"',
              ),
              const SizedBox(height: 12),
              const _GuideStep(
                number: 2,
                icon: Icons.tune_rounded,
                title: 'Mas opciones de sonido',
                description:
                    'Baja hasta el final y haz click en '
                    '"Mas opciones de sonido" o "Panel de control de sonido"',
              ),
              const SizedBox(height: 12),
              const _GuideStep(
                number: 3,
                icon: Icons.mic_external_on_rounded,
                title: 'Pestana "Grabacion"',
                description:
                    'Ve a la pestana "Grabacion", click derecho en el area vacia '
                    'y marca "Mostrar dispositivos deshabilitados"',
              ),
              const SizedBox(height: 12),
              const _GuideStep(
                number: 4,
                icon: Icons.check_circle_outline_rounded,
                title: 'Habilitar Stereo Mix',
                description:
                    'Aparecera "Stereo Mix" o "Mezcla estereo" en gris. '
                    'Click derecho sobre el → "Habilitar"',
              ),
              const SizedBox(height: 12),
              const _GuideStep(
                number: 5,
                icon: Icons.restart_alt_rounded,
                title: 'Reiniciar EasyExpert',
                description:
                    'Cierra y vuelve a abrir EasyExpert. El audio del sistema '
                    'se detectara automaticamente.',
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Process.start('cmd', [
                          '/c',
                          'start',
                          'ms-settings:sound',
                        ]);
                      },
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('Abrir Sonido'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF5CB2FF),
                        foregroundColor: const Color(0xFF08101C),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Entendido'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({
    required this.number,
    required this.icon,
    required this.title,
    required this.description,
  });

  final int number;
  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: const Color(0xFF5CB2FF).withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            '$number',
            style: const TextStyle(
              color: Color(0xFF5CB2FF),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: const Color(0xFF5CB2FF)),
                  const SizedBox(width: 6),
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                description,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DebugLogsPane extends StatelessWidget {
  const _DebugLogsPane({required this.logs});

  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (logs.isEmpty) {
      return Center(
        child: Text(
          'Sin logs todavía. Inicia una sesión para ver actividad.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface.withOpacity(0.6),
              ),
        ),
      );
    }

    return ListView.builder(
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      itemCount: logs.length,
      reverse: true,
      itemBuilder: (context, index) {
        final log = logs[logs.length - 1 - index];
        final isError = log.contains('❌');
        final isWarning = log.contains('⚠️');
        final isSuccess = log.contains('✅');
        final textColor = isError
            ? const Color(0xFFE53935)
            : isWarning
                ? const Color(0xFFFF9800)
                : isSuccess
                    ? const Color(0xFF4CAF50)
                    : colorScheme.onSurface.withOpacity(0.8);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Text(
            log,
            style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: 11,
              color: textColor,
              height: 1.4,
            ),
          ),
        );
      },
    );
  }
}
