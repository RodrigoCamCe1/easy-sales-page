import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_config.dart';
import '../models/conversation.dart';
import '../services/conversation_store.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Conversation> _conversations = [];
  bool _loading = true;
  WindowController? _barWindow;

  @override
  void initState() {
    super.initState();
    _loadConversations();
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
  // ⚠️ IGNORAR TODO lo que NO venga de la barra
  if (_barWindow == null || fromWindowId != _barWindow!.windowId) {
    return null;
  }

  switch (call.method) {
    case 'barOpened':
      await windowManager.hide();
      break;

    case 'barMinimizeRequested':
      await _barWindow?.hide();
      break;

    case 'barCloseRequested':
    case 'barClosed':
      await _barWindow?.close();
      _barWindow = null;
      await windowManager.show();
      await windowManager.focus();
      break;
  }

  return null;
});
  }

  Future<void> _loadConversations() async {
    setState(() {
      _loading = true;
    });
    final items = await ConversationStore.instance.load();
    if (!mounted) return;
    setState(() {
      _conversations = items;
      _loading = false;
    });
  }

  Future<void> _openRecordingBar() async {
    if (_barWindow != null) {
      await _barWindow?.show();
      await windowManager.hide();
      return;
    }
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final screenWidth = view.physicalSize.width;
    final screenHeight = view.physicalSize.height;
    final window = await DesktopMultiWindow.createWindow(jsonEncode({
      'type': 'bar',
    }));
    window
      ..setFrame(Rect.fromLTWH(0, 0, screenWidth, screenHeight))
      ..setTitle('AsesorIA')
      ..show();
    _barWindow = window;
    await windowManager.hide();
  }

  Future<void> _openSettings() async {
    String prompt = systemPrompt;
    if (await promptFile.exists()) {
      final content = (await promptFile.readAsString()).trim();
      if (content.isNotEmpty) {
        prompt = content;
      }
    }
    final window = await DesktopMultiWindow.createWindow(jsonEncode({
      'type': 'settings',
      'mainWindowId': 0,
      'prompt': prompt,
    }));
    window
      ..setTitle('Configuracion')
      ..show();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF0B0C10),
              Color(0xFF141723),
              Color(0xFF0E0F14),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
                child: Row(
                  children: [
                    Row(
                      children: [
                        _IconPill(
                          icon: Icons.public,
                          tooltip: 'Inicio',
                          onTap: () {},
                        ),
                        const SizedBox(width: 8),
                        _IconPill(
                          icon: Icons.settings_rounded,
                          tooltip: 'Configuracion',
                          onTap: _openSettings,
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        height: 38,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.08),
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          children: [
                            Icon(Icons.search,
                                size: 18,
                                color: Colors.white.withOpacity(0.6)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                decoration: const InputDecoration(
                                  border: InputBorder.none,
                                  hintText: 'Search or ask anything...',
                                ),
                                style: textTheme.bodyMedium
                                    ?.copyWith(color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2F3A),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      alignment: Alignment.center,
                      child: const Text('A'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            'AsesorIA',
                            style: textTheme.headlineMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 12),
                          _SoftPill(
                            label: 'Agente',
                            icon: Icons.tune_rounded,
                          ),
                          const Spacer(),
                          ElevatedButton.icon(
                            onPressed: _openRecordingBar,
                            icon: const Icon(Icons.play_arrow_rounded, size: 18),
                            label: const Text('Start AsesorIA'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF5CB2FF),
                              foregroundColor: const Color(0xFF0B0C10),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 18, vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: _GradientCard(
                              title: 'Inicia reuniones con AsesorIA',
                              subtitle:
                                  'AsesorIA analiza participantes, ofrece asistencia en tiempo real y genera notas.',
                              actionText: 'Unirse a demo',
                              onAction: _openRecordingBar,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 2,
                            child: _SmallCard(
                              title: 'Recibe recordatorios',
                              subtitle: 'Conecta tu calendario',
                              buttonText: 'Conectar',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Conversaciones',
                            style: textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _loadConversations,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('Actualizar'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_loading)
                        const Center(child: CircularProgressIndicator())
                      else if (_conversations.isEmpty)
                        _EmptyState(onStart: _openRecordingBar)
                      else
                        Column(
                          children: _conversations
                              .map((item) => _ConversationTile(item: item))
                              .toList(),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: null,
    );
  }
}

class _SoftPill extends StatelessWidget {
  const _SoftPill({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white70),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(color: Colors.white70)),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more, size: 16, color: Colors.white70),
        ],
      ),
    );
  }
}

class _IconPill extends StatelessWidget {
  const _IconPill({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: const Color(0xFF1B1F2A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withOpacity(0.08),
            ),
          ),
          child: Icon(icon, size: 18),
        ),
      ),
    );
  }
}

class _GradientCard extends StatelessWidget {
  const _GradientCard({
    required this.title,
    required this.subtitle,
    required this.actionText,
    required this.onAction,
  });

  final String title;
  final String subtitle;
  final String actionText;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0D2A6A), Color(0xFF1D6FE3), Color(0xFF5CB2FF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(color: Colors.white.withOpacity(0.85)),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: onAction,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.18),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Text(actionText),
          ),
        ],
      ),
    );
  }
}

class _SmallCard extends StatelessWidget {
  const _SmallCard({
    required this.title,
    required this.subtitle,
    required this.buttonText,
  });

  final String title;
  final String subtitle;
  final String buttonText;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          Text(subtitle, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () {},
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.12),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Text(buttonText),
          ),
        ],
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.item});

  final Conversation item;

  @override
  Widget build(BuildContext context) {
    final time = TimeOfDay.fromDateTime(item.endedAt);
    final duration = Duration(seconds: item.durationSeconds);
    final timeLabel =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final durationLabel =
        '${duration.inMinutes.toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  item.preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _Tag(label: durationLabel),
              const SizedBox(height: 6),
              Text(timeLabel, style: const TextStyle(color: Colors.white60)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: const TextStyle(color: Colors.white70)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        children: [
          const Icon(Icons.chat_bubble_outline, color: Colors.white54),
          const SizedBox(height: 10),
          const Text(
            'Aún no hay conversaciones guardadas.',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: onStart,
            child: const Text('Iniciar AsesorIA'),
          ),
        ],
      ),
    );
  }
}
