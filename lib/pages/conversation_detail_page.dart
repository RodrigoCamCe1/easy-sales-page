import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../models/conversation.dart';

class ConversationDetailPage extends StatelessWidget {
  const ConversationDetailPage({super.key, required this.conversation});

  final Conversation conversation;

  @override
  Widget build(BuildContext context) {
    final isLegacy = conversation.messages.isEmpty &&
        conversation.suggestions.isEmpty &&
        conversation.transcripts.isEmpty;

    if (isLegacy) {
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _DetailTitleBar(title: conversation.title),
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.history_rounded, size: 44),
                        SizedBox(height: 12),
                        Text(
                          'Esta conversaci\u00f3n fue guardada con una versi\u00f3n anterior.',
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: 8),
                        Text(
                          'El historial completo de chat, sugerencias y transcripci\u00f3n no estaba disponible en ese momento.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _DetailTitleBar(title: conversation.title),
              const Material(
                child: TabBar(
                  tabs: [
                    Tab(text: 'Chat'),
                    Tab(text: 'Sugerencias'),
                    Tab(text: 'Transcripcion'),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _ChatTab(messages: conversation.messages),
                    _BulletListTab(items: conversation.suggestions),
                    _TranscriptTab(items: conversation.transcripts),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailTitleBar extends StatelessWidget {
  const _DetailTitleBar({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    Future<void> goBackToHome() async {
      if (Navigator.of(context).canPop()) {
        await Navigator.of(context).maybePop();
      }
    }

    return SizedBox(
      height: 38,
      child: Row(
        children: [
          _DetailWindowButton(
            icon: Icons.arrow_back_rounded,
            tooltip: 'Volver',
            onPressed: goBackToHome,
          ),
          Expanded(
            child: DragToMoveArea(
              child: Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
          _DetailWindowButton(
            icon: Icons.remove_rounded,
            tooltip: 'Minimizar',
            onPressed: () async => windowManager.minimize(),
          ),
          _DetailWindowButton(
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
          _DetailWindowButton(
            icon: Icons.close_rounded,
            tooltip: 'Cerrar y volver',
            onPressed: goBackToHome,
          ),
        ],
      ),
    );
  }
}

class _DetailWindowButton extends StatelessWidget {
  const _DetailWindowButton({
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

class _ChatTab extends StatelessWidget {
  const _ChatTab({required this.messages});

  final List<ConversationMessage> messages;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final item = messages[index];
        final isAssistant = item.role == 'assistant';
        return Align(
          alignment: isAssistant ? Alignment.centerLeft : Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            constraints: const BoxConstraints(maxWidth: 560),
            decoration: BoxDecoration(
              color: isAssistant
                  ? Theme.of(context).colorScheme.surfaceVariant
                  : Theme.of(context).colorScheme.primary.withOpacity(0.18),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(item.text),
          ),
        );
      },
    );
  }
}

class _BulletListTab extends StatelessWidget {
  const _BulletListTab({required this.items});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      itemBuilder: (context, index) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text('\u2022 ${items[index]}'),
        );
      },
    );
  }
}

class _TranscriptTab extends StatelessWidget {
  const _TranscriptTab({required this.items});

  final List<String> items;

  bool get _hasBubbleFormat {
    return items.any((line) {
      final t = line.trimLeft();
      return t.startsWith('🎤 ') || t.startsWith('🖥️ ') || t.startsWith('🖥 ');
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasBubbleFormat) {
      return _BulletListTab(items: items);
    }

    final entries = items
        .map(_TranscriptBubbleEntry.fromRaw)
        .where((e) => e.text.isNotEmpty)
        .toList();

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final align =
            entry.isMic ? Alignment.centerRight : Alignment.centerLeft;
        final bgColor = entry.isMic
            ? const Color(0xFF2F7C4E).withOpacity(0.9)
            : Theme.of(context).colorScheme.surfaceVariant;
        final fgColor = entry.isMic ? Colors.white : null;

        return Align(
          alignment: align,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 560),
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              entry.text,
              style: TextStyle(color: fgColor),
            ),
          ),
        );
      },
    );
  }
}

class _TranscriptBubbleEntry {
  const _TranscriptBubbleEntry({required this.text, required this.isMic});

  final String text;
  final bool isMic;

  static _TranscriptBubbleEntry fromRaw(String raw) {
    final t = raw.trim();
    if (t.startsWith('🎤 ')) {
      return _TranscriptBubbleEntry(
        text: t.substring(2).trim(),
        isMic: true,
      );
    }
    if (t.startsWith('🖥️ ')) {
      return _TranscriptBubbleEntry(
        text: t.substring(3).trim(),
        isMic: false,
      );
    }
    if (t.startsWith('🖥 ')) {
      return _TranscriptBubbleEntry(
        text: t.substring(2).trim(),
        isMic: false,
      );
    }
    return _TranscriptBubbleEntry(text: t, isMic: false);
  }
}
