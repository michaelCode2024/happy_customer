import 'package:flutter/material.dart';

import 'package:relaydesk_agent_console/src/api/api_exception.dart';
import 'package:relaydesk_agent_console/src/state/session_controller.dart';

/// Account and connection settings.
///
/// The ordering follows what an agent actually does here: check who they are
/// signed in as, switch their own presence, occasionally change a password, and
/// only then look at connection details. The server address is shown but not
/// editable — changing it is a sign-out, and the login screen is where that
/// belongs.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.session,
    this.themeMode = ThemeMode.system,
    this.onThemeModeChanged,
  });

  final SessionController session;

  /// The app-wide brightness choice. Owned by the root widget, not by this
  /// screen, because the setting has to survive a sign-out: the login form is
  /// the first thing a dark-mode agent sees.
  final ThemeMode themeMode;

  /// Null when the host does not offer a choice (tests, embedded builds); the
  /// appearance section then renders read-only text instead of a selector.
  final ValueChanged<ThemeMode>? onThemeModeChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _displayName = TextEditingController();
  final _currentPassword = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirmPassword = TextEditingController();

  bool _savingName = false;
  bool _savingPassword = false;
  String? _nameError;
  String? _passwordError;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _displayName.text = widget.session.agent?.displayName ?? '';
  }

  @override
  void dispose() {
    _displayName.dispose();
    _currentPassword.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    final name = _displayName.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = '显示名称不能为空');
      return;
    }
    setState(() {
      _savingName = true;
      _nameError = null;
    });
    try {
      await widget.session.api.updateProfile(name);
      await widget.session.refreshProfile();
      if (!mounted) {
        return;
      }
      _toast('显示名称已更新');
    } on ApiException catch (failure) {
      if (mounted) {
        setState(() => _nameError = failure.message);
      }
    } finally {
      if (mounted) {
        setState(() => _savingName = false);
      }
    }
  }

  Future<void> _savePassword() async {
    final current = _currentPassword.text;
    final next = _newPassword.text;
    if (current.isEmpty || next.isEmpty) {
      setState(() => _passwordError = '请填写当前密码与新密码');
      return;
    }
    if (next.length < 8) {
      // Matches the server's own floor; failing here saves a round trip.
      setState(() => _passwordError = '新密码至少 8 位');
      return;
    }
    if (next != _confirmPassword.text) {
      setState(() => _passwordError = '两次输入的新密码不一致');
      return;
    }
    setState(() {
      _savingPassword = true;
      _passwordError = null;
    });
    try {
      await widget.session.api.changePassword(
        currentPassword: current,
        newPassword: next,
      );
      if (!mounted) {
        return;
      }
      _currentPassword.clear();
      _newPassword.clear();
      _confirmPassword.clear();
      _toast('密码已修改');
    } on ApiException catch (failure) {
      if (mounted) {
        setState(() => _passwordError = failure.message);
      }
    } finally {
      if (mounted) {
        setState(() => _savingPassword = false);
      }
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('设置'),
        backgroundColor: Colors.transparent,
      ),
      body: ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) {
          final session = widget.session;
          final agent = session.agent;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: <Widget>[
              _Section(
                title: '账号',
                children: <Widget>[
                  _InfoRow(label: '登录邮箱', value: agent?.email ?? '—'),
                  _InfoRow(label: '企业', value: session.tenant?.name ?? '—'),
                  _InfoRow(label: '企业标识', value: session.tenant?.id ?? '—'),
                  _InfoRow(label: '角色', value: _roleLabel(agent?.role ?? '')),
                  _InfoRow(label: '服务器', value: session.serverHint),
                ],
              ),
              const SizedBox(height: 18),
              _Section(
                title: '我的状态',
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const <ButtonSegment<String>>[
                        ButtonSegment<String>(
                          value: 'ONLINE',
                          label: Text('在线'),
                          icon: Icon(Icons.check_circle_outline, size: 16),
                        ),
                        ButtonSegment<String>(
                          value: 'AWAY',
                          label: Text('离开'),
                          icon: Icon(Icons.schedule_outlined, size: 16),
                        ),
                        ButtonSegment<String>(
                          value: 'OFFLINE',
                          label: Text('离线'),
                          icon: Icon(Icons.do_not_disturb_on_outlined, size: 16),
                        ),
                      ],
                      selected: <String>{agent?.presence ?? 'ONLINE'},
                      onSelectionChanged: (selection) =>
                          session.setPresence(selection.first),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '状态会同步给主管与其他同事；离线时不会自动分配新会话。',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _Section(
                title: '显示名称',
                children: <Widget>[
                  TextField(
                    controller: _displayName,
                    decoration: const InputDecoration(
                      labelText: '客户与同事看到的名字',
                    ),
                  ),
                  if (_nameError != null) _ErrorText(_nameError!),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed: _savingName ? null : _saveName,
                      child: _savingName
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('保存名称'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _Section(
                title: '修改密码',
                children: <Widget>[
                  TextField(
                    controller: _currentPassword,
                    obscureText: _obscure,
                    decoration: const InputDecoration(labelText: '当前密码'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _newPassword,
                    obscureText: _obscure,
                    decoration: const InputDecoration(labelText: '新密码（至少 8 位）'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _confirmPassword,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: '确认新密码',
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
                  ),
                  if (_passwordError != null) _ErrorText(_passwordError!),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed: _savingPassword ? null : _savePassword,
                      child: _savingPassword
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('修改密码'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _Section(
                title: '我的客服入口',
                children: <Widget>[
                  if (session.inboxes.isEmpty)
                    Text(
                      '暂无已加入的客服入口',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  for (final inbox in session.inboxes)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Icon(
                        inbox.aiEnabled
                            ? Icons.smart_toy_outlined
                            : Icons.inbox_outlined,
                        size: 18,
                      ),
                      title: Text(inbox.name),
                      subtitle: Text(
                        '标识 ${inbox.publicKey}'
                        '${inbox.autoAssign ? ' · 自动分配' : ''}'
                        '${inbox.aiEnabled ? ' · AI 已开启' : ''}',
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              _Section(
                title: '外观',
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: SegmentedButton<ThemeMode>(
                      showSelectedIcon: false,
                      segments: const <ButtonSegment<ThemeMode>>[
                        ButtonSegment<ThemeMode>(
                          value: ThemeMode.system,
                          label: Text('跟随系统'),
                          icon: Icon(Icons.brightness_auto_outlined, size: 16),
                        ),
                        ButtonSegment<ThemeMode>(
                          value: ThemeMode.light,
                          label: Text('浅色'),
                          icon: Icon(Icons.light_mode_outlined, size: 16),
                        ),
                        ButtonSegment<ThemeMode>(
                          value: ThemeMode.dark,
                          label: Text('深色'),
                          icon: Icon(Icons.dark_mode_outlined, size: 16),
                        ),
                      ],
                      selected: <ThemeMode>{widget.themeMode},
                      onSelectionChanged: widget.onThemeModeChanged == null
                          ? null
                          : (selection) =>
                              widget.onThemeModeChanged!(selection.first),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: () => _confirmSignOut(context),
                icon: const Icon(Icons.logout, size: 18),
                label: const Text('退出登录'),
              ),
              const SizedBox(height: 10),
              Text(
                '版本信息：连语客服工作台 · 协议版本 v1',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后需要重新输入密码。未读与分配状态保存在服务端。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.session.logout();
    }
  }

  static String _roleLabel(String role) => switch (role) {
        'OWNER' => '企业所有者',
        'ADMIN' => '管理员',
        'SUPERVISOR' => '主管',
        'AGENT' => '客服坐席',
        _ => role.isEmpty ? '—' : role,
      };
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant.withAlpha(120)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '—' : value,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        message,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }
}
