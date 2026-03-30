import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_audio_capture/flutter_audio_capture.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_config.dart';
import '../models/session_models.dart';
import '../services/agent_profile_store.dart';
import '../services/meeting_session_controller.dart';

class MeetingBarApp extends StatelessWidget {
  const MeetingBarApp({super.key});

  @override
  Widget build(BuildContext context) {
    const brightness = Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: brightness,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'EasyExpert — Modo Reunión',
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        brightness: brightness,
        scaffoldBackgroundColor: Colors.transparent,
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: const MeetingBar(),
    );
  }
}

class MeetingBar extends StatefulWidget {
  const MeetingBar({super.key});

  @override
  State<MeetingBar> createState() => _MeetingBarState();
}

class _MeetingBarState extends State<MeetingBar> {
  // ── UI-only state ─────────────────────────────────────────────────────
  bool _showTranscript = false;
  bool _showDebugLogs = false;
  bool _suggestionsSidebarOpen = true;

  // ── Scroll / input controllers ────────────────────────────────────────
  final ScrollController _chatScrollController = ScrollController();
  final ScrollController _suggestionScrollController = ScrollController();
  final ScrollController _transcriptScrollController = ScrollController();
  final TextEditingController _manualPromptController = TextEditingController();

  // ── Platform audio ────────────────────────────────────────────────────
  final FlutterAudioCapture _audioCapture = FlutterAudioCapture();

  // ── Session controller ────────────────────────────────────────────────
  late final MeetingSessionController _controller;

  bool get _audioSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isLinux;

