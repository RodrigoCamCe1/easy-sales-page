import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../models/agent_profile.dart';
import '../models/auth_models.dart';
import '../models/conversation.dart';
import '../pages/conversation_detail_page.dart';
import '../services/agent_profile_store.dart';
import '../services/auth_session_manager.dart';
import '../services/backend_data_api.dart';
import '../services/conversation_store.dart';
import '../core/app_config.dart';
import '../services/store_helpers.dart';
import 'admin_panel_screen.dart';
import 'agents_screen.dart';
import 'loading_overlay.dart';
import 'settings_panel.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Conversation> _conversations = [];
  String _searchQuery = '';
  bool _favoritesOnly = false;
  DateTime? _selectedDate;
  bool _loading = true;
  bool _settingsPanelOpen = false;
  String? _loadingAction; // null = no loading, otherwise shows message
  WindowController? _barWindow;
  AgentProfile? _activeAgent;

  // ── Calendar state ──
  bool _calendarConnected = false;
  bool _calendarLoading = false;
  List<Map<String, dynamic>> _calendarEvents = [];

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadConversations();
    _loadActiveAgent();
    _loadCalendarStatus();
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      switch (call.method) {
        case 'barOpened':
          // Track the window that just opened (recording or meeting)
          if (_barWindow == null) {
            _barWindow = WindowController.fromWindowId(fromWindowId);
          }
          await windowManager.hide();
          break;

        case 'barMinimizeRequested':
          await _barWindow?.hide();
          break;

        case 'barCloseRequested':
        case 'barClosed':
          await _barWindow?.close();
          _barWindow = null;
          await windowManager.show();
          await windowManager.focus();
          break;
      }

      return null;
    });
  }

  void _onSearchChanged() {
    final next = _searchController.text.trim();
    if (next == _searchQuery) return;
    setState(() {
      _searchQuery = next;
    });
  }

  List<Conversation> get _visibleConversations {
    final source = _favoritesOnly
        ? _conversations.where((c) => c.isFavorite).toList()
        : _conversations;
    final dateFiltered = _selectedDate == null
        ? source
        : source.where((c) => _isSameDay(c.endedAt, _selectedDate!)).toList();
    final query = _searchQuery.toLowerCase().trim();
    if (query.isEmpty) return dateFiltered;

    bool matches(Conversation item) {
      if (item.title.toLowerCase().contains(query)) return true;
      if (item.preview.toLowerCase().contains(query)) return true;
      if (item.messages.any((m) => m.text.toLowerCase().contains(query))) {
        return true;
      }
      if (item.suggestions.any((s) => s.toLowerCase().contains(query))) {
        return true;
      }
      if (item.transcripts.any((t) => t.toLowerCase().contains(query))) {
        return true;
      }
      return false;
    }

    return dateFiltered.where(matches).toList();
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _formatDate(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    return '$d/$m/${dt.year}';
  }

  Future<void> _pickDateFilter() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 5),
      locale: const Locale('es', 'ES'),
      helpText: 'Filtrar por fecha',
      cancelText: 'Cancelar',
      confirmText: 'Aplicar',
    );
    if (!mounted || picked == null) return;
    setState(() {
      _selectedDate = picked;
    });
  }

  void _clearDateFilter() {
    if (_selectedDate == null) return;
    setState(() {
      _selectedDate = null;
    });
  }

  Future<void> _persistConversations() async {
    await ConversationStore.instance.saveAll(_conversations);
  }

  Future<void> _renameConversation(Conversation item) async {
    final controller = TextEditingController(text: item.title);
    final renamed = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Editar nombre'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            hintText: 'Nombre de la conversación',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    final nextTitle = (renamed ?? '').trim();
    if (nextTitle.isEmpty || nextTitle == item.title) return;

    final index = _conversations.indexWhere((c) => c.id == item.id);
    if (index == -1) return;

    setState(() {
      _conversations[index] = _conversations[index].copyWith(title: nextTitle);
    });
    await _persistConversations();
  }

  Future<void> _toggleFavoriteConversation(Conversation item) async {
    final index = _conversations.indexWhere((c) => c.id == item.id);
    if (index == -1) return;

    setState(() {
      final current = _conversations[index];
      _conversations[index] = current.copyWith(isFavorite: !current.isFavorite);
    });
    await _persistConversations();
  }

  Future<void> _deleteConversation(Conversation item) async {
    final shouldDelete = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Borrar conversación'),
            content: Text(
              '¿Seguro que quieres borrar "${item.title}"? Esta acción no se puede deshacer.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Borrar'),
              ),
            ],
          ),
        ) ??
        false;

    if (!mounted || !shouldDelete) return;
    setState(() {
      _conversations.removeWhere((c) => c.id == item.id);
    });
    await _persistConversations();
  }

  Future<void> _onConversationAction(
    _ConversationAction action,
    Conversation item,
  ) async {
    switch (action) {
      case _ConversationAction.rename:
        await _renameConversation(item);
        break;
      case _ConversationAction.favorite:
        await _toggleFavoriteConversation(item);
        break;
      case _ConversationAction.delete:
        await _deleteConversation(item);
        break;
    }
  }

  Future<void> _loadConversations() async {
    setState(() {
      _loading = true;
    });
    final items = await ConversationStore.instance.load();
    if (!mounted) return;
    setState(() {
      _conversations = items;
      _loading = false;
    });
  }

  Future<void> _loadActiveAgent() async {
    final active = await AgentProfileStore.instance.getActiveAgent();
    if (!mounted) return;
    setState(() {
      _activeAgent = active;
    });
  }

  // ── Calendar ──

  Future<void> _loadCalendarStatus() async {
    setState(() => _calendarLoading = true);
    final api = BackendDataApi();

    final status = await withAuthRetry<Map<String, dynamic>>(
      action: (token) => api.getCalendarStatus(accessToken: token),
      silent: true,
    );

    if (!mounted) return;

    if (status == null || status['connected'] != true) {
      setState(() {
        _calendarConnected = false;
        _calendarLoading = false;
      });
      return;
    }

    _calendarConnected = true;

    final events = await withAuthRetry<List<Map<String, dynamic>>>(
      action: (token) => api.getCalendarEvents(accessToken: token),
      silent: true,
    );

    if (!mounted) return;
    setState(() {
      _calendarEvents = events ?? [];
      _calendarLoading = false;
    });
  }

  void _connectCalendar() {
    // User needs to re-login with Google to authorize Calendar scope
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
            'Para conectar Calendar, cerrá sesión y volvé a iniciar con Google.'),
        duration: Duration(seconds: 4),
      ),
    );
  }

  void _showCreateEventDialog() {
    final titleCtrl = TextEditingController();
    var selectedDate = DateTime.now();
    var startTime = TimeOfDay.now();
    var endTime =
        TimeOfDay(hour: TimeOfDay.now().hour + 1, minute: TimeOfDay.now().minute);

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.event_rounded, size: 22),
                SizedBox(width: 8),
                Text('Agendar reunión'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nombre de la reunión',
                    hintText: 'Ej: Llamada con cliente',
                    prefixIcon: Icon(Icons.title_rounded, size: 18),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Fecha',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.calendar_today_rounded, size: 16),
                        label: Text(
                            '${selectedDate.day}/${selectedDate.month}/${selectedDate.year}'),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: ctx,
                            initialDate: selectedDate,
                            firstDate: DateTime.now(),
                            lastDate:
                                DateTime.now().add(const Duration(days: 365)),
                          );
                          if (picked != null) {
                            setDialogState(() => selectedDate = picked);
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('Horario',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          OutlinedButton.icon(
                            icon: const Icon(Icons.schedule_rounded, size: 16),
                            onPressed: () async {
                              final picked = await showTimePicker(
                                  context: ctx, initialTime: startTime);
                              if (picked != null) {
                                setDialogState(() => startTime = picked);
                              }
                            },
                            label: Text(
                                '${startTime.hour.toString().padLeft(2, '0')}:${startTime.minute.toString().padLeft(2, '0')}'),
                          ),
                          const SizedBox(height: 2),
                          Text('Desde',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(ctx)
                                      .colorScheme
                                      .onSurfaceVariant)),
                        ],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 16),
                      child: Icon(Icons.arrow_forward_rounded, size: 16),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          OutlinedButton.icon(
                            icon: const Icon(Icons.schedule_rounded, size: 16),
                            onPressed: () async {
                              final picked = await showTimePicker(
                                  context: ctx, initialTime: endTime);
                              if (picked != null) {
                                setDialogState(() => endTime = picked);
                              }
                            },
                            label: Text(
                                '${endTime.hour.toString().padLeft(2, '0')}:${endTime.minute.toString().padLeft(2, '0')}'),
                          ),
                          const SizedBox(height: 2),
                          Text('Hasta',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(ctx)
                                      .colorScheme
                                      .onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final title = titleCtrl.text.trim();
                  if (title.isEmpty) return;

                  Navigator.pop(ctx);

                  final start = DateTime(
                    selectedDate.year,
                    selectedDate.month,
                    selectedDate.day,
                    startTime.hour,
                    startTime.minute,
                  );
                  final end = DateTime(
                    selectedDate.year,
                    selectedDate.month,
                    selectedDate.day,
                    endTime.hour,
                    endTime.minute,
                  );

                  final api = BackendDataApi();
                  await withAuthRetry<Map<String, dynamic>>(
                    action: (token) => api.createCalendarEvent(
                      accessToken: token,
                      body: {
                        'title': title,
                        'startDateTime': start.toUtc().toIso8601String(),
                        'endDateTime': end.toUtc().toIso8601String(),
                      },
                    ),
                    silent: true,
                  );

                  if (!mounted) return;
                  _loadCalendarStatus();
                },
                child: const Text('Agendar'),
              ),
            ],
          );
        });
      },
    );
  }

  Future<void> _openRecordingBar() async {
    setState(() => _loadingAction = 'Iniciando modo virtual...');
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final screenWidth = view.physicalSize.width;
      final screenHeight = view.physicalSize.height;
      const minWidth = 820.0;
      const maxWidth = 1180.0;
      const widthRatio = 0.74;
      const minHeight = 420.0;
      const heightRatio = 0.84;
      final targetWidth = (screenWidth * widthRatio).clamp(minWidth, maxWidth);
      final targetHeight = (screenHeight * heightRatio).clamp(
        minHeight,
        screenHeight - 28.0,
      );
      final left = (screenWidth - targetWidth) / 2;
      final top = (screenHeight - targetHeight) / 2;

      if (_barWindow != null) {
        _barWindow?.setFrame(Rect.fromLTWH(left, top, targetWidth, targetHeight));
        await _barWindow?.show();
        await windowManager.hide();
        return;
      }
      final window = await DesktopMultiWindow.createWindow(jsonEncode({
        'type': 'bar',
      }));
      window
        ..setFrame(
          Rect.fromLTWH(left, top, targetWidth, targetHeight),
        )
        ..setTitle('EasyExpert')
        ..show();
      _barWindow = window;
      await windowManager.hide();
    } finally {
      if (mounted) setState(() => _loadingAction = null);
    }
  }

  Future<void> _openMeetingBar() async {
    setState(() => _loadingAction = 'Iniciando modo reunion...');
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final screenWidth = view.physicalSize.width;
      final screenHeight = view.physicalSize.height;
      const minWidth = 820.0;
      const maxWidth = 1180.0;
      const widthRatio = 0.74;
      const minHeight = 420.0;
      const heightRatio = 0.84;
      final targetWidth = (screenWidth * widthRatio).clamp(minWidth, maxWidth);
      final targetHeight = (screenHeight * heightRatio).clamp(
        minHeight,
        screenHeight - 28.0,
      );
      final left = (screenWidth - targetWidth) / 2;
      final top = (screenHeight - targetHeight) / 2;

      final window = await DesktopMultiWindow.createWindow(jsonEncode({
        'type': 'meeting',
      }));
      window
        ..setFrame(
          Rect.fromLTWH(left, top, targetWidth, targetHeight),
        )
        ..setTitle('EasyExpert — Modo Reunión')
        ..show();
      await windowManager.hide();
    } finally {
      if (mounted) setState(() => _loadingAction = null);
    }
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) {
        final textTheme = Theme.of(context).textTheme;
        return Dialog(
          backgroundColor: const Color(0xFF1A1D24),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480, maxHeight: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.help_outline_rounded,
                          color: const Color(0xFF5CB2FF), size: 24),
                      const SizedBox(width: 10),
                      Text(
                        'Como usar EasyExpert',
                        style: textTheme.titleLarge?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white54),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Divider(color: Colors.white.withOpacity(0.1)),
                  const SizedBox(height: 12),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          _helpItem(
                            Icons.play_arrow_rounded,
                            'Start EasyExpert',
                            'Abre la barra flotante que escucha el audio de tu sistema y microfono en tiempo real.',
                            const Color(0xFF5CB2FF),
                          ),
                          _helpItem(
                            Icons.tune_rounded,
                            'Agentes',
                            'Selecciona o crea agentes con instrucciones personalizadas y documentos adjuntos para guiar las respuestas del asistente.',
                            const Color(0xFFFFD45C),
                          ),
                          _helpItem(
                            Icons.lightbulb_outline_rounded,
                            'Sugerencias',
                            'El panel lateral muestra preguntas sugeridas basadas en la conversacion que estas escuchando.',
                            const Color(0xFF81C784),
                          ),
                          _helpItem(
                            Icons.mic_rounded,
                            'Transcripcion',
                            'Muestra en tiempo real lo que se esta diciendo, separando audio del sistema y del microfono.',
                            const Color(0xFFCE93D8),
                          ),
                          _helpItem(
                            Icons.auto_fix_high_rounded,
                            'Modo libre',
                            'Permite al asistente responder libremente sin limitarse al documento adjunto. Util para preguntas generales.',
                            const Color(0xFFE53935),
                          ),
                          _helpItem(
                            Icons.visibility_rounded,
                            'Modo invisible',
                            'Oculta la barra de las capturas de pantalla y grabaciones, para que no sea visible en videollamadas.',
                            const Color(0xFF5CB2FF),
                          ),
                          _helpItem(
                            Icons.chat_rounded,
                            'Chat manual',
                            'Escribe preguntas directamente al asistente usando el campo de texto en la barra.',
                            const Color(0xFFFFB74D),
                          ),
                          _helpItem(
                            Icons.settings_rounded,
                            'Configuracion',
                            'Ajusta el dispositivo de audio del sistema y microfono, y edita el prompt del agente activo.',
                            Colors.white70,
                          ),
                          _helpItem(
                            Icons.star_rounded,
                            'Favoritos y filtros',
                            'Marca conversaciones como favoritas y filtra por fecha o texto desde la barra de busqueda.',
                            const Color(0xFFFFD45C),
                          ),
                          _helpItem(
                            Icons.calendar_month_rounded,
                            'Google Calendar',
                            'Conecta tu calendario para ver tus proximas reuniones y prepararte con anticipacion.',
                            const Color(0xFF7FC3FF),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static Widget _helpItem(
      IconData icon, String title, String description, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.65),
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _toggleSettings() {
    setState(() => _settingsPanelOpen = !_settingsPanelOpen);
  }

  Future<void> _syncBarPromptWithActiveAgent() async {
    if (_barWindow == null) return;
    final active = await AgentProfileStore.instance.getActiveAgent();
    try {
      await DesktopMultiWindow.invokeMethod(
        _barWindow!.windowId,
        'updatePrompt',
        {
          'agentId': active.id,
          'prompt': active.composedPrompt,
          'agentName': active.name,
          'agentMode': active.mode,
          'canEditPrompt': active.canEditPrompt,
        },
      );
    } catch (_) {}
  }

  Future<void> _openAgentsScreen() async {
    setState(() => _loadingAction = 'Cargando agentes...');
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => const AgentsScreen(),
      ),
    );
    if (mounted) setState(() => _loadingAction = null);
    if (changed == true) {
      await _loadActiveAgent();
      await _syncBarPromptWithActiveAgent();
    }
  }

  Future<void> _logout() async {
    await AuthSessionManager.instance.logout();
  }

  static const _adminEmails = ['intoyourmomy@gmail.com', 'rodrigo@easycorp.com'];
  bool _isAdmin(String email) => _adminEmails.contains(email.toLowerCase());

  void _openAdminPanel() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AdminPanelScreen()),
    );
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final user = AuthSessionManager.instance.currentUserValue;
    final userName = (user?.name ?? '').trim();
    final userEmail = (user?.email ?? '').trim();
    final userPlan = user?.plan ?? const UserPlan();
    final userInitialSource = userName.isNotEmpty
        ? userName
        : (userEmail.isNotEmpty ? userEmail : 'A');
    final userInitial = userInitialSource[0].toUpperCase();

    return Stack(
      children: [
        Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF0B0C10),
              Color(0xFF141723),
              Color(0xFF0E0F14),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Row(
            children: [
              // ── Settings panel (left side) ──
              if (_settingsPanelOpen)
                Container(
                  width: 320,
                  decoration: BoxDecoration(
                    color: const Color(0xFF141723),
                    border: Border(
                      right: BorderSide(
                        color: Colors.white.withValues(alpha: 0.1),
                      ),
                    ),
                  ),
                  child: SettingsPanel(
                    onClose: _toggleSettings,
                    onPromptSaved: () async {
                      final active = await AgentProfileStore.instance.getActiveAgent();
                      setState(() => _activeAgent = active);
                      _syncBarPromptWithActiveAgent();
                    },
                  ),
                ),
              // ── Main content ──
              Expanded(
                child: Column(
            children: [
              _FramelessTitleBar(
                title: 'EasyExpert $appVersion',
                onClose: () async {
                  await windowManager.close();
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 8),
                child: Row(
                  children: [
                    Row(
                      children: [
                        _IconPill(
                          icon: Icons.help_outline_rounded,
                          tooltip: 'Tutorial',
                          onTap: _showHelpDialog,
                        ),
                        const SizedBox(width: 8),
                        _IconPill(
                          icon: Icons.settings_rounded,
                          tooltip: 'Configuracion',
                          onTap: _toggleSettings,
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Container(
                        height: 38,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.08),
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(
                          children: [
                            Icon(Icons.search,
                                size: 18, color: Colors.white.withOpacity(0.6)),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _searchController,
                                textAlignVertical: TextAlignVertical.center,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  contentPadding:
                                      EdgeInsets.symmetric(vertical: 8),
                                  border: InputBorder.none,
                                  hintText: 'Buscar conversaciones...',
                                ),
                                style: textTheme.bodyMedium
                                    ?.copyWith(color: Colors.white),
                              ),
                            ),
                            Tooltip(
                              message: _favoritesOnly
                                  ? 'Mostrar todas'
                                  : 'Mostrar solo favoritas',
                              child: IconButton(
                                visualDensity: VisualDensity.compact,
                                splashRadius: 18,
                                onPressed: () {
                                  setState(() {
                                    _favoritesOnly = !_favoritesOnly;
                                  });
                                },
                                icon: Icon(
                                  _favoritesOnly
                                      ? Icons.star_rounded
                                      : Icons.star_border_rounded,
                                  size: 19,
                                  color: _favoritesOnly
                                      ? const Color(0xFFFFD45C)
                                      : Colors.white70,
                                ),
                              ),
                            ),
                            Tooltip(
                              message: _selectedDate == null
                                  ? 'Filtrar por fecha'
                                  : 'Fecha: ${_formatDate(_selectedDate!)}',
                              child: IconButton(
                                visualDensity: VisualDensity.compact,
                                splashRadius: 18,
                                onPressed: _pickDateFilter,
                                icon: Icon(
                                  Icons.calendar_month_rounded,
                                  size: 19,
                                  color: _selectedDate == null
                                      ? Colors.white70
                                      : const Color(0xFF7FC3FF),
                                ),
                              ),
                            ),
                            if (_selectedDate != null)
                              Tooltip(
                                message: 'Quitar filtro de fecha',
                                child: IconButton(
                                  visualDensity: VisualDensity.compact,
                                  splashRadius: 18,
                                  onPressed: _clearDateFilter,
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                    color: Colors.white60,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    PopupMenuButton<String>(
                      tooltip: 'Perfil',
                      onSelected: (value) async {
                        if (value == 'logout') {
                          await _logout();
                        } else if (value == 'admin') {
                          _openAdminPanel();
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem<String>(
                          enabled: false,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                userName.isNotEmpty ? userName : 'Usuario',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (userEmail.isNotEmpty)
                                Text(
                                  userEmail,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              const SizedBox(height: 4),
                              _PlanBadge(plan: userPlan),
                            ],
                          ),
                        ),
                        const PopupMenuDivider(),
                        if (_isAdmin(userEmail))
                          const PopupMenuItem<String>(
                            value: 'admin',
                            child: Row(
                              children: [
                                Icon(Icons.admin_panel_settings, size: 18),
                                SizedBox(width: 8),
                                Text('Panel Admin'),
                              ],
                            ),
                          ),
                        const PopupMenuItem<String>(
                          value: 'logout',
                          child: Text('Cerrar sesion'),
                        ),
                      ],
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2F3A),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: Text(userInitial),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Image.asset(
                            'assets/logo_name.png',
                            width: 180,
                            fit: BoxFit.contain,
                          ),
                          const SizedBox(width: 12),
                          _SoftPill(
                            label: _activeAgent?.name ?? 'Agente',
                            icon: Icons.tune_rounded,
                            onTap: _openAgentsScreen,
                          ),
                          const Spacer(),
                          PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'virtual') {
                                _openRecordingBar();
                              } else if (value == 'meeting') {
                                _openMeetingBar();
                              }
                            },
                            itemBuilder: (context) => [
                              const PopupMenuItem(
                                value: 'virtual',
                                child: ListTile(
                                  leading: Icon(Icons.headset_rounded, size: 20),
                                  title: Text('Modo Virtual'),
                                  subtitle: Text('Audio del sistema + micrófono',
                                      style: TextStyle(fontSize: 11)),
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'meeting',
                                child: ListTile(
                                  leading: Icon(Icons.groups_rounded, size: 20),
                                  title: Text('Modo Reunión'),
                                  subtitle: Text('Solo micrófono — reuniones presenciales',
                                      style: TextStyle(fontSize: 11)),
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            ],
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 18, vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF5CB2FF),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.play_arrow_rounded,
                                      size: 18, color: Color(0xFF0B0C10)),
                                  SizedBox(width: 6),
                                  Text('Start EasyExpert',
                                      style: TextStyle(
                                        color: Color(0xFF0B0C10),
                                        fontWeight: FontWeight.w600,
                                      )),
                                  SizedBox(width: 4),
                                  Icon(Icons.arrow_drop_down,
                                      size: 18, color: Color(0xFF0B0C10)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: _GradientCard(
                              title: 'Inicia reuniones con EasyExpert',
                              subtitle:
                                  'EasyExpert analiza participantes, ofrece asistencia en tiempo real y genera notas.',
                              actionText: 'Unirse a demo',
                              onAction: _openRecordingBar,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 2,
                            child: _CalendarCard(
                              connected: _calendarConnected,
                              loading: _calendarLoading,
                              events: _calendarEvents,
                              onConnect: _connectCalendar,
                              onCreateEvent: _showCreateEventDialog,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Conversaciones',
                            style: textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _loadConversations,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('Actualizar'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_loading)
                        const Center(child: CircularProgressIndicator())
                      else if (_visibleConversations.isEmpty)
                        (_searchQuery.isNotEmpty ||
                                _favoritesOnly ||
                                _selectedDate != null
                            ? _NoFilteredResults(
                                message: _buildNoResultsMessage(),
                              )
                            : _EmptyState(onStart: _openRecordingBar))
                      else
                        Column(
                          children: _visibleConversations
                              .map(
                                (item) => _ConversationTile(
                                  item: item,
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ConversationDetailPage(
                                          conversation: item,
                                        ),
                                      ),
                                    );
                                  },
                                  onAction: (action) =>
                                      _onConversationAction(action, item),
                                ),
                              )
                              .toList(),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ), // end Column
              ), // end Expanded (main content)
            ],
          ), // end Row (settings + main)
        ),
      ),
    ), // end Scaffold
        if (_loadingAction != null)
          LoadingOverlay(message: _loadingAction!),
      ],
    );
  }

  String _buildNoResultsMessage() {
    if (_searchQuery.isNotEmpty && _selectedDate != null && _favoritesOnly) {
      return 'No hay favoritas para "$_searchQuery" en ${_formatDate(_selectedDate!)}.';
    }
    if (_searchQuery.isNotEmpty && _selectedDate != null) {
      return 'No hay conversaciones para "$_searchQuery" en ${_formatDate(_selectedDate!)}.';
    }
    if (_selectedDate != null && _favoritesOnly) {
      return 'No hay favoritas en ${_formatDate(_selectedDate!)}.';
    }
    if (_selectedDate != null) {
      return 'No hay conversaciones en ${_formatDate(_selectedDate!)}.';
    }
    if (_favoritesOnly && _searchQuery.isNotEmpty) {
      return 'No hay favoritas para "$_searchQuery".';
    }
    if (_favoritesOnly) {
      return 'Aun no tienes conversaciones favoritas.';
    }
    return 'No se encontraron conversaciones para "$_searchQuery".';
  }
}

class _SoftPill extends StatelessWidget {
  const _SoftPill({
    required this.label,
    required this.icon,
    this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.12)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.white70),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: Colors.white70)),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 16, color: Colors.white70),
          ],
        ),
      ),
    );
  }
}

