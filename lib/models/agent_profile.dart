class AgentProfile {
  const AgentProfile({
    required this.id,
    required this.name,
    required this.mode,
    required this.communicationStyle,
    required this.mindset,
    required this.prompt,
    required this.canEditPrompt,
    this.communicationStyleOther = '',
    this.isBuiltIn = false,
  });

  final String id;
  final String name;
  final String mode;
  final String communicationStyle;
  final String communicationStyleOther;
  final String mindset;
  final String prompt;
  final bool canEditPrompt;
  final bool isBuiltIn;

  String get effectiveCommunicationStyle {
    if (communicationStyle == 'otro' &&
        communicationStyleOther.trim().isNotEmpty) {
      return communicationStyleOther.trim();
    }
    return communicationStyle;
  }

  String get composedPrompt {
    final style = effectiveCommunicationStyle.trim();
    final mind = mindset.trim();
    final base = prompt.trim();
    final buffer = StringBuffer();
    if (style.isNotEmpty) {
      buffer.writeln('Estilo de comunicacion: $style.');
    }
    if (mind.isNotEmpty) {
      buffer.writeln('Mentalidad: $mind.');
    }
    if (base.isNotEmpty) {
      if (buffer.isNotEmpty) {
        buffer.writeln();
      }
      buffer.write(base);
    }
    return buffer.toString().trim();
  }

  AgentProfile copyWith({
    String? id,
    String? name,
    String? mode,
    String? communicationStyle,
    String? communicationStyleOther,
    String? mindset,
    String? prompt,
    bool? canEditPrompt,
    bool? isBuiltIn,
  }) {
    return AgentProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      mode: mode ?? this.mode,
      communicationStyle: communicationStyle ?? this.communicationStyle,
      communicationStyleOther:
          communicationStyleOther ?? this.communicationStyleOther,
      mindset: mindset ?? this.mindset,
      prompt: prompt ?? this.prompt,
      canEditPrompt: canEditPrompt ?? this.canEditPrompt,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'mode': mode,
      'communicationStyle': communicationStyle,
      'communicationStyleOther': communicationStyleOther,
      'mindset': mindset,
      'prompt': prompt,
      'canEditPrompt': canEditPrompt,
      'isBuiltIn': isBuiltIn,
    };
  }

  factory AgentProfile.fromJson(Map<String, dynamic> json) {
    return AgentProfile(
      id: (json['id'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? '').trim(),
      mode: (json['mode'] as String? ?? '').trim(),
      communicationStyle:
          (json['communicationStyle'] as String? ?? 'corporativo').trim(),
      communicationStyleOther:
          (json['communicationStyleOther'] as String? ?? '').trim(),
      mindset: (json['mindset'] as String? ?? 'enfocado a resultados').trim(),
      prompt: (json['prompt'] as String? ?? '').trim(),
      canEditPrompt: json['canEditPrompt'] == true,
      isBuiltIn: json['isBuiltIn'] == true,
    );
  }
}

class AgentConfig {
  const AgentConfig({
    required this.activeAgentId,
    required this.agents,
  });

  final String activeAgentId;
  final List<AgentProfile> agents;

  AgentProfile? get activeAgent {
    for (final agent in agents) {
      if (agent.id == activeAgentId) return agent;
    }
    return null;
  }

  AgentConfig copyWith({
    String? activeAgentId,
    List<AgentProfile>? agents,
  }) {
    return AgentConfig(
      activeAgentId: activeAgentId ?? this.activeAgentId,
      agents: agents ?? this.agents,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'activeAgentId': activeAgentId,
      'agents': agents.map((item) => item.toJson()).toList(),
    };
  }

  factory AgentConfig.fromJson(Map<String, dynamic> json) {
    final rawAgents = json['agents'];
    final parsed = <AgentProfile>[];
    if (rawAgents is List) {
      for (final item in rawAgents) {
        if (item is Map) {
          parsed.add(
            AgentProfile.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }

    return AgentConfig(
      activeAgentId: (json['activeAgentId'] as String? ?? '').trim(),
      agents: parsed,
    );
  }
}
