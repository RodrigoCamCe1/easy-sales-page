import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/conversation.dart';
import 'backend_data_api.dart';
import 'store_helpers.dart';

class ConversationStore {
  ConversationStore._();

  static final ConversationStore instance = ConversationStore._();
  final BackendDataApi _remoteApi = BackendDataApi();

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    final scoped = File(
      p.join(dir.path, 'conversations_${await storeUserKey()}.json'),
    );

    final legacy = File(p.join(dir.path, 'conversations.json'));

    if (await legacy.exists() && !await scoped.exists()) {
      await legacy.copy(scoped.path);
      // Rename legacy so it doesn't get copied to other users.
      await legacy.rename(p.join(dir.path, 'conversations.json.migrated'));
    }

    return scoped;
  }

  Future<List<Conversation>> _loadLocal() async {
    final file = await _file();
    Future<List<Conversation>> parseFile(File source) async {
      if (!await source.exists()) return [];
      final raw = await source.readAsString();
      if (raw.trim().isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
        .whereType<Map>()
        .map((item) => Conversation.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    }

    final scoped = await parseFile(file);
    if (scoped.isNotEmpty) return scoped;

    final dir = await getApplicationDocumentsDirectory();
    final legacy = File(p.join(dir.path, 'conversations.json'));
    final legacyItems = await parseFile(legacy);
    if (legacyItems.isNotEmpty && !await file.exists()) {
      await legacy.copy(file.path);
      await legacy.rename(p.join(dir.path, 'conversations.json.migrated'));
    }
    return legacyItems;
  }

  Future<List<Conversation>> load() async {
    final rawItems = await withAuthRetry<List<Map<String, dynamic>>>(
      action: (token) => _remoteApi.getConversations(accessToken: token),
      silent: true,
    );

    if (rawItems != null) {
      if (rawItems.isNotEmpty) {
        return rawItems.map(Conversation.fromJson).toList();
      }

      // Seed inicial: si backend aún no tiene nada, sube lo local del usuario.
      final local = await _loadLocal();
      if (local.isNotEmpty) {
        await withAuthRetry<void>(
          action: (token) => _remoteApi.putConversations(
            accessToken: token,
            conversations: local.map((item) => item.toJson()).toList(),
          ),
          silent: true,
        );
        return local;
      }
      return [];
    }

    return _loadLocal();
  }

  Future<void> saveAll(List<Conversation> conversations) async {
    final payload = conversations.map((item) => item.toJson()).toList();
    final saved = await withAuthRetry<bool>(
      action: (token) async {
        await _remoteApi.putConversations(
          accessToken: token,
          conversations: payload,
        );
        return true;
      },
      silent: true,
    );
    if (saved == true) return;

    final file = await _file();
    await file.writeAsString(jsonEncode(payload));
  }

  Future<void> add(Conversation conversation) async {
    final added = await withAuthRetry<bool>(
      action: (token) async {
        await _remoteApi.addConversation(
          accessToken: token,
          conversation: conversation.toJson(),
        );
        return true;
      },
      silent: true,
    );
    if (added == true) return;

    final current = await load();
    current.insert(0, conversation);
    await saveAll(current);
  }
}