class _IconPill extends StatelessWidget {
  const _IconPill({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.isActive = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF1A2940) : const Color(0xFF1B1F2A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive
                  ? const Color(0xFF5CB2FF).withOpacity(0.4)
                  : Colors.white.withOpacity(0.08),
            ),
          ),
          child: Icon(icon, size: 18,
              color: isActive ? const Color(0xFF5CB2FF) : null),
        ),
      ),
    );
  }
}

class _GradientCard extends StatelessWidget {
  const _GradientCard({
    required this.title,
    required this.subtitle,
    required this.actionText,
    required this.onAction,
  });

  final String title;
  final String subtitle;
  final String actionText;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF0D2A6A), Color(0xFF1D6FE3), Color(0xFF5CB2FF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(color: Colors.white.withOpacity(0.85)),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: onAction,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.18),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Text(actionText),
          ),
        ],
      ),
    );
  }
}

class _CalendarCard extends StatelessWidget {
  const _CalendarCard({
    required this.connected,
    required this.loading,
    required this.events,
    required this.onConnect,
    required this.onCreateEvent,
  });

  final bool connected;
  final bool loading;
  final List<Map<String, dynamic>> events;
  final VoidCallback onConnect;
  final VoidCallback onCreateEvent;

  String _formatTime(String? dateTimeStr) {
    if (dateTimeStr == null) return '';
    final dt = DateTime.tryParse(dateTimeStr);
    if (dt == null) return dateTimeStr;
    final local = dt.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    const calendarGreen = Color(0xFF4CAF50);

    if (loading) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    if (!connected) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Recibe recordatorios',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            const Text('Conecta tu calendario',
                style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: onConnect,
              style: ElevatedButton.styleFrom(
                backgroundColor: calendarGreen.withOpacity(0.2),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Conectar'),
            ),
          ],
        ),
      );
    }

    // Connected — show today's events
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: calendarGreen.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_month_rounded,
                  size: 16, color: calendarGreen),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Eventos de hoy',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              GestureDetector(
                onTap: onCreateEvent,
                child: const Icon(Icons.add_rounded,
                    size: 18, color: calendarGreen),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (events.isEmpty)
            const Text('No hay eventos para hoy',
                style: TextStyle(color: Colors.white54, fontSize: 13))
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 100),
              child: Scrollbar(
                thumbVisibility: events.length > 3,
                child: SingleChildScrollView(
                  child: Column(
                    children: events.map((event) {
                      final title = event['title'] as String? ?? '(Sin titulo)';
                      final startStr = event['startDateTime'] as String?;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          children: [
                            Container(
                              width: 3,
                              height: 24,
                              decoration: BoxDecoration(
                                color: calendarGreen,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (startStr != null) ...[
                              Text(
                                _formatTime(startStr),
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 12),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: Text(
                                title,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 13),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
          if (events.length > 3)
            Text(
              '+${events.length - 3} más',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
        ],
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.item,
    this.onTap,
    this.onAction,
  });

  final Conversation item;
  final VoidCallback? onTap;
  final ValueChanged<_ConversationAction>? onAction;

  @override
  Widget build(BuildContext context) {
    final time = TimeOfDay.fromDateTime(item.endedAt);
    final duration = Duration(seconds: item.durationSeconds);
    final dateLabel =
        '${item.endedAt.day.toString().padLeft(2, '0')}/${item.endedAt.month.toString().padLeft(2, '0')}/${item.endedAt.year}';
    final timeLabel =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final durationLabel =
        '${duration.inMinutes.toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item.preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (item.isFavorite)
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: Icon(
                          Icons.star_rounded,
                          color: Color(0xFFFFD45C),
                          size: 18,
                        ),
                      ),
                    PopupMenuButton<_ConversationAction>(
                      icon: const Icon(
                        Icons.more_vert_rounded,
                        color: Colors.white70,
                        size: 20,
                      ),
                      onSelected: (action) => onAction?.call(action),
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: _ConversationAction.rename,
                          child: Text('Editar nombre'),
                        ),
                        PopupMenuItem(
                          value: _ConversationAction.favorite,
                          child: Text(
                            item.isFavorite
                                ? 'Quitar de favoritos'
                                : 'Añadir a favoritos',
                          ),
                        ),
                        const PopupMenuItem(
                          value: _ConversationAction.delete,
                          child: Text('Borrar'),
                        ),
                      ],
                    ),
                  ],
                ),
                _Tag(label: durationLabel),
                const SizedBox(height: 6),
                Text(dateLabel, style: const TextStyle(color: Colors.white60)),
                const SizedBox(height: 2),
                Text(timeLabel, style: const TextStyle(color: Colors.white60)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _ConversationAction {
  rename,
  favorite,
  delete,
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: const TextStyle(color: Colors.white70)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        children: [
          const Icon(Icons.chat_bubble_outline, color: Colors.white54),
          const SizedBox(height: 10),
          const Text(
            'Aún no hay conversaciones guardadas.',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: onStart,
            child: const Text('Iniciar EasyExpert'),
          ),
        ],
      ),
    );
  }
}

class _NoFilteredResults extends StatelessWidget {
  const _NoFilteredResults({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Column(
        children: [
          const Icon(Icons.search_off_rounded, color: Colors.white54),
          const SizedBox(height: 10),
          Text(
            message,
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _FramelessTitleBar extends StatelessWidget {
  const _FramelessTitleBar({
    required this.title,
    required this.onClose,
  });

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          _TitleButton(
            icon: Icons.remove_rounded,
            onPressed: () async => windowManager.minimize(),
            tooltip: 'Minimizar',
          ),
          _TitleButton(
            icon: Icons.crop_square_rounded,
            onPressed: () async {
              final isMaximized = await windowManager.isMaximized();
              if (isMaximized) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
            tooltip: 'Maximizar',
          ),
          _TitleButton(
            icon: Icons.close_rounded,
            onPressed: onClose,
            tooltip: 'Cerrar',
          ),
        ],
      ),
    );
  }
}

class _TitleButton extends StatelessWidget {
  const _TitleButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 32,
      child: IconButton(
        iconSize: 16,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
        tooltip: tooltip,
        icon: Icon(icon, color: Colors.white70),
      ),
    );
  }
}

class _PlanBadge extends StatelessWidget {
  const _PlanBadge({required this.plan});
  final UserPlan plan;

  Color get _color {
    switch (plan.tier) {
      case 'starter':
        return Colors.blue;
      case 'professional':
        return Colors.cyan;
      case 'business':
        return Colors.amber;
      case 'enterprise':
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            plan.tierLabel,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: _color,
            ),
          ),
          if (plan.isExpired)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.warning, size: 12, color: Colors.red),
            ),
          if (plan.isExpiringSoon && !plan.isExpired)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.schedule, size: 12, color: Colors.orange),
            ),
        ],
      ),
    );
  }
}
