import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/agent_profile.dart';
import '../services/agent_profile_store.dart';

const List<String> _communicationStyles = [
  'formal',
  'informal',
  'corporativo',
  'otro',
];

class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key});

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen> {
  AgentConfig? _config;
  bool _loading = true;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final config = await AgentProfileStore.instance.loadConfig();
    if (!mounted) return;
    setState(() {
      _config = config;
      _loading = false;
    });
  }

  void _closeScreen() {
    Navigator.pop(context, _hasChanges);
  }

  Future<void> _selectAgent(AgentProfile agent) async {
    final next = await AgentProfileStore.instance.setActiveAgent(agent.id);
    if (!mounted) return;
    setState(() {
      _config = next;
      _hasChanges = true;
    });
    _closeScreen();
  }

  Future<void> _createAgent() async {
    final form = await _showAgentEditor(
      title: 'Anadir agente',
      initialName: '',
      initialStyle: 'formal',
      initialStyleOther: '',
      initialMindset: '',
      initialPrompt: '',
      canEditPrompt: true,
    );
    if (form == null) return;

    try {
      final next = await AgentProfileStore.instance.createCustomAgent(
        name: form.name,
        communicationStyle: form.communicationStyle,
        communicationStyleOther: form.communicationStyleOther,
        mindset: form.mindset,
        prompt: form.prompt,
      );
      if (!mounted) return;
      setState(() {
        _config = next;
        _hasChanges = true;
      });
      _closeScreen();
    } catch (error) {
      if (!mounted) return;
      _showError(error.toString());
    }
  }

  Future<void> _quickEditAgent(AgentProfile agent) async {
    final form = await _showAgentEditor(
      title: 'Editar ${agent.name}',
      initialName: agent.name,
      initialStyle: agent.communicationStyle,
      initialStyleOther: agent.communicationStyleOther,
      initialMindset: agent.mindset,
      initialPrompt: agent.prompt,
      canEditPrompt: agent.canEditPrompt,
      agentId: agent.id,
      initialAttachedFiles: agent.attachedFiles,
    );
    if (form == null) return;

    try {
      final next = await AgentProfileStore.instance.updateAgentQuickProfile(
        agentId: agent.id,
        communicationStyle: form.communicationStyle,
        communicationStyleOther: form.communicationStyleOther,
        mindset: form.mindset,
        prompt: form.prompt,
      );
      if (!mounted) return;
      setState(() {
        _config = next;
        _hasChanges = true;
      });
    } catch (error) {
      if (!mounted) return;
      _showError(error.toString());
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<_AgentEditorResult?> _showAgentEditor({
    required String title,
    required String initialName,
    required String initialStyle,
    required String initialStyleOther,
    required String initialMindset,
    required String initialPrompt,
    required bool canEditPrompt,
    String? agentId,
    List<AttachedFileRef> initialAttachedFiles = const [],
  }) async {
    final nameCtrl = TextEditingController(text: initialName);
    final mindsetCtrl = TextEditingController(text: initialMindset);
    final promptCtrl = TextEditingController(text: initialPrompt);
    final styleOtherCtrl = TextEditingController(text: initialStyleOther);
    var selectedStyle =
        _communicationStyles.contains(initialStyle) ? initialStyle : 'formal';
    var attachedFiles = List<AttachedFileRef>.from(initialAttachedFiles);
    var isProcessingFile = false;
    String? fileError;

    return showDialog<_AgentEditorResult>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final styleIsOther = selectedStyle == 'otro';

            Future<void> pickAndAttachFile() async {
              if (agentId == null || agentId.isEmpty) return;
              final result = await FilePicker.platform.pickFiles(
                type: FileType.custom,
                allowedExtensions: ['pdf', 'txt', 'docx'],
              );
              if (result == null || result.files.isEmpty) return;
              final path = result.files.single.path;
              if (path == null) return;

              setModalState(() {
                isProcessingFile = true;
                fileError = null;
              });
              try {
                final ref = await AgentProfileStore.instance.addFileToAgent(
                  agentId: agentId,
                  filePath: path,
                );
                setModalState(() {
                  attachedFiles = [...attachedFiles, ref];
                  isProcessingFile = false;
                });
              } catch (e) {
                setModalState(() {
                  isProcessingFile = false;
                  fileError = e.toString();
                });
              }
            }

            Future<void> removeFile(AttachedFileRef file) async {
              if (agentId == null || agentId.isEmpty) return;
              try {
                await AgentProfileStore.instance.removeFileFromAgent(
                  agentId: agentId,
                  fileId: file.id,
                );
                setModalState(() {
                  attachedFiles =
                      attachedFiles.where((f) => f.id != file.id).toList();
                });
              } catch (e) {
                setModalState(() {
                  fileError = e.toString();
                });
              }
            }

            return AlertDialog(
              title: Text(title),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: nameCtrl,
                        maxLength: 40,
                        decoration: const InputDecoration(
                          labelText: 'Nombre del agente',
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: selectedStyle,
                        items: _communicationStyles
                            .map(
                              (style) => DropdownMenuItem(
                                value: style,
                                child: Text(_styleLabel(style)),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setModalState(() {
                            selectedStyle = value;
                          });
                        },
                        decoration: const InputDecoration(
                          labelText: 'Estilo de comunicacion',
                        ),
                      ),
                      if (styleIsOther) ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: styleOtherCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Especifica el estilo',
                            hintText: 'Ej: cercano, tecnico, persuasivo',
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      TextField(
                        controller: mindsetCtrl,
                        maxLines: 2,
                        decoration: const InputDecoration(
                          labelText: 'Mentalidad',
                          hintText:
                              'Ej: orientado a resultados, empatico, analitico',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: promptCtrl,
                        enabled: canEditPrompt,
                        maxLines: 6,
                        decoration: InputDecoration(
                          labelText: 'Prompt',
                          hintText: canEditPrompt
                              ? 'Define instrucciones base del agente'
                              : 'Prompt bloqueado para este agente',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      if (canEditPrompt && agentId != null) ...[
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Text(
                              'Archivos adjuntos (${attachedFiles.length})',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                            const Spacer(),
                            if (isProcessingFile)
                              const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            else
                              IconButton(
                                onPressed: pickAndAttachFile,
                                icon: const Icon(
                                    Icons.attach_file_rounded),
                                tooltip: 'Adjuntar archivo (PDF, TXT, DOCX)',
                              ),
                          ],
                        ),
                        if (fileError != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            fileError!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontSize: 12,
                            ),
                          ),
                        ],
                        for (final file in attachedFiles)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Row(
                              children: [
                                Icon(
                                  _fileTypeIcon(file.fileType),
                                  size: 18,
                                  color: Colors.white70,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    file.fileName,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                Text(
                                  '${file.chunkCount} chunks',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.white.withValues(
                                        alpha: 0.5),
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => removeFile(file),
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 16,
                                  ),
                                  tooltip: 'Eliminar archivo',
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () {
                    final name = nameCtrl.text.trim();
                    final mindset = mindsetCtrl.text.trim();
                    final styleOther = styleOtherCtrl.text.trim();
                    final prompt = promptCtrl.text.trim();
                    if (name.isEmpty || mindset.isEmpty) return;
                    if (selectedStyle == 'otro' && styleOther.isEmpty) return;
                    Navigator.pop(
                      context,
                      _AgentEditorResult(
                        name: name,
                        communicationStyle: selectedStyle,
                        communicationStyleOther:
                            selectedStyle == 'otro' ? styleOther : '',
                        mindset: mindset,
                        prompt: prompt,
                      ),
                    );
                  },
                  child: const Text('Guardar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final config = _config;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF07162D),
              Color(0xFF081A35),
              Color(0xFF050F1D),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: _closeScreen,
                      icon: const Icon(Icons.arrow_back_rounded),
                      tooltip: 'Volver',
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Elegir agentes',
                      style: textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    ElevatedButton.icon(
                      onPressed: _createAgent,
                      icon: const Icon(Icons.add_circle_outline_rounded),
                      label: const Text('Anadir agente'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF33C45D),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  'Edita rapido cada agente para definir estilo, mentalidad y prompt.',
                  style: textTheme.bodyLarge?.copyWith(
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
                const SizedBox(height: 26),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : SingleChildScrollView(
                          child: Wrap(
                            spacing: 20,
                            runSpacing: 20,
                            children: [
                              for (final agent in config?.agents ?? const [])
                                _AgentCard(
                                  profile: agent,
                                  isActive: config?.activeAgentId == agent.id,
                                  onSelect: () => _selectAgent(agent),
                                  onQuickEdit: () => _quickEditAgent(agent),
                                ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AgentCard extends StatelessWidget {
  const _AgentCard({
    required this.profile,
    required this.isActive,
    required this.onSelect,
    required this.onQuickEdit,
  });

  final AgentProfile profile;
  final bool isActive;
  final VoidCallback onSelect;
  final VoidCallback onQuickEdit;

  @override
  Widget build(BuildContext context) {
    final borderColor = isActive
        ? const Color(0xFF5CB2FF)
        : Colors.white.withValues(alpha: 0.12);
    return Container(
      width: 270,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: isActive ? 1.4 : 1),
      ),
      child: Column(
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFF0F2B57), Color(0xFF113D80)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
            ),
            child: const Icon(
              Icons.smart_toy_rounded,
              color: Colors.white,
              size: 46,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onSelect,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.28)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                isActive ? '${profile.name} (activo)' : profile.name,
                textAlign: TextAlign.center,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Estilo: ${_styleLabel(profile.communicationStyle)}',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.78)),
          ),
          const SizedBox(height: 4),
          Text(
            'Mentalidad: ${profile.mindset}',
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.66)),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onQuickEdit,
                  icon: const Icon(Icons.edit_rounded, size: 16),
                  label: const Text('Editar'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

IconData _fileTypeIcon(String fileType) {
  switch (fileType.toLowerCase()) {
    case 'pdf':
      return Icons.picture_as_pdf_rounded;
    case 'docx':
      return Icons.description_rounded;
    case 'txt':
      return Icons.text_snippet_rounded;
    default:
      return Icons.insert_drive_file_rounded;
  }
}

String _styleLabel(String style) {
  switch (style) {
    case 'formal':
      return 'Formal';
    case 'informal':
      return 'Informal';
    case 'corporativo':
      return 'Corporativo';
    case 'otro':
      return 'Otro';
    default:
      return style;
  }
}

class _AgentEditorResult {
  const _AgentEditorResult({
    required this.name,
    required this.communicationStyle,
    required this.communicationStyleOther,
    required this.mindset,
    required this.prompt,
  });

  final String name;
  final String communicationStyle;
  final String communicationStyleOther;
  final String mindset;
  final String prompt;
}
