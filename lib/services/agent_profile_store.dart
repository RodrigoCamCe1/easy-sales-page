import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/app_config.dart';
import '../models/agent_profile.dart';
import 'auth_api.dart';
import 'auth_session_manager.dart';
import 'backend_data_api.dart';
import 'store_helpers.dart';

class AgentProfileStore {
  AgentProfileStore._();

  static final AgentProfileStore instance = AgentProfileStore._();
  final BackendDataApi _remoteApi = BackendDataApi();

  static const String salesAgentId = 'sales';
  static const String interviewsAgentId = 'interviews';
  static const String customDefaultAgentId = 'custom-default';

  Future<Directory> _documentsDir() async {
    return getApplicationDocumentsDirectory();
  }

  Future<File> _file() async {
    final dir = await _documentsDir();
    final scoped = File(
      p.join(dir.path, 'agents_config_${await storeUserKey()}.json'),
    );

    final legacy = File(p.join(dir.path, 'agents_config.json'));

    if (await legacy.exists() && !await scoped.exists()) {
      await legacy.copy(scoped.path);
      await legacy.rename(p.join(dir.path, 'agents_config.json.migrated'));
    }

    return scoped;
  }

  Future<File> _userPromptFile() async {
    final dir = await _documentsDir();
    final userPrompt = File(
      p.join(dir.path, 'prompt_${await storeUserKey()}.txt'),
    );

    if (await promptFile.exists() && !await userPrompt.exists()) {
      await promptFile.copy(userPrompt.path);
      await promptFile.rename(
        p.join(dir.path, '${p.basename(promptFile.path)}.migrated'),
      );
    }

    return userPrompt;
  }

  Future<AgentConfig?> _loadLocalConfigOrNull() async {
    final scoped = await _file();

    Future<AgentConfig?> parseFile(File source) async {
      if (!await source.exists()) return null;
      final raw = (await source.readAsString()).trim();
      if (raw.isEmpty) return null;

      dynamic decoded;
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        return null;
      }
      if (decoded is! Map) return null;

      final current = AgentConfig.fromJson(Map<String, dynamic>.from(decoded));
      return _normalizeConfig(current);
    }

    final scopedConfig = await parseFile(scoped);
    if (scopedConfig != null) return scopedConfig;

