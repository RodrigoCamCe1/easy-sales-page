class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.preview,
    required this.startedAt,
    required this.endedAt,
    required this.durationSeconds,
  });

  final String id;
  final String title;
  final String preview;
  final DateTime startedAt;
  final DateTime endedAt;
  final int durationSeconds;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'preview': preview,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
        'durationSeconds': durationSeconds,
      };

  static Conversation fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      preview: json['preview'] as String? ?? '',
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: DateTime.parse(json['endedAt'] as String),
      durationSeconds: json['durationSeconds'] as int? ?? 0,
    );
  }
}
