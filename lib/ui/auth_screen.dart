import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../services/auth_api.dart';
import '../services/auth_session_manager.dart';

enum _AuthMode {
  login,
  register,
  magic,
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _magicTokenController = TextEditingController();

  _AuthMode _mode = _AuthMode.login;
  bool _loading = false;
  String _status = '';
  String _devMagicLink = '';

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _magicTokenController.dispose();
    super.dispose();
  }

  Future<void> _submitLogin() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      _setStatus('Email y password son requeridos.');
      return;
    }

    setState(() {
      _loading = true;
      _status = '';
    });
    try {
      await AuthSessionManager.instance.login(email: email, password: password);
      _setStatus('Sesion iniciada.');
    } on AuthApiException catch (error) {
      _setStatus(error.toString());
    } catch (_) {
      _setStatus('No se pudo iniciar sesion.');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _submitRegister() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final name = _nameController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      _setStatus('Email y password son requeridos.');
      return;
    }
    if (password.length < 8) {
      _setStatus('El password debe tener al menos 8 caracteres.');
      return;
    }

    setState(() {
      _loading = true;
      _status = '';
    });
    try {
      await AuthSessionManager.instance.register(
        email: email,
        password: password,
        name: name.isEmpty ? null : name,
      );
      _setStatus('Cuenta creada.');
    } on AuthApiException catch (error) {
      _setStatus(error.toString());
    } catch (_) {
      _setStatus('No se pudo crear la cuenta.');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _requestMagicLink() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      _setStatus('Ingresa tu email.');
      return;
    }

    setState(() {
      _loading = true;
      _status = '';
      _devMagicLink = '';
    });
    try {
      final devLink = await AuthSessionManager.instance.requestMagicLink(
        email: email,
      );
      setState(() {
        _devMagicLink = devLink ?? '';
      });
      _setStatus('Revisa tu correo para el enlace magico.');
    } on AuthApiException catch (error) {
      _setStatus(error.toString());
    } catch (_) {
      _setStatus('No se pudo enviar el enlace magico.');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _verifyMagicToken() async {
    final token = _magicTokenController.text.trim();
    if (token.isEmpty) {
      _setStatus('Pega el token del enlace magico.');
      return;
    }

    setState(() {
      _loading = true;
      _status = '';
    });
    try {
      await AuthSessionManager.instance.verifyMagicLink(token: token);
      _setStatus('Sesion iniciada con magic link.');
    } on AuthApiException catch (error) {
      _setStatus(error.toString());
    } catch (_) {
      _setStatus('No se pudo verificar el token.');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _setStatus(String message) {
    if (!mounted) return;
    setState(() {
      _status = message;
    });
  }

  Future<void> _copyDevMagicLinkToken() async {
    if (_devMagicLink.trim().isEmpty) return;
    final uri = Uri.tryParse(_devMagicLink.trim());
    final token = uri?.queryParameters['token'] ?? '';
    if (token.isEmpty) {
      _setStatus('No se encontro token en el enlace.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: token));
    _setStatus('Token copiado al portapapeles.');
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final title = switch (_mode) {
      _AuthMode.login => 'Iniciar sesión',
      _AuthMode.register => 'Crear cuenta',
      _AuthMode.magic => 'Magic link',
    };
    final actionLabel = switch (_mode) {
      _AuthMode.login => 'Continuar',
      _AuthMode.register => 'Registrarme',
      _AuthMode.magic => 'Enviar enlace',
    };

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF0B0C10),
              Color(0xFF121723),
              Color(0xFF0D1320),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      children: [
                        Container(
                          width: 54,
                          height: 54,
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F2A5A),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color:
                                  const Color(0xFF5CB2FF).withValues(alpha: 0.35),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.north_east_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          title,
                          style:
                              Theme.of(context).textTheme.headlineMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                          decoration: BoxDecoration(
                            color:
                                const Color(0xFF111827).withValues(alpha: 0.88),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color:
                                  const Color(0xFF5CB2FF).withValues(alpha: 0.18),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                          Text(
                            'Correo electrónico',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            enabled: !_loading,
                            decoration: InputDecoration(
                              hintText: 'Tu dirección de correo electrónico',
                              filled: true,
                              fillColor: const Color(0xFF0C121E),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                          if (_mode == _AuthMode.register) ...[
                            const SizedBox(height: 12),
                            TextField(
                              controller: _nameController,
                              enabled: !_loading,
                              decoration: InputDecoration(
                                hintText: 'Nombre (opcional)',
                                filled: true,
                                fillColor: const Color(0xFF0C121E),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ],
                          if (_mode != _AuthMode.magic) ...[
                            const SizedBox(height: 12),
                            TextField(
                              controller: _passwordController,
                              obscureText: true,
                              enabled: !_loading,
                              decoration: InputDecoration(
                                hintText: 'Tu contraseña',
                                filled: true,
                                fillColor: const Color(0xFF0C121E),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ],
                          if (_mode == _AuthMode.magic) ...[
                            const SizedBox(height: 12),
                            TextField(
                              controller: _magicTokenController,
                              enabled: !_loading,
                              decoration: InputDecoration(
                                hintText: 'Pega el token del enlace',
                                filled: true,
                                fillColor: const Color(0xFF0C121E),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 14),
                          SizedBox(
                            height: 50,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF5CB2FF),
                                foregroundColor: const Color(0xFF08101C),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              onPressed: _loading
                                  ? null
                                  : () {
                                      if (_mode == _AuthMode.login) {
                                        _submitLogin();
                                        return;
                                      }
                                      if (_mode == _AuthMode.register) {
                                        _submitRegister();
                                        return;
                                      }
                                      _requestMagicLink();
                                    },
                              child: Text(actionLabel),
                            ),
                          ),
                          if (_mode == _AuthMode.magic) ...[
                            const SizedBox(height: 10),
                            SizedBox(
                              height: 46,
                              child: OutlinedButton(
                                onPressed: _loading ? null : _verifyMagicToken,
                                child: const Text('Verificar token y entrar'),
                              ),
                            ),
                          ],
                          const SizedBox(height: 18),
                          Row(
                            children: [
                              Expanded(
                                child: Divider(
                                  color: Colors.white.withValues(alpha: 0.16),
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 10),
                                child: Text(
                                  'o',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.72),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Divider(
                                  color: Colors.white.withValues(alpha: 0.16),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 48,
                            child: OutlinedButton.icon(
                              onPressed: _loading
                                  ? null
                                  : () => _setStatus(
                                      'Google login se habilita en el siguiente paso.'),
                              icon: const Text(
                                'G',
                                style: TextStyle(
                                  color: Color(0xFF5CB2FF),
                                  fontWeight: FontWeight.w800,
                                  fontSize: 18,
                                ),
                              ),
                              label: const Text('Continuar con Google'),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 48,
                            child: OutlinedButton.icon(
                              onPressed: _loading
                                  ? null
                                  : () => _setStatus(
                                      'Apple login se habilita en el siguiente paso.'),
                              icon: const Icon(Icons.apple, size: 22),
                              label: const Text('Continuar con Apple'),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Center(
                            child: TextButton(
                              onPressed: _loading
                                  ? null
                                  : () {
                                      setState(() {
                                        if (_mode == _AuthMode.login) {
                                          _mode = _AuthMode.register;
                                        } else if (_mode == _AuthMode.register) {
                                          _mode = _AuthMode.magic;
                                        } else {
                                          _mode = _AuthMode.login;
                                        }
                                        _status = '';
                                      });
                                    },
                              child: Text(
                                _mode == _AuthMode.login
                                    ? '¿No tienes cuenta? Registrarte'
                                    : _mode == _AuthMode.register
                                        ? '¿Ya tienes cuenta? Iniciar sesión'
                                        : 'Volver a login',
                              ),
                            ),
                          ),
                          if (_loading) ...[
                            const SizedBox(height: 8),
                            const Center(child: CircularProgressIndicator()),
                          ],
                          if (_status.trim().isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              _status,
                              style: TextStyle(
                                color: colorScheme.onSurface
                                    .withValues(alpha: 0.85),
                              ),
                            ),
                          ],
                          if (_mode == _AuthMode.magic &&
                              _devMagicLink.trim().isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: colorScheme.outlineVariant,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Dev magic link (local):',
                                    style:
                                        TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 6),
                                  SelectableText(_devMagicLink),
                                  const SizedBox(height: 8),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                      onPressed: _copyDevMagicLinkToken,
                                      child: const Text('Copiar token'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: Row(
                  children: [
                    _WindowButton(
                      tooltip: 'Minimizar',
                      icon: Icons.remove_rounded,
                      onTap: () async => windowManager.minimize(),
                    ),
                    const SizedBox(width: 8),
                    _WindowButton(
                      tooltip: 'Cerrar',
                      icon: Icons.close_rounded,
                      onTap: () async => windowManager.close(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: const Color(0xFF18243A).withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: const Color(0xFF5CB2FF).withValues(alpha: 0.28),
            ),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 18, color: Colors.white70),
        ),
      ),
    );
  }
}