    final dir = await _documentsDir();
    final legacy = File(p.join(dir.path, 'agents_config.json'));
    final legacyConfig = await parseFile(legacy);
    if (legacyConfig != null && !await scoped.exists()) {
      await legacy.copy(scoped.path);
      await legacy.rename(p.join(dir.path, 'agents_config.json.migrated'));
    }
    return legacyConfig;
  }

  Future<AgentConfig> loadConfig() async {
    final token = AuthSessionManager.instance.accessToken?.trim() ?? '';
    if (token.isNotEmpty) {
      try {
        final local = await _loadLocalConfigOrNull();
        final remote = await _remoteApi.getAgentsConfig(accessToken: token);
        if (remote != null) {
          final current = AgentConfig.fromJson(remote);
          final normalized = _normalizeConfig(current);
          final merged = _mergeRemoteWithLocal(
            remoteConfig: normalized,
            localConfig: local,
          );
          await _persistLocal(merged);
          await _syncLegacyPrompt(
            merged.activeAgent?.composedPrompt ?? systemPrompt,
          );
          await _persistRemote(merged, silent: true);
          return merged;
        }

        // Seed inicial: backend vacio, intenta subir primero lo local.
        if (local != null) {
          await _persistLocal(local);
          await _syncLegacyPrompt(local.activeAgent?.composedPrompt ?? systemPrompt);
          await _persistRemote(local, silent: true);
          return local;
        }

        final seeded = await _bootstrapConfigFromLegacyPrompt();
        await _persistRemote(seeded, silent: true);
        return seeded;
      } on AuthApiException catch (error) {
        if (error.statusCode == 401) {
          final refreshed =
              await AuthSessionManager.instance.refreshWithStoredToken();
          if (refreshed) {
            return loadConfig();
          }
        }
      } catch (_) {}
    }

    final local = await _loadLocalConfigOrNull();
    if (local == null) {
      return _bootstrapConfigFromLegacyPrompt();
    }
    await _persistLocal(local);
    await _syncLegacyPrompt(
      local.activeAgent?.composedPrompt ?? systemPrompt,
    );
    return local;
  }

  Future<AgentProfile> getActiveAgent() async {
    final config = await loadConfig();
    return config.activeAgent ?? _defaultBuiltIns().first;
  }

  Future<AgentConfig> setActiveAgent(String agentId) async {
    final config = await loadConfig();
    final exists = config.agents.any((a) => a.id == agentId);
    final next = config.copyWith(
      activeAgentId: exists ? agentId : config.activeAgentId,
    );
    await _persist(next);
    await _syncLegacyPrompt(next.activeAgent?.composedPrompt ?? systemPrompt);
    return next;
  }

  Future<AgentConfig> updateAgentPrompt({
    required String agentId,
    required String prompt,
  }) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Prompt vacio');
    }

    final config = await loadConfig();
    final nextAgents = config.agents.map((agent) {
      if (agent.id != agentId) return agent;
      if (!agent.canEditPrompt) return agent;
      return agent.copyWith(prompt: trimmed);
    }).toList();
    final next = config.copyWith(agents: nextAgents);
    await _persist(next);

    if (next.activeAgentId == agentId) {
      final active = next.activeAgent;
      await _syncLegacyPrompt(active?.composedPrompt ?? trimmed);
    }
    return next;
  }

  Future<AgentConfig> createCustomAgent({
    required String name,
    required String communicationStyle,
    required String communicationStyleOther,
    required String mindset,
    required String prompt,
  }) async {
    final nextName = name.trim();
    final nextStyle = communicationStyle.trim().toLowerCase();
    final nextStyleOther = communicationStyleOther.trim();
    final nextMindset = mindset.trim();
    final nextPrompt = prompt.trim();
    if (nextName.isEmpty || nextMindset.isEmpty) {
      throw ArgumentError('Nombre y mentalidad requeridos');
    }
    if (!_validStyles.contains(nextStyle)) {
      throw ArgumentError('Estilo invalido');
    }
    if (nextStyle == 'otro' && nextStyleOther.isEmpty) {
      throw ArgumentError('Debes especificar el estilo');
    }

    final config = await loadConfig();
    final id = 'custom-${DateTime.now().millisecondsSinceEpoch}';
    final created = AgentProfile(
      id: id,
      name: nextName,
      mode: 'custom',
      communicationStyle: nextStyle,
      communicationStyleOther: nextStyle == 'otro' ? nextStyleOther : '',
      mindset: nextMindset,
      prompt: nextPrompt.isEmpty ? systemPrompt : nextPrompt,
      canEditPrompt: true,
    );

    final next = config.copyWith(
      activeAgentId: created.id,
      agents: [...config.agents, created],
    );

    await _persist(next);
    await _syncLegacyPrompt(created.composedPrompt);
    return next;
  }

  Future<AgentConfig> updateAgentQuickProfile({
    required String agentId,
    required String communicationStyle,
    required String communicationStyleOther,
    required String mindset,
    String? prompt,
  }) async {
    final nextStyle = communicationStyle.trim().toLowerCase();
    final nextStyleOther = communicationStyleOther.trim();
    final nextMindset = mindset.trim();
    final nextPrompt = (prompt ?? '').trim();

    if (!_validStyles.contains(nextStyle)) {
      throw ArgumentError('Estilo invalido');
    }
    if (nextStyle == 'otro' && nextStyleOther.isEmpty) {
      throw ArgumentError('Debes especificar el estilo');
    }
    if (nextMindset.isEmpty) {
      throw ArgumentError('Mentalidad requerida');
    }

    final config = await loadConfig();
    final nextAgents = config.agents.map((agent) {
      if (agent.id != agentId) return agent;
      var updatedPrompt = agent.prompt;
      if (agent.canEditPrompt && nextPrompt.isNotEmpty) {
        updatedPrompt = nextPrompt;
      }
      return agent.copyWith(
        communicationStyle: nextStyle,
        communicationStyleOther: nextStyle == 'otro' ? nextStyleOther : '',
        mindset: nextMindset,
        prompt: updatedPrompt,
      );
    }).toList();

    final next = config.copyWith(agents: nextAgents);
    await _persist(next);
    if (next.activeAgentId == agentId) {
      await _syncLegacyPrompt(next.activeAgent?.composedPrompt ?? systemPrompt);
    }
    return next;
  }

  Future<void> _persist(AgentConfig config) async {
    await _persistLocal(config);
    await _persistRemote(config, silent: false);
  }

  Future<void> _persistLocal(AgentConfig config) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(config.toJson()));
  }

  Future<void> _persistRemote(AgentConfig config, {required bool silent}) async {
    final payload = config.toJson();
    await withAuthRetry<void>(
      action: (token) => _remoteApi.putAgentsConfig(
        accessToken: token,
        config: payload,
      ),
      silent: silent,
    );
  }

  AgentConfig _mergeRemoteWithLocal({
    required AgentConfig remoteConfig,
    required AgentConfig? localConfig,
  }) {
    if (localConfig == null) return remoteConfig;

    final byId = <String, AgentProfile>{};
    for (final item in remoteConfig.agents) {
      byId[item.id] = item;
    }

    // Conserva agentes que existian localmente pero no llegaron al backend.
    for (final item in localConfig.agents) {
      if (item.id.trim().isEmpty) continue;
      byId.putIfAbsent(item.id, () => item);
    }

    final merged = _normalizeConfig(
      AgentConfig(
        activeAgentId: byId.containsKey(remoteConfig.activeAgentId)
            ? remoteConfig.activeAgentId
            : (byId.containsKey(localConfig.activeAgentId)
                ? localConfig.activeAgentId
                : remoteConfig.activeAgentId),
        agents: byId.values.toList(),
      ),
    );
    return merged;
  }

  Future<AgentConfig> _bootstrapConfigFromLegacyPrompt() async {
    var legacyPrompt = '';
    final promptCacheFile = await _userPromptFile();
    if (await promptCacheFile.exists()) {
      legacyPrompt = (await promptCacheFile.readAsString()).trim();
    }

    final builtIns = _defaultBuiltIns();
    final customSeed = builtIns.firstWhere(
      (a) => a.id == customDefaultAgentId,
      orElse: () => builtIns.last,
    );
    final agents = builtIns.map((agent) {
      if (agent.id != customDefaultAgentId) return agent;
      final nextPrompt =
          legacyPrompt.isEmpty ? customSeed.prompt : legacyPrompt;
      return agent.copyWith(prompt: nextPrompt);
    }).toList();

    final config = AgentConfig(
      activeAgentId: customDefaultAgentId,
      agents: agents,
    );
    await _persist(config);
    await _syncLegacyPrompt(config.activeAgent?.composedPrompt ?? systemPrompt);
    return config;
  }

  AgentConfig _normalizeConfig(AgentConfig config) {
    final byId = <String, AgentProfile>{};
    for (final agent in config.agents) {
      if (agent.id.isEmpty || agent.name.isEmpty || agent.prompt.isEmpty) {
        continue;
      }
      byId[agent.id] = agent;
    }

    for (final builtIn in _defaultBuiltIns()) {
      final existing = byId[builtIn.id];
      if (existing == null) {
        byId[builtIn.id] = builtIn;
      } else {
        byId[builtIn.id] = existing.copyWith(
          name: builtIn.name,
          mode: builtIn.mode,
          canEditPrompt: builtIn.canEditPrompt,
          isBuiltIn: true,
          communicationStyle: existing.communicationStyle,
          communicationStyleOther: existing.communicationStyleOther,
          mindset: existing.mindset,
          prompt: builtIn.canEditPrompt ? existing.prompt : builtIn.prompt,
        );
      }
    }

    final ordered = <AgentProfile>[];
    for (final builtIn in _defaultBuiltIns()) {
      final item = byId.remove(builtIn.id);
      if (item != null) ordered.add(item);
    }
    ordered.addAll(byId.values);

    var activeId = config.activeAgentId;
    if (!ordered.any((item) => item.id == activeId)) {
      activeId = customDefaultAgentId;
    }

    return AgentConfig(
      activeAgentId: activeId,
      agents: ordered,
    );
  }

  Future<void> _syncLegacyPrompt(String prompt) async {
    final next = prompt.trim();
    if (next.isEmpty) return;
    final promptCacheFile = await _userPromptFile();
    await promptCacheFile.writeAsString(next);
  }

  // ─── Document / file management (RAG) ──────────────────────

  Future<AttachedFileRef> addFileToAgent({
    required String agentId,
    required String filePath,
  }) async {
    final ref = await withAuthRetry<AttachedFileRef>(
      action: (token) => _remoteApi.uploadDocument(
        accessToken: token,
        agentId: agentId,
        filePath: filePath,
      ),
    );
    if (ref == null) {
      throw Exception('No se pudo subir el archivo.');
    }

    // Update local config with new file ref
    final config = await loadConfig();
    final nextAgents = config.agents.map((agent) {
      if (agent.id != agentId) return agent;
      return agent.copyWith(
        attachedFiles: [...agent.attachedFiles, ref],
      );
    }).toList();
    final next = config.copyWith(agents: nextAgents);
    await _persist(next);
    return ref;
  }

  Future<void> removeFileFromAgent({
    required String agentId,
    required String fileId,
  }) async {
    await withAuthRetry<void>(
      action: (token) => _remoteApi.deleteDocument(
        accessToken: token,
        fileId: fileId,
      ),
    );

    final config = await loadConfig();
    final nextAgents = config.agents.map((agent) {
      if (agent.id != agentId) return agent;
      return agent.copyWith(
        attachedFiles:
            agent.attachedFiles.where((f) => f.id != fileId).toList(),
      );
    }).toList();
    final next = config.copyWith(agents: nextAgents);
    await _persist(next);
  }

  Future<List<AttachedFileRef>> listFilesForAgent({
    required String agentId,
  }) async {
    final result = await withAuthRetry<List<AttachedFileRef>>(
      action: (token) => _remoteApi.listDocuments(
        accessToken: token,
        agentId: agentId,
      ),
    );
    return result ?? [];
  }

  static const Set<String> _validStyles = {
    'formal',
    'informal',
    'corporativo',
    'otro',
  };

  List<AgentProfile> _defaultBuiltIns() {
    return [
      const AgentProfile(
        id: salesAgentId,
        name: 'Para Ventas',
        mode: 'ventas',
        communicationStyle: 'corporativo',
        mindset: 'orientado a cierres y resultados comerciales',
        canEditPrompt: false,
        isBuiltIn: true,
        prompt: '''Eres un asistente de apoyo en tiempo real durante llamadas comerciales y reuniones de ventas.

Tu funcion es ayudar al vendedor a responder rapido, claro y con estructura persuasiva mientras conversa en vivo por voz.

Reglas:

Responde en maximo 5-7 lineas.
Da respuestas directas, listas para decir en voz alta.
Estructura comercial: Contexto breve + Propuesta de valor + Evidencia corta + Cierre sugerido.
Para objeciones: valida la inquietud + responde con beneficio concreto + pregunta de avance.
No inventes datos especificos del cliente o del negocio.
Si falta contexto, asume un escenario B2B/B2C general y profesional.
Usa lenguaje profesional, seguro y natural.

Tu prioridad es:
Claridad
Confianza
Estructura
Precision

Responde siempre como si el vendedor estuviera hablando en ese momento.''',
      ),
      const AgentProfile(
        id: interviewsAgentId,
        name: 'Para Entrevistas',
        mode: 'entrevistas',
        communicationStyle: 'formal',
        mindset: 'analitico, objetivo y estructurado',
        canEditPrompt: false,
        isBuiltIn: true,
        prompt: '''Eres un asistente de apoyo en tiempo real durante entrevistas laborales tecnicas y profesionales.

Tu funcion es ayudar al candidato a responder rapido, claro y con estructura solida mientras esta en una entrevista en vivo por voz.

Reglas:

Responde en maximo 5-7 lineas.
Da respuestas directas, listas para decir en voz alta.
Estructura tecnica: Definicion breve + Aplicacion practica + Ejemplo corto.
Estructura conductual: STAR resumido (Situacion, Accion, Resultado).
No inventes experiencia especifica del usuario.
Si falta contexto, asume un perfil profesional general.
Usa lenguaje profesional, seguro y natural.

Tu prioridad es:
Claridad
Confianza
Estructura
Precision

Responde siempre como si el candidato estuviera hablando en ese momento.''',
      ),
      AgentProfile(
        id: customDefaultAgentId,
        name: 'Personalizar tu agente',
        mode: 'custom',
        communicationStyle: 'informal',
        mindset: 'flexible y adaptable al contexto del usuario',
        canEditPrompt: true,
        isBuiltIn: true,
        prompt: systemPrompt,
      ),
    ];
  }
}
