import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_config.dart';
import '../services/auth_session_manager.dart';

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  List<Map<String, dynamic>> _users = [];
  bool _loading = false;
  String? _error;
  String? _success;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>?> _adminRequest({
    required String method,
    required String path,
    Map<String, dynamic>? body,
  }) async {
    final token = AuthSessionManager.instance.accessToken;
    if (token == null) return null;

    final uri = Uri.parse(backendApiBaseUrl).resolve(path);
    final request = await HttpClient().openUrl(method, uri);
    request.headers.set('Authorization', 'Bearer $token');
    request.headers.set('Content-Type', 'application/json');
    if (body != null) {
      request.add(utf8.encode(jsonEncode(body)));
    }

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(responseBody) as Map<String, dynamic>;
    } else {
      final err = jsonDecode(responseBody) as Map<String, dynamic>;
      throw Exception(err['error'] ?? 'Error ${response.statusCode}');
    }
  }

  Future<void> _loadUsers() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final search = _searchCtrl.text.trim();
      final path = search.isEmpty
          ? '/api/admin/users'
          : '/api/admin/users?search=${Uri.encodeComponent(search)}';
      final result = await _adminRequest(method: 'GET', path: path);
      if (!mounted) return;
      setState(() {
        _users = List<Map<String, dynamic>>.from(result?['users'] ?? []);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _activateUser(String email) async {
    final result = await _showActivateDialog(email);
    if (result == null) return;

    setState(() {
      _success = null;
      _error = null;
    });

    try {
      await _adminRequest(
        method: 'POST',
        path: '/api/admin/activate',
        body: {
          'email': email,
          'plan_tier': result['tier'],
          'duration_days': result['days'],
        },
      );
      if (!mounted) return;
      setState(() => _success = 'Plan ${result['tier']} activado para $email');
      _loadUsers();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _deactivateUser(String email) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Desactivar plan'),
        content: Text('¿Desactivar el plan de $email? Volverá a Free.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Desactivar', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await _adminRequest(
        method: 'POST',
        path: '/api/admin/deactivate',
        body: {'email': email},
      );
      if (!mounted) return;
      setState(() => _success = 'Plan desactivado para $email');
      _loadUsers();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _extendUser(String email) async {
    final daysCtrl = TextEditingController(text: '30');
    final days = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Extender plan de $email'),
        content: TextField(
          controller: daysCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Días adicionales',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(daysCtrl.text) ?? 30),
            child: const Text('Extender'),
          ),
        ],
      ),
    );

    if (days == null) return;

    try {
      await _adminRequest(
        method: 'POST',
        path: '/api/admin/extend',
        body: {'email': email, 'extra_days': days},
      );
      if (!mounted) return;
      setState(() => _success = '+$days días para $email');
      _loadUsers();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<Map<String, dynamic>?> _showActivateDialog(String email) async {
    var selectedTier = 'pro';
    final daysCtrl = TextEditingController(text: '30');
    const tiers = ['pro', 'business'];

    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text('Activar plan para $email'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: selectedTier,
                items: tiers
                    .map((t) => DropdownMenuItem(value: t, child: Text(_tierLabel(t))))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setModalState(() => selectedTier = v);
                },
                decoration: const InputDecoration(
                  labelText: 'Plan',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: 30,
                items: const [
                  DropdownMenuItem(value: 30, child: Text('1 mes')),
                  DropdownMenuItem(value: 90, child: Text('3 meses')),
                  DropdownMenuItem(value: 180, child: Text('6 meses')),
                  DropdownMenuItem(value: 365, child: Text('1 año')),
                ],
                onChanged: (v) {
                  if (v != null) daysCtrl.text = v.toString();
                },
                decoration: const InputDecoration(
                  labelText: 'Duración',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, {
                'tier': selectedTier,
                'days': int.tryParse(daysCtrl.text) ?? 30,
              }),
              child: const Text('Activar'),
            ),
          ],
        ),
      ),
    );
  }

  String _tierLabel(String tier) {
    const labels = {
      'free': 'Gratuito',
      'pro': 'Pro (\$29/mes)',
      'business': 'Business (\$79/mes)',
    };
    return labels[tier] ?? tier;
  }

  Color _tierColor(String tier) {
    switch (tier) {
      case 'pro':
        return Colors.cyan;
      case 'business':
        return Colors.amber;
      default:
        return Colors.grey;
    }
  }

  String _formatDate(dynamic date) {
    if (date == null) return '-';
    final dt = DateTime.tryParse(date.toString());
    if (dt == null) return '-';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  bool _isExpired(Map<String, dynamic> user) {
    final tier = (user['plan_tier'] ?? 'free').toString();
    if (tier == 'free') return false;
    final expires = user['plan_expires_at'];
    if (expires == null) return false;
    final dt = DateTime.tryParse(expires.toString());
    return dt != null && DateTime.now().isAfter(dt);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Panel de Administración'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadUsers,
            tooltip: 'Recargar',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Search bar
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Buscar por email o nombre...',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _loadUsers(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _loadUsers,
                  child: const Text('Buscar'),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Messages
            if (_error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
              ),
            if (_success != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                ),
                child: Text(_success!, style: const TextStyle(color: Colors.green, fontSize: 12)),
              ),

            // Users table
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _users.isEmpty
                      ? const Center(child: Text('No se encontraron usuarios'))
                      : SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SingleChildScrollView(
                            child: DataTable(
                              columnSpacing: 20,
                              columns: const [
                                DataColumn(label: Text('Email')),
                                DataColumn(label: Text('Nombre')),
                                DataColumn(label: Text('Plan')),
                                DataColumn(label: Text('Expira')),
                                DataColumn(label: Text('Consultas')),
                                DataColumn(label: Text('Voz (min)')),
                                DataColumn(label: Text('Acciones')),
                              ],
                              rows: _users.map((user) {
                                final email = (user['email'] ?? '').toString();
                                final name = (user['name'] ?? '').toString();
                                final tier = (user['plan_tier'] ?? 'free').toString();
                                final expired = _isExpired(user);
                                final queryUsed = user['monthly_query_used'] ?? 0;
                                final queryLimit = user['monthly_query_limit'] ?? 0;
                                final voiceUsed = user['voice_minutes_used'] ?? 0;
                                final voiceLimit = user['voice_minutes_limit'] ?? 0;

                                return DataRow(cells: [
                                  DataCell(Text(email, style: const TextStyle(fontSize: 12))),
                                  DataCell(Text(name, style: const TextStyle(fontSize: 12))),
                                  DataCell(Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: _tierColor(tier).withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          _tierLabel(tier),
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: _tierColor(tier),
                                          ),
                                        ),
                                      ),
                                      if (expired)
                                        const Padding(
                                          padding: EdgeInsets.only(left: 4),
                                          child: Icon(Icons.warning, size: 14, color: Colors.red),
                                        ),
                                    ],
                                  )),
                                  DataCell(Text(
                                    _formatDate(user['plan_expires_at']),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: expired ? Colors.red : null,
                                    ),
                                  )),
                                  DataCell(Text('$queryUsed / $queryLimit', style: const TextStyle(fontSize: 12))),
                                  DataCell(Text('$voiceUsed / $voiceLimit', style: const TextStyle(fontSize: 12))),
                                  DataCell(Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(Icons.upgrade, size: 18),
                                        tooltip: 'Activar/Cambiar plan',
                                        onPressed: () => _activateUser(email),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      if (tier != 'free') ...[
                                        IconButton(
                                          icon: const Icon(Icons.more_time, size: 18),
                                          tooltip: 'Extender',
                                          onPressed: () => _extendUser(email),
                                          visualDensity: VisualDensity.compact,
                                        ),
                                        IconButton(
                                          icon: Icon(Icons.block, size: 18, color: Colors.red.withValues(alpha: 0.7)),
                                          tooltip: 'Desactivar',
                                          onPressed: () => _deactivateUser(email),
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ],
                                    ],
                                  )),
                                ]);
                              }).toList(),
                            ),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
