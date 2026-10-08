import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:relaydesk_agent_console/src/state/session_controller.dart';

/// The sign-in screen.
///
/// Two things drive its design. First, an agent signs in on a phone, a desktop
/// or a shared browser, so the form is a single column that never needs
/// horizontal scrolling. Second, the server address is a first-class field
/// rather than a build-time constant: the same build talks to a self-hosted
/// instance or to a hosted one, and getting that wrong is the most common
/// reason a working install appears broken.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.session});

  final SessionController session;

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
                        _ErrorBanner(
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

/// An inline failure notice. It carries the server's own wording, which is
/// written for an operator ("企业已停用", "密码错误"), so it is shown verbatim.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.error_outline,
            size: 18,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close, color: theme.colorScheme.onErrorContainer),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// Copies a value to the clipboard and confirms it. Used for the ids an agent
/// occasionally needs to paste into a ticket.
Future<void> copyToClipboard(BuildContext context, String value, String label) async {
  await Clipboard.setData(ClipboardData(text: value));
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('$label已复制'), duration: const Duration(seconds: 2)),
  );
}
