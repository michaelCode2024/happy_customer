import 'package:flutter/material.dart';

import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/platform/platform_controller.dart';
import 'package:relaydesk_agent_console/src/ui/error_banner.dart';

/// Sign-in for the RelayDesk operations console.
///
/// It asks for the deployment's static platform token rather than an email and
/// password, because that is the only credential the operations API accepts. The
/// token is used once to mint a 24-hour bearer token and is never stored, so a
/// console left open on a laptop cannot be used to mint more of them.
class PlatformLoginPage extends StatefulWidget {
  const PlatformLoginPage({
    super.key,
    required this.controller,
    required this.onAgentLogin,
  });

  final PlatformController controller;

  /// Switches back to the agent sign-in form.
  final VoidCallback onAgentLogin;

  @override
  State<PlatformLoginPage> createState() => _PlatformLoginPageState();
}

class _PlatformLoginPageState extends State<PlatformLoginPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _server;
  final _token = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    final hint = widget.controller.server;
    _server = TextEditingController(text: hint);
    // A stored server with no stored token is the normal return visit: the
    // bearer token expired overnight, and the address is still right.
    _token.text = '';
  }

  @override
  void dispose() {
    _server.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    FocusScope.of(context).unfocus();
    await widget.controller.signIn(
      server: _server.text,
      staticToken: _token.text,
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
              listenable: widget.controller,
              builder: (context, _) {
                final busy = widget.controller.busy;
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
                              color: theme.colorScheme.tertiary,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              Icons.admin_panel_settings_outlined,
                              color: theme.colorScheme.onTertiary,
                              size: 26,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                'RelayDesk 运营后台',
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '平台管理员登录',
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
                        controller: _token,
                        enabled: !busy,
                        obscureText: _obscure,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => busy ? null : _submit(),
                        decoration: InputDecoration(
                          labelText: '平台管理令牌',
                          hintText: '部署时配置的 PLATFORM_ADMIN_TOKEN',
                          prefixIcon: const Icon(Icons.key_outlined),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? '显示令牌' : '隐藏令牌',
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (value) =>
                            (value ?? '').trim().isEmpty ? '请填写平台管理令牌' : null,
                      ),
                      if (widget.controller.error != null) ...<Widget>[
                        const SizedBox(height: 16),
                        ErrorBanner(
                          message: widget.controller.error!,
                          onDismiss: widget.controller.clearError,
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
                            : const Text('进入运营后台'),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        '令牌只用于换取 24 小时会话凭证，不会被保存。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: busy ? null : widget.onAgentLogin,
                        child: const Text('返回客服工作台登录'),
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

/// The console's own address, prefilled when a server has been used before.
String platformServerHint(String stored) =>
    stored.isEmpty ? '' : RelayDeskApi.normalizeServer(stored);
