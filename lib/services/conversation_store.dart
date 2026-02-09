import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/conversation.dart';

class ConversationStore {
  ConversationStore._();

  static final ConversationStore instance = ConversationStore._();

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'conversations.json'));
  }

  Future<List<Conversation>> load() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map>()
        .map((item) => Conversation.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<void> saveAll(List<Conversation> conversations) async {
    final file = await _file();
    final encoded =
        jsonEncode(conversations.map((item) => item.toJson()).toList());
    await file.writeAsString(encoded);
  }

  Future<void> add(Conversation conversation) async {
    final current = await load();
    current.insert(0, conversation);
    await saveAll(current);
  }
}
