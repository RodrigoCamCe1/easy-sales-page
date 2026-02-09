import 'package:flutter/material.dart';

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
        appBar: AppBar(title: Text(conversation.title)),
        body: const Center(
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
      );
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(conversation.title),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Chat'),
              Tab(text: 'Sugerencias'),
              Tab(text: 'Transcripcion'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _ChatTab(messages: conversation.messages),
            _BulletListTab(items: conversation.suggestions),
            _BulletListTab(items: conversation.transcripts),
          ],
        ),
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
          alignment:
              isAssistant ? Alignment.centerLeft : Alignment.centerRight,
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
