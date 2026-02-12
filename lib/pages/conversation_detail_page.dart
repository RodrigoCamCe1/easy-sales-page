import 'dart:convert';

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
      return t.startsWith('🎤 ') ||
          t.startsWith('🖥️ ') ||
          t.startsWith('🖥 ') ||
          t.startsWith('ðŸŽ¤ ') ||
          t.startsWith('ðŸ–¥ï¸ ') ||
          t.startsWith('ðŸ–¥ ');
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
    final normalized = _normalizeEntries(entries);

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: normalized.length,
      itemBuilder: (context, index) {
        final entry = normalized[index];
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
              _fixMojibake(entry.text),
              style: TextStyle(color: fgColor),
            ),
          ),
        );
      },
    );
  }

  List<_TranscriptBubbleEntry> _normalizeEntries(
    List<_TranscriptBubbleEntry> source,
  ) {
    if (source.length < 2) return source;
    final ordered = List<_TranscriptBubbleEntry>.from(source);

    for (var i = 1; i < ordered.length - 1; i++) {
      final prev = ordered[i - 1];
      final current = ordered[i];
      final next = ordered[i + 1];
      if (prev.isMic != next.isMic) continue;
      if (current.isMic == prev.isMic) continue;
      if (!_isShortInterjection(current.text)) continue;

      ordered.removeAt(i);
      ordered.insert(i + 1, current);
      i++;
    }

    final merged = <_TranscriptBubbleEntry>[];
    for (final item in ordered) {
      if (merged.isEmpty) {
        merged.add(item);
        continue;
      }
      final last = merged.last;
      if (last.isMic == item.isMic) {
        merged[merged.length - 1] = _TranscriptBubbleEntry(
          text: '${last.text.trim()}\n${item.text.trim()}'.trim(),
          isMic: last.isMic,
        );
      } else {
        merged.add(item);
      }
    }

    return merged;
  }

  bool _isShortInterjection(String text) {
    final words = text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    return words.length <= 3 || text.trim().length <= 18;
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

class _TranscriptBubbleEntry {
  const _TranscriptBubbleEntry({required this.text, required this.isMic});

  final String text;
  final bool isMic;

  static _TranscriptBubbleEntry fromRaw(String raw) {
    final t = raw.trim();
    if (RegExp(r'^(🎤|ðŸŽ¤)\s*').hasMatch(t)) {
      return _TranscriptBubbleEntry(
        text: t.replaceFirst(RegExp(r'^(🎤|ðŸŽ¤)\s*'), '').trim(),
        isMic: true,
      );
    }
    if (RegExp(r'^(🖥️|🖥|ðŸ–¥ï¸|ðŸ–¥)\s*').hasMatch(t)) {
      return _TranscriptBubbleEntry(
        text: t.replaceFirst(RegExp(r'^(🖥️|🖥|ðŸ–¥ï¸|ðŸ–¥)\s*'), '').trim(),
        isMic: false,
      );
    }
    return _TranscriptBubbleEntry(text: t, isMic: false);
  }
}
