import 'package:flutter/material.dart';

import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/platform/platform_controller.dart';
import 'package:relaydesk_agent_console/src/ui/error_banner.dart';
import 'package:relaydesk_agent_console/src/ui/login_shell.dart';
import 'package:relaydesk_agent_console/src/util/server_hint.dart';

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
    _server = TextEditingController(text: initialServerHint(hint));
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
    return LoginShell(
      icon: Icons.admin_panel_settings_outlined,
      title: '登录运营后台',
      subtitle: '管理企业、套餐与平台运行状态',
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
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? '请填写服务器地址' : null,
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
                const SizedBox(height: 12),
                TextButton(
                  onPressed: busy ? null : widget.onAgentLogin,
                  child: const Text('返回客服工作台登录'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The console's own address, prefilled when a server has been used before.
String platformServerHint(String stored) =>
    stored.isEmpty ? '' : RelayDeskApi.normalizeServer(stored);
