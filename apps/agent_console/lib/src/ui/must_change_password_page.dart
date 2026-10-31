import 'package:flutter/material.dart';

import 'package:tongyu_agent_console/src/api/api_exception.dart';
import 'package:tongyu_agent_console/src/state/session_controller.dart';
import 'package:tongyu_agent_console/src/ui/error_banner.dart';
import 'package:tongyu_agent_console/src/ui/login_shell.dart';
import 'package:tongyu_agent_console/src/ui/platform_support.dart';

/// 使用初始密码登录后，须先修改密码方可进入工作台。修改成功后结束本次登录。
class MustChangePasswordPage extends StatefulWidget {
  const MustChangePasswordPage({super.key, required this.session});

  final SessionController session;

  @override
  State<MustChangePasswordPage> createState() => _MustChangePasswordPageState();
}

class _MustChangePasswordPageState extends State<MustChangePasswordPage> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscureCurrent = true;
  bool _obscureNext = true;
  bool _obscureConfirm = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final current = _current.text;
    final next = _next.text;
    if (current.isEmpty || next.isEmpty) {
      setState(() => _error = '请填写当前密码与新密码');
      return;
    }
    if (next.length < 8) {
      setState(() => _error = '新密码不少于 8 位');
      return;
    }
    if (next == current) {
      setState(() => _error = '新密码不得与当前密码相同');
      return;
    }
    if (next != _confirm.text) {
      setState(() => _error = '两次输入的新密码不一致');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.session.api.changePassword(
        currentPassword: current,
        newPassword: next,
      );
      if (!mounted) return;
      await widget.session.logout();
    } on ApiException catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final gap = MediaQuery.sizeOf(context).width < 560 ? 12.0 : 18.0;
    return LoginShell(
      icon: Icons.lock_reset_rounded,
      title: '请尽快修改登录密码',
      subtitle: '当前账号使用的是初始密码。为保障账号安全，请尽快完成修改。\n修改完成后，请使用新密码重新登录。',
      badgeLabel: '账号安全',
      supportOrigin: () => widget.session.api.server,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _passwordField(
            controller: _current,
            label: '当前密码',
            obscure: _obscureCurrent,
            autofillHints: const [AutofillHints.password],
            onToggle: () => setState(() => _obscureCurrent = !_obscureCurrent),
          ),
          SizedBox(height: gap),
          _passwordField(
            controller: _next,
            label: '新密码',
            helperText: '不少于 8 位，且不得与当前密码相同',
            obscure: _obscureNext,
            autofillHints: const [AutofillHints.newPassword],
            onToggle: () => setState(() => _obscureNext = !_obscureNext),
          ),
          SizedBox(height: gap),
          _passwordField(
            controller: _confirm,
            label: '确认新密码',
            obscure: _obscureConfirm,
            autofillHints: const [AutofillHints.newPassword],
            action: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            onToggle: () => setState(() => _obscureConfirm = !_obscureConfirm),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            ErrorBanner(
              message: _error!,
              onDismiss: () => setState(() => _error = null),
            ),
          ],
          SizedBox(height: gap),
          LoginSubmitButton(
            label: '确认修改并重新登录',
            busy: _busy,
            onPressed: _submit,
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : () => widget.session.logout(),
            child: const Text('退出登录'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => openPlatformSupport(
                      context,
                      origin: widget.session.api.server,
                      displayName: supportVisitorLabel(
                        tenantName: widget.session.tenant?.name ?? '',
                        role: widget.session.agent?.role ?? '',
                        displayName: widget.session.agent?.displayName ?? '',
                      ),
                      subject: '工作台修改密码',
                    ),
            child: const Text('修改遇到问题？联系通语技术支持'),
          ),
        ],
      ),
    );
  }

  Widget _passwordField({
    required TextEditingController controller,
    required String label,
    required bool obscure,
    required VoidCallback onToggle,
    String? helperText,
    List<String>? autofillHints,
    TextInputAction action = TextInputAction.next,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      controller: controller,
      enabled: !_busy,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: false,
      autofillHints: autofillHints,
      textInputAction: action,
      keyboardType: TextInputType.visiblePassword,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        helperMaxLines: 2,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          tooltip: obscure ? '显示此密码' : '隐藏此密码',
          onPressed: _busy ? null : onToggle,
          icon: Icon(
            obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
          ),
        ),
      ),
    );
  }
}
