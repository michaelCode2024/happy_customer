import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:relaydesk_agent_console/src/state/session_controller.dart';
import 'package:relaydesk_agent_console/src/ui/error_banner.dart';
import 'package:relaydesk_agent_console/src/ui/login_shell.dart';
import 'package:relaydesk_agent_console/src/util/server_hint.dart';

/// 客服工作台登录。
///
/// 服务器地址收进「高级设置」：Web 同源部署通常已自动带上当前站点，
/// 避免国内用户被技术字段打断；跨机/桌面端仍可展开填写。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.session, this.onPlatformLogin});

  final SessionController session;

  /// 打开运营后台。仅测客服表单时可不传，此时不渲染切换链接。
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
  late bool _advancedOpen;

  @override
  void initState() {
    super.initState();
    final hint = initialServerHint(widget.session.serverHint);
    _server = TextEditingController(text: hint);
    // Web 已能从页面 origin 推断地址时默认收起；桌面端空地址则展开，避免找不到字段。
    _advancedOpen = hint.trim().isEmpty && !kIsWeb;
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
    if (widget.session.busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) {
      // 服务器校验失败时展开高级区，否则用户看不到红字。
      if (_server.text.trim().isEmpty && !_advancedOpen) {
        setState(() => _advancedOpen = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _formKey.currentState?.validate();
        });
      }
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
    return LoginShell(
      icon: Icons.support_agent_rounded,
      title: '登录工作台',
      subtitle: '欢迎回来，登录后继续接待你的客户。',
      badgeLabel: '客服 / 企业账号',
      onSurfaceSwitch: widget.session.busy ? null : widget.onPlatformLogin,
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
                LoginFieldSection(
                  label: '账号',
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _tenant,
                        textInputAction: TextInputAction.next,
                        enabled: !busy,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: '企业标识',
                          hintText: '请输入企业标识',
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                          prefixIcon: Icon(Icons.business_outlined),
                        ),
                        validator: (value) =>
                            (value ?? '').trim().isEmpty ? '请填写企业标识' : null,
                      ),
                      const SizedBox(height: 18),
                      TextFormField(
                        controller: _email,
                        autofillHints: const [AutofillHints.username],
                        enabled: !busy,
                        keyboardType: TextInputType.text,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '用户名',
                          hintText: '请输入用户名',
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: (value) {
                          final email = (value ?? '').trim();
                          if (email.isEmpty) {
                            return '请填写用户名';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 18),
                      TextFormField(
                        controller: _password,
                        focusNode: _passwordFocus,
                        autocorrect: false,
                        enableSuggestions: false,
                        enabled: !busy,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => busy ? null : _submit(),
                        decoration: InputDecoration(
                          labelText: '密码',
                          hintText: '请输入密码',
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
                            (value ?? '').isEmpty ? '请填写密码' : null,
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
                if (widget.session.error != null) ...<Widget>[
                  const SizedBox(height: 12),
                  ErrorBanner(
                    message: widget.session.error!,
                    onDismiss: widget.session.clearError,
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
