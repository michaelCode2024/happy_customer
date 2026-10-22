import 'package:tongyu_agent_console/src/ui/workspace_layout.dart';
import 'pwa_panel.dart';
import 'package:tongyu_agent_console/src/util/message_alert_stub.dart'
    if (dart.library.html) 'package:tongyu_agent_console/src/util/message_alert_web.dart';
import 'package:flutter/material.dart';

import 'package:tongyu_agent_console/src/api/api_exception.dart';
import 'package:tongyu_agent_console/src/state/session_controller.dart';

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

  int _settingsTab = 0;
  bool _settingPresence = false;
  bool _savingName = false;
  bool _savingPassword = false;
  String? _nameError;
  String? _passwordError;
  bool _obscure = true;

  InputDecoration _field(String label, {Widget? suffixIcon}) => InputDecoration(
        labelText: label,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        filled: true,
        fillColor:
            Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(45),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        suffixIcon: suffixIcon,
      );

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
      appBar: const WorkspaceAppBar(
          title: '个人设置',
          description: '管理你的工作状态、个人资料与外观',
          icon: Icons.settings_outlined),
      body: ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) {
          final session = widget.session;
          final agent = session.agent;
          final sections = <String, Widget>{
            'account': _Section(
              title: '个人资料',
              children: <Widget>[
                _InfoRow(label: '登录用户名', value: agent?.email ?? '—'),
                _InfoRow(label: '企业', value: session.tenant?.name ?? '—'),
                _InfoRow(label: '角色', value: _roleLabel(agent?.role ?? '')),
                ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title:
                        const Text('查看企业与连接信息', style: TextStyle(fontSize: 13)),
                    children: [
                      _InfoRow(
                          label: '企业标识', value: session.tenant?.slug ?? '—'),
                      _InfoRow(
                          label: '企业 ID', value: session.tenant?.id ?? '—'),
                      _InfoRow(label: '服务器', value: session.serverHint),
                    ]),
              ],
            ),
            'presence': _Section(
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
                    onSelectionChanged: _settingPresence
                        ? null
                        : (selection) => _setPresence(selection.first),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '在线时可以收到新的会话分配，仍需确认接单。离开或离线后不再自动分配新会话，已接待的会话保留。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            'name': _Section(
              title: '显示名称',
              children: <Widget>[
                TextField(
                  controller: _displayName,
                  enabled: !_savingName,
                  decoration: _field('客户与同事看到的名字'),
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
            'password': _Section(
              title: '修改密码',
              children: <Widget>[
                TextField(
                  controller: _currentPassword,
                  enabled: !_savingPassword,
                  obscureText: _obscure,
                  decoration: _field('当前密码'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _newPassword,
                  enabled: !_savingPassword,
                  obscureText: _obscure,
                  decoration: _field('新密码（至少 8 位）'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _confirmPassword,
                  enabled: !_savingPassword,
                  obscureText: _obscure,
                  decoration: _field(
                    '确认新密码',
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
            'inboxes': _Section(
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
            'appearance': _Section(
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
            'signout': OutlinedButton.icon(
              onPressed: () => _confirmSignOut(context),
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('退出登录'),
            ),
            'notifications': messageAlertSettings(),
            'version': Text(
              '版本信息：通语工作台 · 协议版本 v1',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          };
          final groups = <List<String>>[
            ['account', 'name', 'inboxes'],
            ['presence'],
            ['password', 'signout'],
            ['appearance', 'notifications', 'version']
          ];
          const labels = ['个人资料', '接待状态', '账号安全', '外观与通知'];
          const icons = [
            Icons.person_outline,
            Icons.support_agent,
            Icons.lock_outline,
            Icons.tune
          ];
          return LayoutBuilder(builder: (context, c) {
            final compact = c.maxWidth < 800;
            final navigation = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 2, 6, 12),
                    child: Row(children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withOpacity(.09),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          (agent?.displayName.isNotEmpty == true
                                  ? agent!.displayName
                                  : '我')
                              .characters
                              .first,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.primary),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(agent?.displayName ?? '个人设置',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                              Text(_roleLabel(agent?.role ?? ''),
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      color:
                                          theme.colorScheme.onSurfaceVariant)),
                            ]),
                      ),
                    ]),
                  ),
                  for (var i = 0; i < labels.length; i++)
                    _SettingsNavItem(
                      icon: icons[i],
                      label: labels[i],
                      selected: _settingsTab == i,
                      onTap: () => setState(() => _settingsTab = i),
                    ),
                ]);
            final content = ListView(
                key: ValueKey(_settingsTab),
                padding: EdgeInsets.fromLTRB(
                    compact ? 16 : 22, 16, compact ? 16 : 22, 32),
                children: [
                  Row(children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withOpacity(.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(icons[_settingsTab],
                          size: 16, color: theme.colorScheme.primary),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(labels[_settingsTab],
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontSize: 16)),
                          const SizedBox(height: 2),
                          Text(
                              [
                                '设置客户看到的名字，查看所属企业与客服入口',
                                '选择是否接收新的会话分配',
                                '更新登录密码，管理本次登录',
                                '按你的工作习惯设置界面与提醒'
                              ][_settingsTab],
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  if (_settingsTab == 3)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: PwaPanel(
                          api: widget.session.api, settingsOnly: true),
                    ),
                  for (final i in groups[_settingsTab])
                    Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: sections[i]!),
                  const SizedBox(height: 4),
                  Text('通语工作台 · 协议版本 v1',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline, fontSize: 11)),
                ]);
            if (compact)
              return Column(children: [
                Container(
                  width: double.infinity,
                  color: theme.colorScheme.surface,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for (var i = 0; i < labels.length; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        _SettingsTabChip(
                          icon: icons[i],
                          label: labels[i],
                          selected: _settingsTab == i,
                          onTap: () => setState(() => _settingsTab = i),
                        ),
                      ]
                    ]),
                  ),
                ),
                Expanded(child: content)
              ]);
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                  width: 216,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    border: Border(
                        right: BorderSide(
                            color: theme.colorScheme.outlineVariant)),
                  ),
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
                      child: navigation)),
              Expanded(
                  child: Align(
                      alignment: Alignment.topLeft,
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 880),
                          child: content)))
            ]);
          });
        },
      ),
    );
  }

  Future<void> _setPresence(String value) async {
    setState(() => _settingPresence = true);
    try {
      await widget.session.setPresence(value);
    } catch (e) {
      if (mounted) _toast('更新状态失败：$e');
    } finally {
      if (mounted) setState(() => _settingPresence = false);
    }
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
        'SUPERVISOR' => '客服主管',
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
    return WorkspaceCard(
      title: title,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            children[i],
          ],
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
                fontSize: 11.5,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '—' : value,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置页左侧导航项：选中时浅蓝底 + 左侧 2px 主色指示条。
class _SettingsNavItem extends StatelessWidget {
  const _SettingsNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? scheme.primary.withOpacity(.07) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border(
                left: BorderSide(
                  width: 2.4,
                  color: selected ? scheme.primary : Colors.transparent,
                ),
              ),
            ),
            child: Row(children: [
              Icon(icon,
                  size: 17,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant),
              const SizedBox(width: 9),
              Expanded(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w400,
                        color: selected
                            ? scheme.primary
                            : scheme.onSurface)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 窄屏设置页顶部的分段切换。
class _SettingsTabChip extends StatelessWidget {
  const _SettingsTabChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primary.withOpacity(.08) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: selected ? scheme.primary.withOpacity(.28) : scheme.outlineVariant),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                size: 15,
                color: selected ? scheme.primary : scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? scheme.primary : scheme.onSurface)),
          ]),
        ),
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
