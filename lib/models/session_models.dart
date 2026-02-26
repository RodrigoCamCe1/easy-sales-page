class ChatMessage {
  ChatMessage({
    required this.role,
    required this.text,
    this.assistantTurnId,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  /// 'user' | 'assistant'
  final String role;
  final String text;
  final int? assistantTurnId;
  final DateTime at;

  ChatMessage copyWith({String? text}) => ChatMessage(
        role: role,
        text: text ?? this.text,
        assistantTurnId: assistantTurnId,
        at: at,
      );
}

class TranscriptEntry {
  const TranscriptEntry({
    required this.text,
    required this.isMic,
    this.pending = false,
  });

  final String text;
  final bool isMic;

  /// True while the line is still accumulating (no newline yet).
  final bool pending;
}
