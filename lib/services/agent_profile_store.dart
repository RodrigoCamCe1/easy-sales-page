import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/app_config.dart';
import '../models/agent_profile.dart';

class AgentProfileStore {
  AgentProfileStore._();

  static final AgentProfileStore instance = AgentProfileStore._();

  static const String salesAgentId = 'sales';
  static const String interviewsAgentId = 'interviews';
  static const String customDefaultAgentId = 'custom-default';

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, 'agents_config.json'));
  }

  Future<AgentConfig> loadConfig() async {
    final file = await _file();
    if (!await file.exists()) {
      return _bootstrapConfigFromLegacyPrompt();
    }

    final raw = (await file.readAsString()).trim();
    if (raw.isEmpty) return _bootstrapConfigFromLegacyPrompt();

    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return _bootstrapConfigFromLegacyPrompt();
    }
    if (decoded is! Map) return _bootstrapConfigFromLegacyPrompt();

    final current = AgentConfig.fromJson(Map<String, dynamic>.from(decoded));
    final normalized = _normalizeConfig(current);
    await _persist(normalized);
    await _syncLegacyPrompt(
      normalized.activeAgent?.composedPrompt ?? systemPrompt,
    );
    return normalized;
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
    if (nextName.isEmpty || nextPrompt.isEmpty || nextMindset.isEmpty) {
      throw ArgumentError('Nombre, mentalidad y prompt requeridos');
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
      prompt: nextPrompt,
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
    final file = await _file();
    await file.writeAsString(jsonEncode(config.toJson()));
  }

  Future<AgentConfig> _bootstrapConfigFromLegacyPrompt() async {
    var legacyPrompt = '';
    if (await promptFile.exists()) {
      legacyPrompt = (await promptFile.readAsString()).trim();
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
    await promptFile.writeAsString(next);
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
