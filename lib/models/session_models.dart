class ChatMessage {
  ChatMessage({
    required this.role,
    required this.text,
    this.assistantTurnId,
    this.isFreestyle = false,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  /// 'user' | 'assistant'
  final String role;
  final String text;
  final int? assistantTurnId;
  final bool isFreestyle;
  final DateTime at;

  ChatMessage copyWith({String? text, bool? isFreestyle}) => ChatMessage(
        role: role,
        text: text ?? this.text,
        assistantTurnId: assistantTurnId,
        isFreestyle: isFreestyle ?? this.isFreestyle,
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
