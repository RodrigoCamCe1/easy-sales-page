class ConversationMessage {
  final String role;
  final String text;
  final DateTime at;

  ConversationMessage({required this.role, required this.text, DateTime? at})
      : at = at ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'role': role,
        'text': text,
        'at': at.toIso8601String(),
      };

  factory ConversationMessage.fromJson(Map<String, dynamic> json) {
    final atStr = (json['at'] ?? '').toString();
    return ConversationMessage(
      role: (json['role'] ?? 'assistant').toString(),
      text: (json['text'] ?? '').toString(),
      at: DateTime.tryParse(atStr) ?? DateTime.now(),
    );
  }
}

class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.preview,
    required this.startedAt,
    required this.endedAt,
    required this.durationSeconds,
    this.messages = const [],
    this.suggestions = const [],
    this.transcripts = const [],
  });

  final String id;
  final String title;
  final String preview;
  final DateTime startedAt;
  final DateTime endedAt;
  final int durationSeconds;
  final List<ConversationMessage> messages;
  final List<String> suggestions;
  final List<String> transcripts;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'preview': preview,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
        'durationSeconds': durationSeconds,
        'messages': messages.map((m) => m.toJson()).toList(),
        'suggestions': suggestions,
        'transcripts': transcripts,
      };

  static Conversation fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      preview: json['preview'] as String? ?? '',
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: DateTime.parse(json['endedAt'] as String),
      durationSeconds: json['durationSeconds'] as int? ?? 0,
      messages: ((json['messages'] ?? []) as List)
          .whereType<Map>()
          .map((e) => ConversationMessage.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      suggestions: ((json['suggestions'] ?? []) as List)
          .map((e) => e.toString())
          .toList(),
      transcripts: ((json['transcripts'] ?? []) as List)
          .map((e) => e.toString())
          .toList(),
    );
  }
}
