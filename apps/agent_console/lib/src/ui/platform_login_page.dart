import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:relaydesk_agent_console/src/api/relaydesk_api.dart';
import 'package:relaydesk_agent_console/src/platform/platform_controller.dart';
import 'package:relaydesk_agent_console/src/ui/error_banner.dart';
import 'package:relaydesk_agent_console/src/ui/login_shell.dart';
import 'package:relaydesk_agent_console/src/util/server_hint.dart';

/// 平台运营后台登录。
///
/// 成功后根路由根据 [PlatformPhase.ready] 进入运营主页；
/// 退出后相位回到 locked，仍停留在本页，不跳回客服登录。
class PlatformLoginPage extends StatefulWidget {
  const PlatformLoginPage({
    super.key,
    required this.controller,
    required this.onAgentLogin,
  });

  final PlatformController controller;
  final VoidCallback onAgentLogin;

  @override
  State<PlatformLoginPage> createState() => _PlatformLoginPageState();
}

class _PlatformLoginPageState extends State<PlatformLoginPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _server;
  final _email = TextEditingController();
  final _token = TextEditingController();
  bool _obscure = true;
  bool _emailLoaded = false;
  late bool _advancedOpen;

  @override
  void initState() {
    super.initState();
    final hint = initialServerHint(widget.controller.server);
    _server = TextEditingController(text: hint);
    _advancedOpen = hint.trim().isEmpty && !kIsWeb;
    _token.text = '';
    _loadRememberedEmail();
  }

  Future<void> _loadRememberedEmail() async {
    final email = await widget.controller.rememberedEmail();
    if (!mounted) return;
    if (email != null && email.isNotEmpty) {
      _email.text = email;
    }
    setState(() => _emailLoaded = true);
  }

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.controller.busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) {
      if (_server.text.trim().isEmpty && !_advancedOpen) {
        setState(() => _advancedOpen = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _formKey.currentState?.validate();
        });
      }
      return;
    }
    FocusScope.of(context).unfocus();
    await widget.controller.signIn(
      server: _server.text,
      email: _email.text,
      password: _token.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LoginShell(
      icon: Icons.admin_panel_settings_outlined,
      title: '登录运营后台',
      subtitle: '使用平台管理员账号，管理企业与服务。',
      badgeLabel: '平台运营',
      heroKind: LoginHeroKind.platform,
      onSurfaceSwitch: widget.controller.busy ? null : widget.onAgentLogin,
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
                LoginFieldSection(
                  label: '管理员凭证',
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _email,
                        autofillHints: const [AutofillHints.username],
                        enabled: !busy && _emailLoaded,
                        keyboardType: TextInputType.text,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '账号',
                          hintText: '请输入管理员用户名',
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: (value) =>
                            (value ?? '').trim().isEmpty ? '请填写管理员用户名' : null,
                      ),
                      const SizedBox(height: 18),
                      TextFormField(
                        controller: _token,
                        enabled: !busy,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => busy ? null : _submit(),
                        decoration: InputDecoration(
                          labelText: '密码',
                          hintText: '请输入管理员密码',
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? '显示密码' : '隐藏密码',
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                            onPressed: busy
                                ? null
                                : () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (value) =>
                            (value ?? '').trim().isEmpty ? '请填写登录密码' : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                LoginAdvancedServerField(
                  controller: _server,
                  enabled: !busy,
                  expanded: _advancedOpen,
                  onExpansionChanged: (open) =>
                      setState(() => _advancedOpen = open),
                ),
                if (widget.controller.error != null) ...<Widget>[
                  const SizedBox(height: 12),
                  ErrorBanner(
                    message: widget.controller.error!,
                    onDismiss: widget.controller.clearError,
                  ),
                ],
                const SizedBox(height: 18),
                LoginSubmitButton(
                  label: '登录',
                  busy: busy,
                  onPressed: _submit,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

String platformServerHint(String stored) =>
    stored.isEmpty ? '' : RelayDeskApi.normalizeServer(stored);
