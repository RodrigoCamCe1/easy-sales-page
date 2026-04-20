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

  Future<Directory> _documentsDir() async {
    try {
      return await getApplicationDocumentsDirectory();
    } catch (e) {
      if (Platform.isMacOS) {
        final home = Platform.environment['HOME'];
        if (home != null) {
          final fallback = Directory('$home/.config/easy-sales-ia');
          if (!await fallback.exists()) {
            await fallback.create(recursive: true);
          }
          return fallback;
        }
      }
      rethrow;
    }
  }

  Future<File> _file() async {
    final dir = await _documentsDir();
    final scoped = File(
      p.join(dir.path, 'conversations_${await storeUserKey()}.json'),
    );

    final legacy = File(p.join(dir.path, 'conversations.json'));

    if (await legacy.exists() && !await scoped.exists()) {
      await legacy.copy(scoped.path);
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

    final dir = await _documentsDir();
    final legacy = File(p.join(dir.path, 'conversations.json'));
    final legacyItems = await parseFile(legacy);
    if (legacyItems.isNotEmpty && !await file.exists()) {
      await legacy.copy(file.path);
      await legacy.rename(p.join(dir.path, 'conversations.json.migrated'));
    }
    return legacyItems;
  }

  Future<void> _saveLocal(List<Conversation> conversations) async {
    final file = await _file();
    final payload = conversations.map((item) => item.toJson()).toList();
    await file.writeAsString(jsonEncode(payload));
  }

  Future<void> _syncToRemote(List<Conversation> conversations) async {
    final payload = conversations.map((item) => item.toJson()).toList();
    await withAuthRetry<bool>(
      action: (token) async {
        await _remoteApi.putConversations(
          accessToken: token,
          conversations: payload,
        );
        return true;
      },
      silent: true,
    );
  }

  Future<List<Conversation>> load() async {
    final rawItems = await withAuthRetry<List<Map<String, dynamic>>>(
      action: (token) => _remoteApi.getConversations(accessToken: token),
      silent: true,
    );

    if (rawItems != null) {
      if (rawItems.isNotEmpty) {
        final remote = rawItems.map(Conversation.fromJson).toList();
        // Merge: check if local has conversations not in remote
        final local = await _loadLocal();
        if (local.isNotEmpty) {
          final remoteIds = remote.map((c) => c.id).toSet();
          final missing = local.where((c) => !remoteIds.contains(c.id)).toList();
          if (missing.isNotEmpty) {
            remote.addAll(missing);
            remote.sort((a, b) => b.startedAt.compareTo(a.startedAt));
            // Save merged list to both local and remote
            await _saveLocal(remote);
            _syncToRemote(remote); // fire-and-forget
            return remote;
          }
        }
        // Save remote data locally for offline access
        await _saveLocal(remote);
        return remote;
      }

      // Seed inicial: si backend aún no tiene nada, sube lo local del usuario.
      final local = await _loadLocal();
      if (local.isNotEmpty) {
        _syncToRemote(local); // fire-and-forget
        return local;
      }
      return [];
    }

    return _loadLocal();
  }

  Future<void> saveAll(List<Conversation> conversations) async {
    // Always save locally first
    await _saveLocal(conversations);
    // Then sync to remote in background
    _syncToRemote(conversations);
  }

  Future<void> add(Conversation conversation) async {
    // 1. Save locally first — guaranteed to persist
    final current = await _loadLocal();
    current.insert(0, conversation);
    await _saveLocal(current);

    // 2. Try remote in background — don't block or lose data if it fails
    withAuthRetry<bool>(
      action: (token) async {
        await _remoteApi.addConversation(
          accessToken: token,
          conversation: conversation.toJson(),
        );
        return true;
      },
      silent: true,
    );
  }
}