  void _scrollToBottom(ScrollController ctrl) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!ctrl.hasClients) return;
      final pos = ctrl.position;
      final distanceFromBottom = pos.maxScrollExtent - pos.pixels;
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
  }

  @override
  void initState() {
    super.initState();

    _controller = MeetingSessionController();
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
          debugPrint('Meeting audio capture error: $error');
        },
        sampleRate: 16000,
        bufferSize: 3000,
      );
    } catch (error) {
      debugPrint('Meeting audio capture init error: $error');
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
        if (attempt == 3) return;
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

  Future<void> _openSettings() async {
    final active = await AgentProfileStore.instance.getActiveAgent();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final screenWidth = view.physicalSize.width / view.devicePixelRatio;
    final screenHeight = view.physicalSize.height / view.devicePixelRatio;
    const topOffset = 28.0;
    final window = await DesktopMultiWindow.createWindow(jsonEncode({
      'type': 'settings',
      'mainWindowId': 0,
      'prompt': active.prompt,
      'agentId': active.id,
      'agentName': active.name,
      'agentMode': active.mode,
      'canEditPrompt': active.canEditPrompt,
    }));
    window
      ..setFrame(
        Rect.fromLTWH(0, topOffset, screenWidth, screenHeight - topOffset),
      )
      ..setTitle('Configuracion')
      ..show();
  }

  @override
  void dispose() {
    _controller.onScrollChatToBottom = null;
    _controller.onScrollTranscriptToBottom = null;
    _controller.onScrollSuggestionsToBottom = null;
    _controller.onRequestStartPlatformCapture = null;
    _controller.onRequestStopPlatformCapture = null;
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
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: barHeight),
              decoration: BoxDecoration(
                color: colorScheme.surface.withOpacity(0.42),
                gradient: LinearGradient(
                  colors: [
                    colorScheme.surfaceContainerHighest.withOpacity(0.62),
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
                        // ── Top bar ──
                        Row(
                          children: [
                            Row(
                              children: [
                                navIconButton(
                                  Icons.play_arrow_rounded,
                                  'Iniciar',
                                  _controller.listening
                                      ? null
                                      : _startListening,
                                ),
                                const SizedBox(width: 8),
                                navIconButton(
                                  Icons.stop_rounded,
                                  'Detener',
                                  _controller.listening
                                      ? _stopListening
                                      : null,
                                ),
                                const SizedBox(width: 8),
                                navIconButton(
                                  Icons.settings_rounded,
                                  'Configurar',
                                  _openSettings,
                                ),
                              ],
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: DragToMoveArea(
                                child: Container(
                                  height: 28,
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.groups_rounded,
                                        size: 16,
                                        color: Color(0xFF26A69A),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'Modo Reunión $appVersion',
                                        style:
                                            textTheme.labelSmall?.copyWith(
                                          color:
                                              colorScheme.onSurfaceVariant,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
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
                                  onPressed: () => _requestMainAction(
                                      'barCloseRequested'),
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
                        // ── Status row ──
                        Row(
                          children: [
                            const Icon(
                              Icons.mic_rounded,
                              size: 16,
                              color: Color(0xFF26A69A),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _controller.listening
                                  ? 'Escuchando reunión'
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
                        // ── Chips ──
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
                                  icon: Icons.notes_rounded,
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
                                  label:
                                      _showDebugLogs ? 'Ocultar logs' : 'Logs',
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
                        // ── Manual prompt ──
                        Container(
                          constraints: const BoxConstraints(minHeight: 34),
                          decoration: BoxDecoration(
                            color:
                                colorScheme.surfaceContainerHighest.withOpacity(0.58),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: colorScheme.outlineVariant
                                  .withOpacity(0.72),
                            ),
                          ),
                          padding:
                              const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _manualPromptController,
                                  onSubmitted: (_) => _sendManualPrompt(),
                                  decoration: InputDecoration(
                                    border: InputBorder.none,
                                    hintText:
                                        'Pregunta sobre lo que quieras...',
                                    hintStyle:
                                        textTheme.bodySmall?.copyWith(
                                      color: colorScheme.onSurface
                                          .withOpacity(0.78),
                                    ),
                                    isDense: true,
                                    contentPadding:
                                        const EdgeInsets.symmetric(
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
                          color:
                              colorScheme.outlineVariant.withOpacity(0.25),
                        ),
                        const SizedBox(height: 6),
                        // ── Main content ──
                        Expanded(
                          child: Row(
                            children: [
                              AnimatedContainer(
                                duration:
                                    const Duration(milliseconds: 180),
                                curve: Curves.easeOut,
                                width: _suggestionsSidebarOpen
                                    ? suggestionsWidth
                                    : 0,
                                child: _suggestionsSidebarOpen
                                    ? _SuggestionsSidebar(
                                        controller:
                                            _suggestionScrollController,
                                        suggestions:
                                            _controller.suggestions,
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
                                        ? _PlainTranscriptPane(
                                            controller:
                                                _transcriptScrollController,
                                            text: _controller
                                                .buildTranscriptText(),
                                          )
                                        : _ChatPane(
                                            controller:
                                                _chatScrollController,
                                            messages: _controller
                                                .chatResponses,
                                            pinnedMessages: _controller
                                                .pinnedMessages,
                                            emptyText: _controller
                                                .statusMessage,
                                            isThinking: _controller
                                                .responseInFlight,
                                            onTogglePin: _controller
                                                .togglePin,
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
          ),
        ),
      ),
    );
  }
}

// ── Plain text transcript (no chat bubbles) ─────────────────────────────────

class _PlainTranscriptPane extends StatelessWidget {
  const _PlainTranscriptPane({
    required this.controller,
    required this.text,
  });

  final ScrollController controller;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (text.trim().isEmpty) {
      return Center(
        child: Text(
          'Esperando audio para transcribir...',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface.withOpacity(0.6),
              ),
        ),
      );
    }

    return SingleChildScrollView(
      controller: controller,
      physics: const ClampingScrollPhysics(),
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withOpacity(0.4),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: colorScheme.outlineVariant.withOpacity(0.5),
          ),
        ),
        child: SelectableText(
          _fixMojibake(text),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface,
                height: 1.6,
              ),
        ),
      ),
    );
  }
}

// ── Reusable widgets (copied from recording_bar to keep independent) ────────

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
    final effectiveColor =
        isActive && activeColor != null ? activeColor! : null;
    final chip = Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: effectiveColor != null
            ? effectiveColor.withOpacity(0.15)
            : colorScheme.surfaceContainerHighest.withOpacity(0.5),
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
          Icon(icon,
              size: 14,
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
        color: colorScheme.surfaceContainerHighest.withOpacity(0.4),
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
              Icon(Icons.lightbulb_outline_rounded,
                  size: 18, color: colorScheme.onSurfaceVariant),
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
            child: suggestions.isEmpty
                ? SingleChildScrollView(
                    controller: controller,
                    child: Text(
                      'Aún no hay sugerencias.\nHabla para que la IA genere preguntas.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurface,
                          ),
                    ),
                  )
                : ListView.builder(
                    controller: controller,
                    physics: const ClampingScrollPhysics(),
                    padding: const EdgeInsets.only(top: 2, bottom: 10),
                    itemCount: suggestions.length,
                    itemBuilder: (context, index) {
                      final s = suggestions[index].trim();
                      if (s.isEmpty) return const SizedBox.shrink();
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 10),
                        decoration: BoxDecoration(
                          color: colorScheme.surface.withOpacity(0.34),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color:
                                colorScheme.outlineVariant.withOpacity(0.48),
                          ),
                        ),
                        child: Text(
                          _fixMojibake('• $s'),
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: colorScheme.onSurface),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ChatPane extends StatelessWidget {
  const _ChatPane({
    required this.controller,
    required this.messages,
    required this.pinnedMessages,
    required this.emptyText,
    required this.isThinking,
    required this.onTogglePin,
  });

  final ScrollController controller;
  final List<ChatMessage> messages;
  final List<ChatMessage> pinnedMessages;
  final String emptyText;
  final bool isThinking;
  final void Function(int index) onTogglePin;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final hasAnything = messages.isNotEmpty || isThinking;
    if (!hasAnything) {
      return Center(
        child: Text(
          emptyText.isEmpty ? 'Listo para escuchar' : emptyText,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface.withOpacity(0.6),
              ),
        ),
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

    return Column(
      children: [
        // ── Pinned messages section ──
        if (pinnedMessages.isNotEmpty)
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 150),
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1a1a2e),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: const Color(0xFFFFD54F).withOpacity(0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Row(
                    children: [
                      Icon(Icons.star_rounded,
                          size: 14,
                          color: const Color(0xFFFFD54F).withOpacity(0.8)),
                      const SizedBox(width: 4),
                      Text(
                        'Puntos clave (${pinnedMessages.length})',
                        style:
                            Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: const Color(0xFFFFD54F),
                                  fontWeight: FontWeight.w600,
                                ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding:
                        const EdgeInsets.only(left: 10, right: 10, bottom: 6),
                    itemCount: pinnedMessages.length,
                    itemBuilder: (context, i) {
                      final msg = pinnedMessages[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '• ${msg.text.trim()}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: colorScheme.onSurface.withOpacity(0.85),
                                fontSize: 11,
                              ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        // ── Chat messages ──
        Expanded(
          child: ListView.builder(
            controller: controller,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.only(top: 6, bottom: 10),
            itemCount: itemCount,
            itemBuilder: (context, index) {
              final isThinkingRow = isThinking && index == itemCount - 1;
              final role =
                  isThinkingRow ? 'assistant' : messages[index].role;
              final text = isThinkingRow
                  ? 'Asistente está pensando...'
                  : messages[index].text.trim();

              final isAssistant = role == 'assistant';
              final currentAssistantTurnId = isThinkingRow
                  ? latestAssistantTurnId
                  : messages[index].assistantTurnId;
              final isFreestyle =
                  !isThinkingRow && messages[index].isFreestyle;
              final isPinned = !isThinkingRow && messages[index].pinned;
              const freestyleRed = Color(0xFFE53935);

              return Align(
                alignment: isAssistant
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                child: GestureDetector(
                  onDoubleTap: isAssistant && !isThinkingRow
                      ? () => onTogglePin(index)
                      : null,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    constraints: const BoxConstraints(maxWidth: 560),
                    decoration: BoxDecoration(
                      color: isFreestyle
                          ? freestyleRed.withOpacity(0.12)
                          : isAssistant
                              ? ((latestAssistantTurnId != null &&
                                      currentAssistantTurnId ==
                                          latestAssistantTurnId)
                                  ? colorScheme.primary.withOpacity(0.4)
                                  : (previousAssistantTurnId != null &&
                                          currentAssistantTurnId ==
                                              previousAssistantTurnId)
                                      ? colorScheme.primary.withOpacity(0.24)
                                      : colorScheme.surfaceContainerHighest
                                          .withOpacity(0.56))
                              : colorScheme.primary.withOpacity(0.36),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isPinned
                            ? const Color(0xFFFFD54F).withOpacity(0.7)
                            : isFreestyle
                                ? freestyleRed.withOpacity(0.6)
                                : colorScheme.outlineVariant
                                    .withOpacity(0.54),
                        width: isPinned ? 1.5 : 1.0,
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
                                    size: 11,
                                    color: freestyleRed.withOpacity(0.8)),
                                const SizedBox(width: 4),
                                Text(
                                  'Modo libre · puede contener info no verificada',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(
                                        color:
                                            freestyleRed.withOpacity(0.8),
                                        fontSize: 10,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                _fixMojibake(text),
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: colorScheme.onSurface,
                                      fontStyle: isThinkingRow
                                          ? FontStyle.italic
                                          : FontStyle.normal,
                                    ),
                              ),
                            ),
                            if (isAssistant && !isThinkingRow)
                              GestureDetector(
                                onTap: () => onTogglePin(index),
                                child: Padding(
                                  padding:
                                      const EdgeInsets.only(left: 6, top: 2),
                                  child: Icon(
                                    isPinned
                                        ? Icons.star_rounded
                                        : Icons.star_outline_rounded,
                                    size: 16,
                                    color: isPinned
                                        ? const Color(0xFFFFD54F)
                                        : colorScheme.onSurface
                                            .withOpacity(0.3),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
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

String _fixMojibake(String input) {
  if (input.isEmpty) return input;
  if (!RegExp(r'[ÃÂâð]').hasMatch(input)) return input;
  try {
    final fixed = utf8.decode(latin1.encode(input), allowMalformed: true);
    if (fixed.isNotEmpty) return fixed;
  } catch (_) {}
  return input;
}
