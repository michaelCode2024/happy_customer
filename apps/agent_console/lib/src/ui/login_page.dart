import 'package:flutter/material.dart';

import 'package:relaydesk_agent_console/src/state/session_controller.dart';
import 'package:relaydesk_agent_console/src/ui/error_banner.dart';

/// The sign-in screen.
///
/// Two things drive its design. First, an agent signs in on a phone, a desktop
/// or a shared browser, so the form is a single column that never needs
/// horizontal scrolling. Second, the server address is a first-class field
/// rather than a build-time constant: the same build talks to a self-hosted
/// instance or to a hosted one, and getting that wrong is the most common
/// reason a working install appears broken.
///
/// It is also the entry point to the operations console: the two surfaces ship
/// in one binary because they answer the same question from opposite ends, and
/// the provider of one usually operates the other.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.session, this.onPlatformLogin});

  final SessionController session;

  /// Opens the operations console. Absent in tests that only drive the agent
  /// form, in which case the link is not rendered.
  final VoidCallback? onPlatformLogin;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _server;
  final _tenant = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(text: widget.session.serverHint);
    // The tenant slug is the one field that has no sensible default on a fresh
    // install, so it is left empty rather than guessed.
    _tenant.text = '';
  }

  @override
  void dispose() {
    _server.dispose();
    _tenant.dispose();
    _email.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    FocusScope.of(context).unfocus();
    await widget.session.login(
      server: _server.text,
      email: _email.text.trim(),
      password: _password.text,
      tenantSlug: _tenant.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListenableBuilder(
              listenable: widget.session,
              builder: (context, _) {
                final busy = widget.session.busy;
                return Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              Icons.support_agent,
                              color: theme.colorScheme.onPrimary,
                              size: 26,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                'RelayDesk 客服工作台',
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '坐席登录',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      TextFormField(
                        controller: _server,
                        enabled: !busy,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: '服务器地址',
                          hintText: 'chat.example.com 或 http://localhost:8080',
                          prefixIcon: Icon(Icons.dns_outlined),
                        ),
                        validator: (value) => (value ?? '').trim().isEmpty
                            ? '请填写服务器地址'
                            : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _tenant,
                        enabled: !busy,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: '企业标识',
                          hintText: '例如 demo',
                          prefixIcon: Icon(Icons.business_outlined),
                        ),
                        validator: (value) => (value ?? '').trim().isEmpty
                            ? '请填写企业标识'
                            : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _email,
                        enabled: !busy,
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '邮箱',
                          prefixIcon: Icon(Icons.alternate_email),
                        ),
                        validator: (value) {
                          final email = (value ?? '').trim();
                          if (email.isEmpty) {
                            return '请填写邮箱';
                          }
                          if (!email.contains('@')) {
                            return '邮箱格式不正确';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _password,
                        focusNode: _passwordFocus,
                        enabled: !busy,
                        obscureText: _obscure,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => busy ? null : _submit(),
                        decoration: InputDecoration(
                          labelText: '密码',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? '显示密码' : '隐藏密码',
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (value) =>
                            (value ?? '').isEmpty ? '请填写密码' : null,
                      ),
                      if (widget.session.error != null) ...<Widget>[
                        const SizedBox(height: 16),
                        ErrorBanner(
                          message: widget.session.error!,
                          onDismiss: widget.session.clearError,
                        ),
                      ],
                      const SizedBox(height: 22),
                      FilledButton(
                        onPressed: busy ? null : _submit,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                        ),
                        child: busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('登录'),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        '登录后工作台会自动重连，未读与分配状态保存在服务端。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (widget.onPlatformLogin != null) ...<Widget>[
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: busy ? null : widget.onPlatformLogin,
                          child: const Text('平台管理员登录'),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
