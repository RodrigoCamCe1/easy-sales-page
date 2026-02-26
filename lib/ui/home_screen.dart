import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../models/agent_profile.dart';
import '../models/conversation.dart';
import '../pages/conversation_detail_page.dart';
import '../services/agent_profile_store.dart';
import '../services/auth_session_manager.dart';
import '../services/conversation_store.dart';
import 'agents_screen.dart';

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
  WindowController? _barWindow;
  AgentProfile? _activeAgent;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadConversations();
    _loadActiveAgent();
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      // ⚠️ IGNORAR TODO lo que NO venga de la barra
      if (_barWindow == null || fromWindowId != _barWindow!.windowId) {
        return null;
      }

      switch (call.method) {
        case 'barOpened':
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

  Future<void> _openRecordingBar() async {
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
      ..setTitle('AsesorIA')
      ..show();
    _barWindow = window;
    await windowManager.hide();
  }

  Future<void> _openSettings() async {
    final activeAgent = await AgentProfileStore.instance.getActiveAgent();
    final window = await DesktopMultiWindow.createWindow(jsonEncode({
      'type': 'settings',
      'mainWindowId': 0,
      'prompt': activeAgent.prompt,
      'agentId': activeAgent.id,
      'agentName': activeAgent.name,
      'agentMode': activeAgent.mode,
      'canEditPrompt': activeAgent.canEditPrompt,
    }));
    window
      ..setTitle('Configuracion')
      ..show();
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
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => const AgentsScreen(),
      ),
    );
    if (changed == true) {
      await _loadActiveAgent();
      await _syncBarPromptWithActiveAgent();
    }
  }

  Future<void> _logout() async {
    await AuthSessionManager.instance.logout();
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
    final userInitialSource = userName.isNotEmpty
        ? userName
        : (userEmail.isNotEmpty ? userEmail : 'A');
    final userInitial = userInitialSource[0].toUpperCase();

    return Scaffold(
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
          child: Column(
            children: [
              _FramelessTitleBar(
                title: 'AsesorIA',
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
                          icon: Icons.public,
                          tooltip: 'Inicio',
                          onTap: () {},
                        ),
                        const SizedBox(width: 8),
                        _IconPill(
                          icon: Icons.settings_rounded,
                          tooltip: 'Configuracion',
                          onTap: _openSettings,
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
                            ],
                          ),
                        ),
                        const PopupMenuDivider(),
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
                          Text(
                            'AsesorIA',
                            style: textTheme.headlineMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 12),
                          _SoftPill(
                            label: _activeAgent?.name ?? 'Agente',
                            icon: Icons.tune_rounded,
                            onTap: _openAgentsScreen,
                          ),
                          const Spacer(),
                          ElevatedButton.icon(
                            onPressed: _openRecordingBar,
                            icon:
                                const Icon(Icons.play_arrow_rounded, size: 18),
                            label: const Text('Start AsesorIA'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF5CB2FF),
                              foregroundColor: const Color(0xFF0B0C10),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 18, vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
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
                              title: 'Inicia reuniones con AsesorIA',
                              subtitle:
                                  'AsesorIA analiza participantes, ofrece asistencia en tiempo real y genera notas.',
                              actionText: 'Unirse a demo',
                              onAction: _openRecordingBar,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 2,
                            child: _SmallCard(
                              title: 'Recibe recordatorios',
                              subtitle: 'Conecta tu calendario',
                              buttonText: 'Conectar',
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
          ),
        ),
      ),
      floatingActionButton: null,
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
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

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
            color: const Color(0xFF1B1F2A),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.white.withOpacity(0.08),
            ),
          ),
          child: Icon(icon, size: 18),
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

class _SmallCard extends StatelessWidget {
  const _SmallCard({
    required this.title,
    required this.subtitle,
    required this.buttonText,
  });

  final String title;
  final String subtitle;
  final String buttonText;

  @override
  Widget build(BuildContext context) {
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
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          Text(subtitle, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () {},
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.12),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Text(buttonText),
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
            child: const Text('Iniciar AsesorIA'),
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
